"""API viewsets.

Access control has two independent layers, and both matter:

1. **Queryset scoping** — :class:`ClientScopedMixin` narrows every list and
   detail lookup to the requesting client's own records. A client cannot
   address another client's dog at all, so there is no object to leak.
2. **Field gating** — the serializers drop staff-only fields (temperament,
   chatty, private notes) for non-staff. See ``api/serializers.py``.

Losing either layer would be a real exposure, so viewsets here never rely on
serializer gating alone.
"""

from datetime import timedelta
from functools import lru_cache
from pathlib import Path

from django.conf import settings as django_settings
from django.db import transaction
from django.db.models import Q, Value
from django.db.models.functions import Replace, Upper
from django.utils import timezone
from django.utils.safestring import mark_safe
from rest_framework import status, viewsets
from rest_framework.decorators import action, api_view, permission_classes, throttle_classes
from rest_framework.permissions import AllowAny, IsAdminUser, IsAuthenticated
from rest_framework.renderers import TemplateHTMLRenderer
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView


@lru_cache(maxsize=1)
def load_silhouette_svg():
    """The dog silhouette, inlined into the intake page.

    Read from the Flutter app's asset directory rather than duplicated into
    Django's static files, so the web form and the mobile app can never drift
    onto different-shaped dogs. The whole repo is in the production image, so
    the path resolves there too.
    """
    path = Path(django_settings.BASE_DIR) / 'mobile' / 'assets' / 'dog_silhouette.svg'
    try:
        markup = path.read_text(encoding='utf-8')
    except OSError:
        return ''
    # Strip the XML prolog so it can be inlined inside an HTML document.
    if markup.lstrip().startswith('<?xml'):
        markup = markup.split('?>', 1)[-1]
    return mark_safe(markup.strip())  # noqa: S308 — our own asset, not user input

from .models import (
    AppSettings,
    Appointment,
    AppointmentStatus,
    BookingSeries,
    BookingType,
    Breed,
    Client,
    ClientClaimRequest,
    ClosureDay,
    Dog,
    DogPhoto,
    Equipment,
    GroomSession,
    IntakeInvite,
    IntakeSubmission,
    Invoice,
    OpeningHours,
    Payment,
    ProblemArea,
    ReviewStatus,
    TemperamentLimit,
    TodoItem,
    UserProfile,
)
from .scheduling import booking_warnings
from .serializers import (
    AppSettingsSerializer,
    AppointmentCheckSerializer,
    AppointmentSerializer,
    BookingSeriesSerializer,
    BreedSerializer,
    ClientClaimRequestSerializer,
    ClientSerializer,
    ClosureDaySerializer,
    DogListSerializer,
    DogPhotoSerializer,
    DogSerializer,
    EquipmentSerializer,
    GroomSessionSerializer,
    IntakeInviteSerializer,
    IntakeSubmissionSerializer,
    InvoiceSerializer,
    OpeningHoursSerializer,
    PaymentSerializer,
    ProblemAreaSerializer,
    PublicIntakeSubmissionSerializer,
    TemperamentLimitSerializer,
    TodoItemSerializer,
    UserProfileSerializer,
)


class IsStaffOrReadOnly(IsAuthenticated):
    """Everyone authenticated may read; only staff may write."""

    def has_permission(self, request, view):
        if not super().has_permission(request, view):
            return False
        if request.method in ('GET', 'HEAD', 'OPTIONS'):
            return True
        return bool(request.user and request.user.is_staff)


class ClientScopedMixin:
    """Narrow the queryset to the requesting user's own client record.

    ``client_lookup`` is the ORM path from this model to ``Client``. Staff see
    everything; a user with no client record sees nothing.
    """

    client_lookup = 'client'

    def scope_to_client(self, queryset):
        user = self.request.user
        if user.is_staff:
            return queryset
        client = getattr(user, 'client', None)
        if client is None:
            return queryset.none()
        return queryset.filter(**{self.client_lookup: client})


# ── Reference data ─────────────────────────────────────────────────────

class BreedViewSet(viewsets.ModelViewSet):
    queryset = Breed.objects.all()
    serializer_class = BreedSerializer
    permission_classes = [IsStaffOrReadOnly]

    def get_queryset(self):
        queryset = super().get_queryset()
        search = self.request.query_params.get('search')
        if search:
            queryset = queryset.filter(name__icontains=search)
        return queryset


class TemperamentLimitViewSet(viewsets.ModelViewSet):
    queryset = TemperamentLimit.objects.all()
    serializer_class = TemperamentLimitSerializer
    permission_classes = [IsAdminUser]


class OpeningHoursViewSet(viewsets.ModelViewSet):
    queryset = OpeningHours.objects.all()
    serializer_class = OpeningHoursSerializer
    permission_classes = [IsStaffOrReadOnly]


class ClosureDayViewSet(viewsets.ModelViewSet):
    queryset = ClosureDay.objects.all()
    serializer_class = ClosureDaySerializer
    permission_classes = [IsStaffOrReadOnly]


class AppSettingsView(APIView):
    """Singleton settings row. Readable by all, writable by staff."""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        return Response(AppSettingsSerializer(AppSettings.get()).data)

    def patch(self, request):
        if not request.user.is_staff:
            return Response({'detail': 'Staff only.'}, status=status.HTTP_403_FORBIDDEN)
        serializer = AppSettingsSerializer(AppSettings.get(), data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)


# ── Profile ────────────────────────────────────────────────────────────

class MyProfileView(APIView):
    permission_classes = [IsAuthenticated]

    def get_object(self, request):
        profile, _ = UserProfile.objects.get_or_create(user=request.user)
        return profile

    def get(self, request):
        return Response(UserProfileSerializer(self.get_object(request), context={'request': request}).data)

    def patch(self, request):
        serializer = UserProfileSerializer(
            self.get_object(request), data=request.data, partial=True, context={'request': request},
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)


# ── Clients ────────────────────────────────────────────────────────────

class ClientViewSet(viewsets.ModelViewSet):
    queryset = Client.objects.all().prefetch_related('dogs')
    serializer_class = ClientSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        queryset = super().get_queryset()
        user = self.request.user
        if not user.is_staff:
            # A client may see and edit exactly one record: their own.
            client = getattr(user, 'client', None)
            return queryset.filter(pk=client.pk) if client else queryset.none()

        search = self.request.query_params.get('search')
        if search:
            queryset = queryset.filter(
                Q(first_name__icontains=search)
                | Q(last_name__icontains=search)
                | Q(uid__icontains=search)
                | Q(phone__icontains=search)
                | Q(email__icontains=search)
            )
        return queryset

    def perform_create(self, serializer):
        if not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied

            raise PermissionDenied('Only staff can create client records.')
        serializer.save()


class ClientClaimRequestViewSet(viewsets.ModelViewSet):
    """A user asking to be linked to an existing client record.

    Anyone signed in may lodge a claim and see their own; only staff review
    them, because approving one grants access to that client's whole history.
    """

    queryset = ClientClaimRequest.objects.select_related('user', 'matched_client')
    serializer_class = ClientClaimRequestSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.request.user.is_staff:
            return queryset
        return queryset.filter(user=self.request.user)

    def perform_create(self, serializer):
        data = serializer.validated_data
        # Suggest a match on email or postcode + surname, for staff to confirm.
        # Never auto-link: the match is a hint, not an authorisation.
        postcode = data['claimed_postcode'].replace(' ', '').upper()
        candidates = Client.objects.filter(user__isnull=True)
        match = candidates.filter(email__iexact=data['claimed_email']).first()
        if match is None:
            surname = data['claimed_name'].split()[-1] if data['claimed_name'].split() else ''
            # Normalise both sides. Stored postcodes are typed by hand and
            # usually carry the space ("SL7 2HE"); comparing them against the
            # stripped claim ("SL72HE") never matched, which quietly killed
            # this fallback for every postcode written the normal way.
            match = candidates.annotate(
                postcode_key=Upper(Replace('postcode', Value(' '), Value(''))),
            ).filter(last_name__iexact=surname, postcode_key=postcode).first()
        serializer.save(user=self.request.user, matched_client=match)

    @action(detail=True, methods=['post'], permission_classes=[IsAdminUser])
    def approve(self, request, pk=None):
        claim = self.get_object()
        client_id = request.data.get('client_id') or (claim.matched_client_id)
        if not client_id:
            return Response(
                {'detail': 'No client selected to link this claim to.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        client = Client.objects.filter(pk=client_id).first()
        if client is None:
            return Response({'detail': 'Client not found.'}, status=status.HTTP_404_NOT_FOUND)
        if client.user_id and client.user_id != claim.user_id:
            return Response(
                {'detail': 'That client record is already linked to another login.'},
                status=status.HTTP_409_CONFLICT,
            )

        with transaction.atomic():
            client.user = claim.user
            client.save(update_fields=['user', 'updated_at'])
            claim.matched_client = client
            claim.status = ReviewStatus.APPROVED
            claim.reviewed_by = request.user
            claim.reviewed_at = timezone.now()
            claim.review_notes = request.data.get('review_notes', '')
            claim.save()
        return Response(self.get_serializer(claim).data)

    @action(detail=True, methods=['post'], permission_classes=[IsAdminUser])
    def reject(self, request, pk=None):
        claim = self.get_object()
        claim.status = ReviewStatus.REJECTED
        claim.reviewed_by = request.user
        claim.reviewed_at = timezone.now()
        claim.review_notes = request.data.get('review_notes', '')
        claim.save()
        return Response(self.get_serializer(claim).data)


# ── Dogs ───────────────────────────────────────────────────────────────

class DogViewSet(ClientScopedMixin, viewsets.ModelViewSet):
    queryset = Dog.objects.select_related('client', 'breed').prefetch_related('problem_areas')
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        return DogListSerializer if self.action == 'list' else DogSerializer

    def get_queryset(self):
        queryset = self.scope_to_client(super().get_queryset())

        # The Doguments search: dog name, client name, or phone number.
        search = self.request.query_params.get('search')
        if search:
            queryset = queryset.filter(
                Q(name__icontains=search)
                | Q(client__first_name__icontains=search)
                | Q(client__last_name__icontains=search)
                | Q(client__phone__icontains=search)
                | Q(client__uid__icontains=search)
            )

        client_id = self.request.query_params.get('client')
        if client_id:
            queryset = queryset.filter(client_id=client_id)

        if self.request.query_params.get('include_inactive') not in ('1', 'true', 'True'):
            queryset = queryset.filter(is_active=True)
        return queryset

    def perform_create(self, serializer):
        if not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied

            raise PermissionDenied('Only staff can add dogs.')
        serializer.save()

    @action(detail=True, methods=['get'])
    def photos(self, request, pk=None):
        dog = self.get_object()
        photos = dog.photos.all()
        return Response(DogPhotoSerializer(photos, many=True, context={'request': request}).data)

    @action(detail=True, methods=['get'], permission_classes=[IsAdminUser])
    def problem_areas(self, request, pk=None):
        dog = self.get_object()
        return Response(ProblemAreaSerializer(dog.problem_areas.all(), many=True).data)

    @action(detail=True, methods=['get'])
    def suggested_next_groom(self, request, pk=None):
        """When this dog is next due, from its last groom and its interval."""
        dog = self.get_object()
        last = dog.appointments.filter(status=AppointmentStatus.COMPLETED).order_by('-start_at').first()
        if last is None:
            return Response({'due_date': None, 'basis': 'no completed grooms yet'})
        due = timezone.localtime(last.start_at).date() + timedelta(weeks=dog.effective_schedule_weeks)
        return Response({
            'due_date': due.isoformat(),
            'basis': f'{dog.effective_schedule_weeks} weeks after {timezone.localtime(last.start_at):%d %b %Y}',
        })


class ProblemAreaViewSet(viewsets.ModelViewSet):
    """Staff only — these are private handling notes, not client-facing."""

    queryset = ProblemArea.objects.select_related('dog')
    serializer_class = ProblemAreaSerializer
    permission_classes = [IsAdminUser]

    def get_queryset(self):
        queryset = super().get_queryset()
        dog_id = self.request.query_params.get('dog')
        return queryset.filter(dog_id=dog_id) if dog_id else queryset

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user, source=ProblemArea.Source.STAFF)


class DogPhotoViewSet(ClientScopedMixin, viewsets.ModelViewSet):
    queryset = DogPhoto.objects.select_related('dog')
    serializer_class = DogPhotoSerializer
    permission_classes = [IsAuthenticated]
    client_lookup = 'dog__client'

    def get_queryset(self):
        queryset = self.scope_to_client(super().get_queryset())
        dog_id = self.request.query_params.get('dog')
        return queryset.filter(dog_id=dog_id) if dog_id else queryset

    def perform_create(self, serializer):
        if not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied

            raise PermissionDenied('Only staff can upload dog photos.')
        serializer.save(uploaded_by=self.request.user)


# ── Scheduling ─────────────────────────────────────────────────────────

class AppointmentViewSet(ClientScopedMixin, viewsets.ModelViewSet):
    queryset = Appointment.objects.select_related('dog', 'dog__client')
    serializer_class = AppointmentSerializer
    permission_classes = [IsAuthenticated]
    client_lookup = 'dog__client'

    def get_queryset(self):
        queryset = self.scope_to_client(super().get_queryset())

        date_from = self.request.query_params.get('from')
        date_to = self.request.query_params.get('to')
        if date_from:
            queryset = queryset.filter(start_at__date__gte=date_from)
        if date_to:
            queryset = queryset.filter(start_at__date__lte=date_to)

        dog_id = self.request.query_params.get('dog')
        if dog_id:
            queryset = queryset.filter(dog_id=dog_id)
        return queryset

    def perform_create(self, serializer):
        user = self.request.user
        if user.is_staff:
            serializer.save(created_by=user)
            return

        # Clients may only *request* an appointment for their own dog, and the
        # request lands as REQUESTED for Jess to confirm. Bookings themselves
        # are read-only to clients.
        from rest_framework.exceptions import PermissionDenied

        client = getattr(user, 'client', None)
        dog = serializer.validated_data.get('dog')
        if client is None or dog is None or dog.client_id != client.pk:
            raise PermissionDenied('You can only request appointments for your own dogs.')
        serializer.save(created_by=user, status=AppointmentStatus.REQUESTED)

    def perform_update(self, serializer):
        if not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied

            raise PermissionDenied('Only staff can change bookings.')
        serializer.save()

    def perform_destroy(self, instance):
        if not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied

            raise PermissionDenied('Only staff can delete bookings.')
        instance.delete()

    @action(detail=False, methods=['post'], permission_classes=[IsAdminUser])
    def check(self, request):
        """Warnings for a proposed slot — never a refusal.

        The app calls this before saving and shows anything returned in a
        confirm dialog. An empty list means the slot is unremarkable.
        """
        serializer = AppointmentCheckSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        warnings = booking_warnings(
            dog=data['dog'],
            start_at=data['start_at'],
            end_at=data.get('end_at'),
            exclude_appointment=data.get('exclude_appointment'),
        )
        suggested_end = data.get('end_at') or (
            data['start_at'] + timedelta(minutes=data['dog'].effective_groom_minutes)
        )
        return Response({
            'warnings': warnings,
            'suggested_end_at': suggested_end,
            'suggested_price': data['dog'].effective_price,
        })

    @action(detail=False, methods=['get'])
    def day(self, request):
        """Everything on one date, for the calendar's day view."""
        date = request.query_params.get('date') or timezone.localdate().isoformat()
        appointments = self.get_queryset().filter(start_at__date=date)
        return Response({
            'date': date,
            'appointments': self.get_serializer(appointments, many=True).data,
        })


class BookingSeriesViewSet(viewsets.ModelViewSet):
    queryset = BookingSeries.objects.select_related('dog')
    serializer_class = BookingSeriesSerializer
    permission_classes = [IsAdminUser]

    def perform_create(self, serializer):
        series = serializer.save(created_by=self.request.user)
        self._materialise(series)

    def perform_update(self, serializer):
        series = serializer.save()
        self._materialise(series)

    @staticmethod
    def _materialise(series):
        """Create the appointments this series implies, skipping existing ones.

        Only future dates are filled in — back-filling history would invent
        grooms that never happened.
        """
        if not series.active:
            return
        today = timezone.localdate()
        for date in series.occurrence_dates():
            if date < today:
                continue
            exists = Appointment.objects.filter(series=series, start_at__date=date).exists()
            if exists:
                continue
            start = timezone.make_aware(
                timezone.datetime.combine(date, series.preferred_time),
                timezone.get_current_timezone(),
            )
            Appointment.objects.create(
                dog=series.dog,
                start_at=start,
                end_at=start + timedelta(minutes=series.dog.effective_groom_minutes),
                booking_type=BookingType.SCHEDULED,
                series=series,
                created_by=series.created_by,
            )


# ── Groom timing ───────────────────────────────────────────────────────

class GroomSessionViewSet(viewsets.ModelViewSet):
    queryset = GroomSession.objects.select_related('dog').prefetch_related('timings')
    serializer_class = GroomSessionSerializer
    permission_classes = [IsAdminUser]

    def get_queryset(self):
        queryset = super().get_queryset()
        dog_id = self.request.query_params.get('dog')
        return queryset.filter(dog_id=dog_id) if dog_id else queryset

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    @action(detail=True, methods=['post'])
    def apply_to_dog(self, request, pk=None):
        """Make this session's total the dog's default groom time."""
        session = self.get_object()
        if not session.apply_to_dog():
            return Response(
                {'detail': 'This session has no recorded time to apply.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(self.get_serializer(session).data)


# ── Money ──────────────────────────────────────────────────────────────

class InvoiceViewSet(ClientScopedMixin, viewsets.ModelViewSet):
    queryset = Invoice.objects.select_related('client').prefetch_related('lines', 'payments')
    serializer_class = InvoiceSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        user = self.request.user
        if not user.is_staff and not AppSettings.get().invoicing_visible_to_clients:
            # Invoicing starts hidden from clients entirely.
            return Invoice.objects.none()
        return self.scope_to_client(super().get_queryset())

    def perform_create(self, serializer):
        if not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied

            raise PermissionDenied('Only staff can raise invoices.')
        serializer.save(created_by=self.request.user)

    def perform_update(self, serializer):
        if not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied

            raise PermissionDenied('Only staff can edit invoices.')
        serializer.save()


class PaymentViewSet(viewsets.ModelViewSet):
    queryset = Payment.objects.select_related('invoice')
    serializer_class = PaymentSerializer
    permission_classes = [IsAdminUser]

    def perform_create(self, serializer):
        serializer.save(recorded_by=self.request.user)


# ── Equipment / to-dos ─────────────────────────────────────────────────

class EquipmentViewSet(viewsets.ModelViewSet):
    queryset = Equipment.objects.all()
    serializer_class = EquipmentSerializer
    permission_classes = [IsAdminUser]


class TodoItemViewSet(viewsets.ModelViewSet):
    queryset = TodoItem.objects.all()
    serializer_class = TodoItemSerializer
    permission_classes = [IsAdminUser]

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    def perform_update(self, serializer):
        was_done = serializer.instance.is_done
        item = serializer.save()
        if item.is_done and not was_done:
            item.completed_at = timezone.now()
            item.save(update_fields=['completed_at'])
        elif not item.is_done and was_done:
            item.completed_at = None
            item.save(update_fields=['completed_at'])


# ── Intake ─────────────────────────────────────────────────────────────

class IntakeInviteViewSet(viewsets.ModelViewSet):
    queryset = IntakeInvite.objects.select_related('client')
    serializer_class = IntakeInviteSerializer
    permission_classes = [IsAdminUser]

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)


class PublicIntakeView(APIView):
    """The intake form itself, reached by emailed token — no login required.

    The token is the only credential, so it is single-use and time-limited,
    and a GET reveals nothing beyond the invited email address.
    """

    permission_classes = [AllowAny]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = 'intake'

    def get_invite(self, token):
        return IntakeInvite.objects.filter(token=token).first()

    def get(self, request, token):
        invite = self.get_invite(token)
        if invite is None:
            return Response({'detail': 'This link is not valid.'}, status=status.HTTP_404_NOT_FOUND)
        if not invite.is_usable:
            reason = 'already been used' if invite.used_at else 'expired'
            return Response(
                {'detail': f'This link has {reason}. Please ask for a new one.'},
                status=status.HTTP_410_GONE,
            )
        return Response({
            'email': invite.email,
            'business_name': AppSettings.get().business_name,
            'grid_columns': ProblemArea.GRID_COLUMNS,
            'grid_rows': ProblemArea.GRID_ROWS,
        })

    def post(self, request, token):
        invite = self.get_invite(token)
        if invite is None:
            return Response({'detail': 'This link is not valid.'}, status=status.HTTP_404_NOT_FOUND)
        if not invite.is_usable:
            reason = 'already been used' if invite.used_at else 'expired'
            return Response(
                {'detail': f'This link has {reason}. Please ask for a new one.'},
                status=status.HTTP_410_GONE,
            )

        serializer = PublicIntakeSubmissionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        with transaction.atomic():
            submission = serializer.save(invite=invite)
            invite.used_at = timezone.now()
            invite.save(update_fields=['used_at'])
        return Response(
            {'detail': 'Thank you — your details have been sent to Mojo and Co.', 'id': submission.pk},
            status=status.HTTP_201_CREATED,
        )


class PublicIntakeFormView(APIView):
    """The intake form as a web page, for someone with no app and no login.

    This is the point of intake: the recipient is a brand-new client who has
    not signed up for anything yet. A link to a screen inside the mobile app
    would be useless to them, so the form is served as plain HTML that works
    from an email in any browser.

    The page posts JSON to :class:`PublicIntakeView`, so validation, token
    single-use and expiry all stay in one tested place.
    """

    permission_classes = [AllowAny]
    throttle_classes = [ScopedRateThrottle]
    # Deliberately a different bucket from the submission endpoint — see the
    # note on DEFAULT_THROTTLE_RATES in settings.
    throttle_scope = 'intake_form'
    # Rendered as a page, not part of the JSON API.
    renderer_classes = [TemplateHTMLRenderer]

    def get(self, request, token):
        invite = IntakeInvite.objects.filter(token=token).first()
        settings_row = AppSettings.get()

        if invite is None or not invite.is_usable:
            if invite is None:
                message = 'This link is not valid.'
            elif invite.used_at:
                message = 'This form has already been filled in.'
            else:
                message = 'This link has expired.'
            return Response(
                {
                    'message': message,
                    'settings': settings_row,
                },
                template_name='intake/unavailable.html',
                status=status.HTTP_200_OK if invite else status.HTTP_404_NOT_FOUND,
            )

        return Response(
            {
                'token': token,
                'email': invite.email,
                'settings': settings_row,
                'breeds': Breed.objects.values_list('name', flat=True),
                'grid_columns': ProblemArea.GRID_COLUMNS,
                'grid_rows': ProblemArea.GRID_ROWS,
                'silhouette_svg': load_silhouette_svg(),
                'preference_fields': [
                    ('pref_body', 'Body'),
                    ('pref_feet', 'Feet shape'),
                    ('pref_tail', 'Tail'),
                    ('pref_face', 'Face'),
                    ('pref_ears', 'Ears'),
                    ('pref_skirt', 'Skirt'),
                ],
            },
            template_name='intake/form.html',
        )


class IntakeSubmissionViewSet(viewsets.ReadOnlyModelViewSet):
    queryset = IntakeSubmission.objects.select_related('invite', 'created_client')
    serializer_class = IntakeSubmissionSerializer
    permission_classes = [IsAdminUser]

    def get_queryset(self):
        queryset = super().get_queryset()
        status_filter = self.request.query_params.get('status')
        return queryset.filter(status=status_filter) if status_filter else queryset

    @action(detail=True, methods=['post'])
    def approve(self, request, pk=None):
        """Turn a reviewed submission into real Client, Dog and ProblemArea rows.

        Nothing from an intake form reaches the live records until this runs,
        which is why the submission stores dogs as JSON rather than real rows.
        """
        submission = self.get_object()
        if submission.status == ReviewStatus.APPROVED:
            return Response(
                {'detail': 'This submission has already been approved.'},
                status=status.HTTP_409_CONFLICT,
            )

        uid = request.data.get('client_uid')
        if not uid:
            return Response(
                {'detail': 'Give the new client a UID before approving.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if Client.objects.filter(uid=uid).exists():
            return Response({'detail': f'UID "{uid}" is already in use.'}, status=status.HTTP_409_CONFLICT)

        with transaction.atomic():
            client = submission.invite.client if submission.invite and submission.invite.client else None
            if client is None:
                client = Client.objects.create(
                    uid=uid,
                    first_name=submission.first_name,
                    last_name=submission.last_name,
                    email=submission.email,
                    phone=submission.phone,
                    address=submission.address,
                    postcode=submission.postcode,
                )

            for entry in submission.dogs:
                breed = None
                breed_name = (entry.get('breed') or '').strip()
                if breed_name:
                    breed = Breed.objects.filter(name__iexact=breed_name).first()

                dog = Dog.objects.create(
                    client=client,
                    name=entry.get('name', 'Unnamed'),
                    breed=breed,
                    breed_other='' if breed else breed_name,
                    date_of_birth=entry.get('date_of_birth') or None,
                    sex=entry.get('sex', ''),
                    is_neutered=bool(entry.get('is_neutered', False)),
                    pref_body=entry.get('pref_body', ''),
                    pref_feet=entry.get('pref_feet', ''),
                    pref_tail=entry.get('pref_tail', ''),
                    pref_face=entry.get('pref_face', ''),
                    pref_ears=entry.get('pref_ears', ''),
                    pref_skirt=entry.get('pref_skirt', ''),
                    medical_notes=entry.get('medical_notes', ''),
                    vet=entry.get('vet', ''),
                    general_notes=entry.get('general_notes', ''),
                )
                for area in entry.get('problem_areas', []) or []:
                    ProblemArea.objects.create(
                        dog=dog,
                        grid_cells=area.get('grid_cells', []),
                        reason=area.get('reason', ''),
                        source=ProblemArea.Source.INTAKE,
                    )

            submission.status = ReviewStatus.APPROVED
            submission.reviewed_by = request.user
            submission.reviewed_at = timezone.now()
            submission.review_notes = request.data.get('review_notes', '')
            submission.created_client = client
            submission.save()

        return Response(self.get_serializer(submission).data)

    @action(detail=True, methods=['post'])
    def reject(self, request, pk=None):
        submission = self.get_object()
        submission.status = ReviewStatus.REJECTED
        submission.reviewed_by = request.user
        submission.reviewed_at = timezone.now()
        submission.review_notes = request.data.get('review_notes', '')
        submission.save()
        return Response(self.get_serializer(submission).data)


# ── Health ─────────────────────────────────────────────────────────────

@api_view(['GET'])
@permission_classes([AllowAny])
@throttle_classes([])
def health(request):
    return Response({'status': 'ok'})
