"""API serializers.

The security-critical piece here is :class:`StaffOnlyFieldsMixin`. Several
fields on Client and Dog are Jess's private working notes — temperament,
whether an owner is chatty — and must never be serialised for a client. The
mixin removes them from the field set entirely rather than merely marking them
read-only, so they cannot leak through a response *or* be set by a crafted
request.

Field gating is only half the protection: the viewsets also scope querysets so
a client can never address another client's row at all. See ``api/views.py``.
"""

from decimal import Decimal

from django.contrib.auth.models import User
from django.utils import timezone
from rest_framework import serializers

from .models import (
    AppSettings,
    Appointment,
    BookingSeries,
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
    InvoiceLine,
    OpeningHours,
    Payment,
    PhaseTiming,
    ProblemArea,
    TemperamentLimit,
    TodoItem,
    UserProfile,
)


class StaffOnlyFieldsMixin:
    """Drop ``staff_only_fields`` from the serializer for non-staff users.

    Removing the field (rather than setting ``read_only``) means the value is
    absent from output *and* silently ignored on input, so a client cannot
    read or write it by any route.

    The gating happens in ``get_fields`` rather than ``__init__`` because a
    serializer declared as a nested field — ``ClientSerializer(source='client')``
    inside ``DogSerializer`` — is constructed at class-definition time, long
    before it has a request in its context. ``get_fields`` is evaluated lazily
    on first field access, by which point the nested serializer is bound to its
    parent and ``self.context`` resolves to the root's. Gating in ``__init__``
    silently did nothing for nested serializers and leaked every staff-only
    field on the owner block of a dog profile.
    """

    staff_only_fields = ()

    def get_fields(self):
        fields = super().get_fields()
        request = self.context.get('request')
        # No request at all means an internal caller (shell, management
        # command, tests constructing directly) — leave the fields in place.
        if request is None:
            return fields
        user = getattr(request, 'user', None)
        if user is not None and user.is_staff:
            return fields
        for field_name in self.staff_only_fields:
            fields.pop(field_name, None)
        return fields


# ── Auth / profile ─────────────────────────────────────────────────────

class DjoserUserSerializer(serializers.ModelSerializer):
    """What ``/api/auth/users/me/`` returns — drives role routing in the app."""

    is_staff = serializers.BooleanField(read_only=True)
    client_id = serializers.SerializerMethodField()
    has_client_record = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = ['id', 'username', 'email', 'first_name', 'last_name', 'is_staff', 'client_id', 'has_client_record']
        read_only_fields = ['id', 'username', 'is_staff']

    def get_client_id(self, obj):
        client = getattr(obj, 'client', None)
        return client.id if client else None

    def get_has_client_record(self, obj):
        return getattr(obj, 'client', None) is not None


class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    email = serializers.EmailField(source='user.email', required=False)
    first_name = serializers.CharField(source='user.first_name', required=False, allow_blank=True)
    last_name = serializers.CharField(source='user.last_name', required=False, allow_blank=True)
    is_staff = serializers.BooleanField(source='user.is_staff', read_only=True)
    is_superuser = serializers.BooleanField(source='user.is_superuser', read_only=True)

    class Meta:
        model = UserProfile
        fields = [
            'username', 'email', 'first_name', 'last_name', 'phone', 'profile_photo',
            'is_staff', 'is_superuser',
            'can_manage_clients', 'can_manage_bookings', 'can_manage_invoices',
            'can_manage_equipment', 'can_manage_settings',
        ]
        # Capability flags are set only by a superuser in the admin. If they
        # were writable here any authenticated user could PATCH their own
        # profile and grant themselves manager rights.
        read_only_fields = [
            'can_manage_clients', 'can_manage_bookings', 'can_manage_invoices',
            'can_manage_equipment', 'can_manage_settings',
        ]

    def update(self, instance, validated_data):
        user_data = validated_data.pop('user', {})
        for attr, value in user_data.items():
            setattr(instance.user, attr, value)
        if user_data:
            instance.user.save()
        return super().update(instance, validated_data)


# ── Reference data ─────────────────────────────────────────────────────

class BreedSerializer(serializers.ModelSerializer):
    class Meta:
        model = Breed
        fields = ['id', 'name', 'coat_type', 'avg_groom_minutes', 'avg_price', 'avg_schedule_weeks', 'notes']


class TemperamentLimitSerializer(serializers.ModelSerializer):
    temperament_display = serializers.CharField(source='get_temperament_display', read_only=True)

    class Meta:
        model = TemperamentLimit
        fields = ['id', 'temperament', 'temperament_display', 'max_per_day']


class OpeningHoursSerializer(serializers.ModelSerializer):
    weekday_display = serializers.CharField(source='get_weekday_display', read_only=True)

    class Meta:
        model = OpeningHours
        fields = ['id', 'weekday', 'weekday_display', 'open_time', 'close_time', 'is_closed']


class ClosureDaySerializer(serializers.ModelSerializer):
    class Meta:
        model = ClosureDay
        fields = ['id', 'date', 'reason']


class AppSettingsSerializer(serializers.ModelSerializer):
    class Meta:
        model = AppSettings
        fields = [
            'business_name', 'contact_phone', 'contact_email',
            'invoicing_visible_to_clients', 'booking_slot_buffer_minutes', 'updated_at',
        ]
        read_only_fields = ['updated_at']


# ── Clients ────────────────────────────────────────────────────────────

class ClientSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    staff_only_fields = ('chatty', 'leaflet_received', 'notes')

    full_name = serializers.CharField(read_only=True)
    dog_count = serializers.SerializerMethodField()
    has_login = serializers.SerializerMethodField()

    class Meta:
        model = Client
        fields = [
            'id', 'uid', 'first_name', 'last_name', 'full_name', 'email', 'phone',
            'address', 'postcode', 'chatty', 'leaflet_received', 'notes',
            'dog_count', 'has_login', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']

    def get_dog_count(self, obj):
        return obj.dogs.filter(is_active=True).count()

    def get_has_login(self, obj):
        return obj.user_id is not None


class ClientClaimRequestSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    matched_client_name = serializers.CharField(source='matched_client.full_name', read_only=True, default=None)

    class Meta:
        model = ClientClaimRequest
        fields = [
            'id', 'user', 'username', 'claimed_name', 'claimed_email', 'claimed_postcode',
            'matched_client', 'matched_client_name', 'status', 'review_notes',
            'reviewed_at', 'created_at',
        ]
        # A claimant supplies only their own details; everything about the
        # outcome is decided server-side or by staff review.
        read_only_fields = ['id', 'user', 'matched_client', 'status', 'reviewed_at', 'created_at']


# ── Dogs ───────────────────────────────────────────────────────────────

class ProblemAreaSerializer(serializers.ModelSerializer):
    class Meta:
        model = ProblemArea
        fields = ['id', 'dog', 'grid_cells', 'reason', 'source', 'created_at', 'updated_at']
        read_only_fields = ['id', 'source', 'created_at', 'updated_at']

    def validate_grid_cells(self, value):
        return validate_grid_cells(value)


def validate_grid_cells(value):
    """Check cell references look like ``r{row}c{col}`` and sit on the grid."""
    if not isinstance(value, list):
        raise serializers.ValidationError('Expected a list of cell references.')
    cleaned = []
    for cell in value:
        if not isinstance(cell, str):
            raise serializers.ValidationError(f'Cell reference must be a string, got {type(cell).__name__}.')
        try:
            row_part, col_part = cell.lower().split('c')
            row = int(row_part.lstrip('r'))
            col = int(col_part)
        except (ValueError, AttributeError):
            raise serializers.ValidationError(f'Malformed cell reference "{cell}"; expected r{{row}}c{{col}}.')
        if not (0 <= row < ProblemArea.GRID_ROWS and 0 <= col < ProblemArea.GRID_COLUMNS):
            raise serializers.ValidationError(
                f'Cell "{cell}" is outside the {ProblemArea.GRID_COLUMNS}x{ProblemArea.GRID_ROWS} grid.'
            )
        cleaned.append(f'r{row}c{col}')
    return cleaned


class DogPhotoSerializer(serializers.ModelSerializer):
    class Meta:
        model = DogPhoto
        fields = ['id', 'dog', 'image', 'taken_at', 'caption', 'appointment', 'created_at']
        read_only_fields = ['id', 'created_at']


class DogListSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    """The Doguments row: a whole-profile summary at a glance.

    Carries the denormalised owner fields the list needs so the app renders
    without a second request per dog.
    """

    staff_only_fields = ('temperament', 'temperament_display')

    client_uid = serializers.CharField(source='client.uid', read_only=True)
    client_first_name = serializers.CharField(source='client.first_name', read_only=True)
    client_full_name = serializers.CharField(source='client.full_name', read_only=True)
    client_phone = serializers.CharField(source='client.phone', read_only=True)
    breed_label = serializers.CharField(read_only=True)
    temperament_display = serializers.CharField(source='get_temperament_display', read_only=True)
    groom_minutes_effective = serializers.IntegerField(source='effective_groom_minutes', read_only=True)
    price_effective = serializers.DecimalField(
        source='effective_price', max_digits=7, decimal_places=2, read_only=True,
    )
    schedule_weeks_effective = serializers.IntegerField(source='effective_schedule_weeks', read_only=True)

    class Meta:
        model = Dog
        fields = [
            'id', 'name', 'profile_image', 'is_active',
            'client', 'client_uid', 'client_first_name', 'client_full_name', 'client_phone',
            'breed', 'breed_label',
            'temperament', 'temperament_display',
            'groom_minutes_effective', 'price_effective', 'schedule_weeks_effective',
        ]


class DogSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    staff_only_fields = ('temperament', 'temperament_display', 'temperament_notes', 'problem_areas')

    client_detail = ClientSerializer(source='client', read_only=True)
    breed_label = serializers.CharField(read_only=True)
    temperament_display = serializers.CharField(source='get_temperament_display', read_only=True)
    problem_areas = ProblemAreaSerializer(many=True, read_only=True)
    groom_minutes_effective = serializers.IntegerField(source='effective_groom_minutes', read_only=True)
    price_effective = serializers.DecimalField(
        source='effective_price', max_digits=7, decimal_places=2, read_only=True,
    )
    schedule_weeks_effective = serializers.IntegerField(source='effective_schedule_weeks', read_only=True)

    class Meta:
        model = Dog
        fields = [
            'id', 'client', 'client_detail', 'name', 'breed', 'breed_other', 'breed_label',
            'date_of_birth', 'sex', 'is_neutered', 'profile_image',
            'temperament', 'temperament_display', 'temperament_notes',
            'groom_minutes', 'price', 'schedule_weeks',
            'groom_minutes_effective', 'price_effective', 'schedule_weeks_effective',
            'pref_body', 'pref_feet', 'pref_tail', 'pref_face', 'pref_ears', 'pref_skirt',
            'medical_notes', 'vet', 'general_notes', 'is_active',
            'problem_areas', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']


# ── Scheduling ─────────────────────────────────────────────────────────

class AppointmentSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    # A client seeing their own booking has no business seeing the handling
    # notes Jess keeps about their dog.
    staff_only_fields = ('dog_temperament',)

    dog_name = serializers.CharField(source='dog.name', read_only=True)
    dog_temperament = serializers.CharField(source='dog.temperament', read_only=True)
    client_id = serializers.IntegerField(source='dog.client_id', read_only=True)
    client_name = serializers.CharField(source='dog.client.full_name', read_only=True)
    client_phone = serializers.CharField(source='dog.client.phone', read_only=True)
    duration_minutes = serializers.IntegerField(read_only=True)

    class Meta:
        model = Appointment
        fields = [
            'id', 'dog', 'dog_name', 'dog_temperament', 'client_id', 'client_name', 'client_phone',
            'start_at', 'end_at', 'duration_minutes', 'booking_type', 'status',
            'price_quoted', 'notes', 'series', 'created_at', 'updated_at',
        ]
        # end_at is optional on input — the model fills it from the dog's groom
        # time when omitted.
        extra_kwargs = {'end_at': {'required': False}}
        read_only_fields = ['id', 'created_at', 'updated_at']

    def validate(self, data):
        start = data.get('start_at', getattr(self.instance, 'start_at', None))
        end = data.get('end_at', getattr(self.instance, 'end_at', None))
        if start and end and end <= start:
            raise serializers.ValidationError({'end_at': 'The end time must be after the start time.'})
        return data


class BookingSeriesSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)

    class Meta:
        model = BookingSeries
        fields = [
            'id', 'dog', 'dog_name', 'interval_weeks', 'start_date', 'end_date',
            'preferred_time', 'active', 'notes', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']


class AppointmentCheckSerializer(serializers.Serializer):
    """Input for the pre-booking warning check."""

    dog = serializers.PrimaryKeyRelatedField(queryset=Dog.objects.all())
    start_at = serializers.DateTimeField()
    end_at = serializers.DateTimeField(required=False, allow_null=True)
    exclude_appointment = serializers.PrimaryKeyRelatedField(
        queryset=Appointment.objects.all(), required=False, allow_null=True,
        help_text='Ignore this appointment when checking — used when editing an existing booking.',
    )


# ── Groom timing ───────────────────────────────────────────────────────

class PhaseTimingSerializer(serializers.ModelSerializer):
    phase_display = serializers.CharField(source='get_phase_display', read_only=True)

    class Meta:
        model = PhaseTiming
        fields = ['id', 'phase', 'phase_display', 'duration_seconds', 'started_at', 'ended_at', 'entered_manually']


class GroomSessionSerializer(serializers.ModelSerializer):
    timings = PhaseTimingSerializer(many=True, required=False)
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    total_seconds = serializers.IntegerField(read_only=True)
    total_minutes = serializers.IntegerField(read_only=True)

    class Meta:
        model = GroomSession
        fields = [
            'id', 'dog', 'dog_name', 'appointment', 'started_at', 'finished_at', 'notes',
            'timings', 'total_seconds', 'total_minutes', 'applied_to_dog_at', 'created_at',
        ]
        read_only_fields = ['id', 'applied_to_dog_at', 'created_at']

    def create(self, validated_data):
        timings = validated_data.pop('timings', [])
        session = GroomSession.objects.create(**validated_data)
        for timing in timings:
            PhaseTiming.objects.create(session=session, **timing)
        return session

    def update(self, instance, validated_data):
        timings = validated_data.pop('timings', None)
        for attr, value in validated_data.items():
            setattr(instance, attr, value)
        instance.save()
        if timings is not None:
            # Phases are a small fixed set; replacing them wholesale keeps the
            # client free to send whichever subset was actually used.
            instance.timings.all().delete()
            for timing in timings:
                PhaseTiming.objects.create(session=instance, **timing)
        return instance


# ── Money ──────────────────────────────────────────────────────────────

class InvoiceLineSerializer(serializers.ModelSerializer):
    line_total = serializers.DecimalField(max_digits=9, decimal_places=2, read_only=True)

    class Meta:
        model = InvoiceLine
        fields = ['id', 'appointment', 'description', 'quantity', 'unit_price', 'line_total']


class PaymentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Payment
        fields = ['id', 'invoice', 'amount', 'paid_at', 'method', 'reference', 'created_at']
        read_only_fields = ['id', 'created_at']


class InvoiceSerializer(serializers.ModelSerializer):
    lines = InvoiceLineSerializer(many=True, required=False)
    payments = PaymentSerializer(many=True, read_only=True)
    client_name = serializers.CharField(source='client.full_name', read_only=True)
    client_uid = serializers.CharField(source='client.uid', read_only=True)
    total = serializers.DecimalField(max_digits=9, decimal_places=2, read_only=True)
    amount_paid = serializers.DecimalField(max_digits=9, decimal_places=2, read_only=True)
    balance = serializers.DecimalField(max_digits=9, decimal_places=2, read_only=True)

    class Meta:
        model = Invoice
        fields = [
            'id', 'client', 'client_name', 'client_uid', 'number', 'issue_date', 'due_date',
            'status', 'notes', 'lines', 'payments', 'total', 'amount_paid', 'balance',
            'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']

    def create(self, validated_data):
        lines = validated_data.pop('lines', [])
        invoice = Invoice.objects.create(**validated_data)
        for line in lines:
            InvoiceLine.objects.create(invoice=invoice, **line)
        return invoice

    def update(self, instance, validated_data):
        lines = validated_data.pop('lines', None)
        for attr, value in validated_data.items():
            setattr(instance, attr, value)
        instance.save()
        if lines is not None:
            instance.lines.all().delete()
            for line in lines:
                InvoiceLine.objects.create(invoice=instance, **line)
        return instance


# ── Equipment / to-dos ─────────────────────────────────────────────────

class EquipmentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Equipment
        fields = [
            'id', 'name', 'uid', 'last_sharpened', 'pat_tested', 'pat_tested_date',
            'notes', 'is_active', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']


class TodoItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = TodoItem
        fields = ['id', 'text', 'is_done', 'due_date', 'sort_order', 'created_at', 'completed_at']
        read_only_fields = ['id', 'created_at', 'completed_at']


# ── Intake ─────────────────────────────────────────────────────────────

class IntakeInviteSerializer(serializers.ModelSerializer):
    is_usable = serializers.BooleanField(read_only=True)

    class Meta:
        model = IntakeInvite
        fields = ['id', 'client', 'email', 'token', 'expires_at', 'used_at', 'is_usable', 'created_at']
        read_only_fields = ['id', 'token', 'used_at', 'created_at']
        extra_kwargs = {'expires_at': {'required': False}}


class IntakeSubmissionSerializer(serializers.ModelSerializer):
    """Staff-facing view of a submitted intake form."""

    class Meta:
        model = IntakeSubmission
        fields = [
            'id', 'invite', 'first_name', 'last_name', 'email', 'phone', 'address', 'postcode',
            'dogs', 'status', 'review_notes', 'reviewed_at', 'created_client', 'created_at',
        ]
        read_only_fields = ['id', 'invite', 'status', 'reviewed_at', 'created_client', 'created_at']


class PublicIntakeSubmissionSerializer(serializers.ModelSerializer):
    """What an unauthenticated visitor may submit through an invite link.

    Deliberately narrow: no status, no review fields, no client link. Whoever
    holds the token can only lodge details for review, never touch live records.
    """

    class Meta:
        model = IntakeSubmission
        fields = ['first_name', 'last_name', 'email', 'phone', 'address', 'postcode', 'dogs']

    def validate_dogs(self, value):
        if not isinstance(value, list) or not value:
            raise serializers.ValidationError('Please tell us about at least one dog.')
        for index, dog in enumerate(value):
            if not isinstance(dog, dict):
                raise serializers.ValidationError(f'Dog {index + 1} is malformed.')
            if not str(dog.get('name', '')).strip():
                raise serializers.ValidationError(f'Dog {index + 1} needs a name.')
            for area in dog.get('problem_areas', []) or []:
                if not isinstance(area, dict):
                    raise serializers.ValidationError(f'Dog {index + 1} has a malformed problem area.')
                validate_grid_cells(area.get('grid_cells', []))
        return value
