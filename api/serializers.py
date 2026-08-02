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

import re
from decimal import Decimal

from django.conf import settings
from django.contrib.auth.models import User
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError as DjangoValidationError
from django.utils import timezone
from djoser.serializers import UserCreateSerializer as DjoserUserCreateSerializer
from rest_framework import serializers

from .models import (
    AppSettings,
    Appointment,
    AppointmentChangeRequest,
    AppointmentStatus,
    BookingSeries,
    Breed,
    Client,
    ClientChangeRequest,
    ClientClaimRequest,
    CLIENT_SELF_SERVICE_FIELDS,
    ClosureDay,
    Consent,
    ConsentKind,
    Dog,
    DogDocument,
    DogPhoto,
    Equipment,
    GroomSession,
    IntakeInvite,
    IntakeSubmission,
    Invoice,
    InvoiceLine,
    OpeningHours,
    PasswordResetRequest,
    PasswordResetToken,
    Payment,
    PhaseTiming,
    ProblemArea,
    REQUIRED_CONSENTS,
    Service,
    ServiceType,
    TemperamentGrade,
    temperament_label,
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
    # The app hides the account-management surface unless this is true, so it
    # has to come down with the rest of the identity rather than from a
    # separate call the login screen would have to wait on.
    is_superuser = serializers.BooleanField(read_only=True)
    client_id = serializers.SerializerMethodField()
    has_client_record = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = [
            'id', 'username', 'email', 'first_name', 'last_name',
            'is_staff', 'is_superuser', 'client_id', 'has_client_record',
        ]
        read_only_fields = ['id', 'username', 'is_staff', 'is_superuser']

    def get_client_id(self, obj):
        client = getattr(obj, 'client', None)
        return client.id if client else None

    def get_has_client_record(self, obj):
        return getattr(obj, 'client', None) is not None


USERNAME_PATTERN = re.compile(r'^[\w.@+-]+$')


class MojoUserCreateSerializer(DjoserUserCreateSerializer):
    """Registration — the one endpoint where a stranger writes to the User table.

    Three things beyond djoser's defaults, each from a way the old form went
    wrong in practice:

    * **Email is required and unique.** It was optional, so accounts arrived
      with no address at all — and an account with no email cannot be matched
      to a client record, cannot be sent a reset link, and gives Jess nothing
      to recognise the person by when they ask for help getting back in.
    * **Names and emails are compared case-insensitively.** Django's uniqueness
      is exact, so "Jess" and "jess" are two accounts. Nobody remembers which
      capitalisation they used, and :mod:`api.auth_backends` has to refuse to
      sign either of them in once both exist. Refusing the second registration
      is far kinder than the login failure it would otherwise cause.
    * **Passwords are checked against the account's own details.** Django's
      validators do this via ``UserAttributeSimilarityValidator``, but only
      when they can see the username and email, which is why they are passed
      an unsaved User below rather than run bare.
    """

    class Meta(DjoserUserCreateSerializer.Meta):
        model = User
        fields = ['id', 'username', 'email', 'password', 'first_name', 'last_name']
        extra_kwargs = {
            'email': {'required': True, 'allow_blank': False},
            'first_name': {'required': False},
            'last_name': {'required': False},
        }

    def validate_username(self, value):
        username = value.strip()
        if len(username) < 3:
            raise serializers.ValidationError('Pick a username of at least 3 characters.')
        if not USERNAME_PATTERN.match(username):
            raise serializers.ValidationError(
                'Usernames can use letters, numbers and . @ + - _ only.'
            )
        if User.objects.filter(username__iexact=username).exists():
            raise serializers.ValidationError('That username is taken. Try another.')
        return username

    def validate_email(self, value):
        email = value.strip()
        if User.objects.filter(email__iexact=email).exists():
            raise serializers.ValidationError(
                'There is already an account with that email address. '
                'Sign in with it, or ask Mojo and Co to send you a reset link.'
            )
        return email

    def validate(self, attrs):
        # Deliberately not calling super().validate(): djoser runs Django's
        # password validators against a User built from the username alone, so
        # a password containing the email address sails through. Building the
        # candidate here gives UserAttributeSimilarityValidator both.
        password = attrs.get('password') or ''
        candidate = User(
            username=attrs.get('username', ''),
            email=attrs.get('email', ''),
            first_name=attrs.get('first_name', ''),
            last_name=attrs.get('last_name', ''),
        )
        try:
            validate_password(password, candidate)
        except DjangoValidationError as error:
            raise serializers.ValidationError({'password': list(error.messages)})
        return attrs


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


# ── Accounts and passwords ─────────────────────────────────────────────

class AccountSerializer(serializers.ModelSerializer):
    """A login, as a superuser sees it when choosing who to send a link to.

    Read-only, and superuser-only at the view. ``client_name`` is what makes
    the list usable: Jess thinks in "Alice with the two cockapoos", not in
    usernames, and a list of bare logins is unmatchable against her clients.
    """

    client_name = serializers.SerializerMethodField()
    client_uid = serializers.SerializerMethodField()
    full_name = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = [
            'id', 'username', 'email', 'full_name', 'is_staff', 'is_superuser',
            'is_active', 'last_login', 'date_joined', 'client_name', 'client_uid',
        ]

    def get_full_name(self, obj):
        return obj.get_full_name()

    def get_client_name(self, obj):
        client = getattr(obj, 'client', None)
        return client.full_name if client else None

    def get_client_uid(self, obj):
        client = getattr(obj, 'client', None)
        return client.uid if client else None


class PasswordResetTokenSerializer(serializers.ModelSerializer):
    """A reset link's *record*, never the link itself.

    The token is the whole credential, so it is returned exactly once — in the
    response to the call that creates it — and this serializer, which backs the
    history list, deliberately has no field for it.
    """

    username = serializers.CharField(source='user.username', read_only=True)
    issued_by = serializers.CharField(source='created_by.username', read_only=True, default=None)
    is_usable = serializers.BooleanField(read_only=True)

    class Meta:
        model = PasswordResetToken
        fields = ['id', 'username', 'issued_by', 'sent_to', 'expires_at', 'used_at', 'is_usable', 'created_at']


class PasswordResetRequestSerializer(serializers.ModelSerializer):
    """A "I've forgotten my password" note, as staff see it."""

    username = serializers.CharField(source='user.username', read_only=True, default=None)
    email = serializers.CharField(source='user.email', read_only=True, default=None)
    client_name = serializers.SerializerMethodField()

    class Meta:
        model = PasswordResetRequest
        fields = [
            'id', 'identifier', 'note', 'username', 'email', 'client_name',
            'status', 'handled_at', 'created_at',
        ]
        read_only_fields = fields

    def get_client_name(self, obj):
        client = getattr(obj.user, 'client', None) if obj.user_id else None
        return client.full_name if client else None


class PublicPasswordResetRequestSerializer(serializers.Serializer):
    """What a signed-out person submits. Never echoed back to them.

    There is no ``user`` field and no confirmation of whether the identifier
    matched: the view answers identically either way, so this cannot be used to
    discover who has an account.
    """

    identifier = serializers.CharField(max_length=254)
    note = serializers.CharField(max_length=300, required=False, allow_blank=True, default='')

    def validate_identifier(self, value):
        identifier = value.strip()
        if not identifier:
            raise serializers.ValidationError('Enter the username or email you sign in with.')
        return identifier


class SetPasswordSerializer(serializers.Serializer):
    """A new password, arriving with a reset token instead of the old one.

    ``user`` comes from the token, not the request body — the password is
    validated against the account it is actually for, so someone cannot set
    their own username as their password by resetting from a link.
    """

    password = serializers.CharField(write_only=True)

    def validate_password(self, value):
        try:
            validate_password(value, self.context.get('user'))
        except DjangoValidationError as error:
            raise serializers.ValidationError(list(error.messages))
        return value


# ── Reference data ─────────────────────────────────────────────────────

class BreedSerializer(serializers.ModelSerializer):
    class Meta:
        model = Breed
        fields = ['id', 'name', 'coat_type', 'avg_groom_minutes', 'avg_price', 'avg_schedule_weeks', 'notes']


class ServiceSerializer(serializers.ModelSerializer):
    """One thing Jess does. Clients read this; only staff write it.

    Price and length stay **null** until she fills them in — her price list of
    28 July covers full grooms only, and there is no figure anywhere for the
    other twelve. A blank on screen is a prompt; an invented number is a wrong
    invoice.
    """

    class Meta:
        model = Service
        fields = [
            'id', 'code', 'name', 'category', 'default_minutes', 'default_price',
            'takes_dog_defaults', 'is_active', 'sort_order',
        ]
        # The code is the seed's natural key — renaming a service must not
        # make the next boot re-create the old row, which is the bug Breed has.
        read_only_fields = ['code']


class TemperamentGradeSerializer(serializers.ModelSerializer):
    # Deprecated alias for `label`, kept because the TestFlight build in Jess's
    # hands reads `temperament_display` on this endpoint and a backend deploy
    # reaches her long before an App Store one does. Remove once the build
    # that uses `label` has shipped.
    temperament_display = serializers.CharField(source='label', read_only=True)

    class Meta:
        model = TemperamentGrade
        fields = [
            'id', 'temperament', 'label', 'temperament_display',
            'max_per_day', 'sort_order',
        ]
        # The code identifies the row and every dog in the database points at
        # it. Jess edits the label and the cap; she does not get to repoint a
        # grade at a different code from the settings screen.
        read_only_fields = ['temperament']

    def validate_label(self, value):
        label = value.strip()
        if not label:
            raise serializers.ValidationError('Give the grade a name.')
        return label


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
            'invoicing_visible_to_clients', 'booking_slot_buffer_minutes',
            'nail_visit_minutes', 'nail_visit_price', 'updated_at',
        ]
        read_only_fields = ['updated_at']


# ── Clients ────────────────────────────────────────────────────────────

class ConsentSerializer(serializers.ModelSerializer):
    kind_display = serializers.CharField(source='get_kind_display', read_only=True)

    class Meta:
        model = Consent
        fields = ['id', 'kind', 'kind_display', 'agreed', 'signed_name', 'signed_at', 'wording']
        read_only_fields = ['id']


class ClientSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    # `uid` is Jess's filing reference off the paper cards, not a secret —
    # it is printed on the client's own booking card. Hiding it is a
    # presentation choice, not the same rule as the notes beside it, and
    # conflating the two would weaken the rule that actually matters.
    #
    # It reaches a client by four separate routes, so gating it here alone
    # would be cosmetic. See DogListSerializer and InvoiceSerializer.
    staff_only_fields = ('uid', 'chatty', 'leaflet_received', 'notes')

    full_name = serializers.CharField(read_only=True)
    dog_count = serializers.SerializerMethodField()
    has_login = serializers.SerializerMethodField()
    # Null means nobody has asked yet, which is not the same as "no".
    photo_consent = serializers.BooleanField(read_only=True, allow_null=True)
    consents = ConsentSerializer(many=True, read_only=True)

    class Meta:
        model = Client
        fields = [
            'id', 'uid', 'first_name', 'last_name', 'full_name', 'email', 'phone',
            'address', 'postcode', 'emergency_contact_name', 'emergency_contact_phone',
            'chatty', 'leaflet_received', 'notes',
            'photo_consent', 'consents', 'dog_count', 'has_login', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']

    def get_dog_count(self, obj):
        return obj.dogs.filter(is_active=True).count()

    def get_has_login(self, obj):
        return obj.user_id is not None


class ClientClaimRequestSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    # The suggested match is a *staff* hint and must not come back to the
    # claimant. Registration is open, so echoing it would turn this endpoint
    # into a lookup: submit any email or surname+postcode, read back whether
    # that person is one of Jess's clients and what they are called.
    #
    # This is the same rule PasswordResetRequestViewSet already follows by
    # answering identically whether or not the identifier matched. The claimant
    # still sees `status`, which is what the app polls to know it was approved.
    staff_only_fields = ('matched_client', 'matched_client_name')

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


class ClientChangeRequestSerializer(serializers.ModelSerializer):
    client_name = serializers.CharField(source='client.full_name', read_only=True)
    requested_by_username = serializers.CharField(
        source='requested_by.username', read_only=True,
    )

    class Meta:
        model = ClientChangeRequest
        fields = [
            'id', 'client', 'client_name', 'requested_by', 'requested_by_username',
            'changes', 'status', 'review_notes', 'reviewed_at', 'created_at',
        ]
        # `client` and `requested_by` come from the session, never the body:
        # accepting them would let any signed-in user lodge a request against
        # any client. `status` is decided by staff review.
        read_only_fields = [
            'id', 'client', 'requested_by', 'status', 'reviewed_at', 'created_at',
        ]

    def validate_changes(self, value):
        """Fence the blob before it is ever stored.

        Approval applies these with ``setattr``, so an unfenced key is an
        arbitrary write onto the client record — including Jess's staff-only
        notes, the UID her paper filing runs on, and the FK to the login. The
        model re-checks on the way out too; this is the layer that stops a bad
        request even existing.
        """
        if not isinstance(value, dict) or not value:
            raise serializers.ValidationError('Say what you would like changed.')

        unknown = sorted(set(value) - set(CLIENT_SELF_SERVICE_FIELDS))
        if unknown:
            raise serializers.ValidationError(
                f'These are not yours to change: {", ".join(unknown)}.'
            )

        cleaned = {}
        for field, raw in value.items():
            text = '' if raw is None else str(raw).strip()
            if field in ('first_name', 'last_name') and not text:
                raise serializers.ValidationError('A name cannot be blank.')
            cleaned[field] = text
        return cleaned


class AppointmentChangeRequestSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='appointment.dog.name', read_only=True)
    client_name = serializers.CharField(source='appointment.dog.client.full_name', read_only=True)
    client_phone = serializers.CharField(source='appointment.dog.client.phone', read_only=True)
    appointment_start_at = serializers.DateTimeField(source='appointment.start_at', read_only=True)
    appointment_status = serializers.CharField(source='appointment.status', read_only=True)
    requested_by_username = serializers.CharField(source='requested_by.username', read_only=True)

    class Meta:
        model = AppointmentChangeRequest
        fields = [
            'id', 'appointment', 'appointment_start_at', 'appointment_status',
            'dog_name', 'client_name', 'client_phone',
            'requested_by', 'requested_by_username',
            'kind', 'preferred_start_at', 'note',
            'status', 'review_notes', 'reviewed_at', 'created_at',
        ]
        # `requested_by` comes from the session and `status` from staff review.
        # `appointment` IS accepted from the body — a client has to say which
        # booking they mean — but the viewset checks it belongs to them before
        # saving. Ownership is not something a serializer can settle.
        read_only_fields = [
            'id', 'requested_by', 'status', 'reviewed_at', 'created_at',
        ]

    def validate(self, attrs):
        kind = attrs.get('kind')
        preferred = attrs.get('preferred_start_at')

        if kind == AppointmentChangeRequest.Kind.RESCHEDULE and preferred is None:
            raise serializers.ValidationError(
                {'preferred_start_at': 'Say roughly when you would like to come instead.'}
            )
        if preferred is not None and preferred <= timezone.now():
            # Not a warning, unlike the booking rules in scheduling.py: those
            # warn because Jess is the one deciding and she books outside her
            # own hours all the time. This is a client naming a date, and a
            # request to move to last Tuesday is a mistake, not a preference.
            raise serializers.ValidationError(
                {'preferred_start_at': 'Pick a time in the future.'}
            )

        appointment = attrs.get('appointment')
        if appointment is not None:
            if appointment.status in (AppointmentStatus.CANCELLED, AppointmentStatus.COMPLETED):
                raise serializers.ValidationError(
                    {'appointment': 'That booking is already finished or cancelled.'}
                )
            if appointment.start_at <= timezone.now():
                raise serializers.ValidationError(
                    {'appointment': 'That booking has already started. Please ring us instead.'}
                )
        return attrs


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


#: Extensions a scanned document may have. HEIC is real — Jess will
#: photograph the paper form on an iPhone.
ALLOWED_DOCUMENT_EXTENSIONS = ('pdf', 'jpg', 'jpeg', 'png', 'heic')

#: First bytes of a HEIC/HEIF file, at offset 4.
_HEIF_BRANDS = (b'ftypheic', b'ftypheix', b'ftyphevc', b'ftypmif1', b'ftypmsf1')


class AbsentMeansDefaultBooleanField(serializers.BooleanField):
    """A boolean whose *absence* means "use the default", even in form data.

    DRF's ``BooleanField.get_value`` deliberately returns ``False`` rather than
    ``empty`` for a missing key in an HTML form, because an unticked checkbox
    sends nothing. That is right for a browser form and wrong here: this
    endpoint is only multipart because it carries a file, and the app omits
    fields it isn't setting.

    Left alone, ``visible_to_client`` arrived as ``False`` on every upload —
    so every document Jess filed would have been invisible to the client,
    silently, which is the exact opposite of what the feature is for.
    """

    def get_value(self, dictionary):
        if self.field_name not in dictionary:
            return serializers.empty
        return super().get_value(dictionary)


class DogDocumentSerializer(serializers.ModelSerializer):
    download_url = serializers.SerializerMethodField()
    kind_display = serializers.CharField(source='get_kind_display', read_only=True)
    visible_to_client = AbsentMeansDefaultBooleanField(required=False, default=True)

    class Meta:
        model = DogDocument
        fields = [
            'id', 'dog', 'file', 'title', 'kind', 'kind_display', 'visible_to_client',
            'original_filename', 'content_type', 'size_bytes', 'download_url', 'created_at',
        ]
        read_only_fields = [
            'id', 'original_filename', 'content_type', 'size_bytes', 'created_at',
        ]
        # Write-only: a FileField serialises to a MEDIA_URL path, which would
        # 404 through Caddy (the file is not under MEDIA_ROOT) but still
        # disclose the storage layout. The gated download URL is the only way
        # out.
        extra_kwargs = {'file': {'write_only': True}}

    def get_download_url(self, obj):
        request = self.context.get('request')
        path = f'/api/dog-documents/{obj.pk}/download/'
        return request.build_absolute_uri(path) if request else path

    def validate_file(self, upload):
        """Check the bytes, not what the client claims they are.

        A browser's `Content-Type` is whatever the uploader's OS guessed, and
        an attacker sets it to anything. The magic bytes are the only thing
        that says what a file actually is.
        """
        if upload.size > settings.MAX_DOCUMENT_BYTES:
            megabytes = settings.MAX_DOCUMENT_BYTES // (1024 * 1024)
            raise serializers.ValidationError(
                f'That file is too big — {megabytes} MB is the limit.'
            )

        extension = (upload.name or '').rsplit('.', 1)[-1].lower()
        if extension not in ALLOWED_DOCUMENT_EXTENSIONS:
            raise serializers.ValidationError(
                'Attach a PDF or a photo (PDF, JPG, PNG or HEIC).'
            )

        head = upload.read(32)
        upload.seek(0)

        # SVG is refused by name *and* would fail the sniff below anyway. It is
        # called out because it is the dangerous one: it is scriptable, and a
        # browser rendering it inline from the download view would be stored
        # XSS on the API's own origin.
        if head.lstrip()[:5] in (b'<?xml', b'<svg '):
            raise serializers.ValidationError('SVG files are not accepted.')

        if extension == 'pdf':
            if not head.startswith(b'%PDF-'):
                raise serializers.ValidationError(
                    "That does not look like a PDF inside, whatever it is called."
                )
        elif extension == 'heic':
            if head[4:12] not in _HEIF_BRANDS:
                raise serializers.ValidationError(
                    'That does not look like a HEIC photo inside.'
                )
        else:
            from PIL import Image, UnidentifiedImageError

            try:
                # verify() only checks the header, and leaves the file unusable
                # afterwards — hence the seek back.
                Image.open(upload).verify()
            except (UnidentifiedImageError, OSError, ValueError):
                raise serializers.ValidationError(
                    'That does not look like an image inside, whatever it is called.'
                )
            finally:
                upload.seek(0)

        return upload

    def create(self, validated_data):
        upload = validated_data['file']
        validated_data['original_filename'] = (upload.name or '')[:255]
        validated_data['content_type'] = (getattr(upload, 'content_type', '') or '')[:100]
        validated_data['size_bytes'] = upload.size
        return super().create(validated_data)


class DogListSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    """The Doguments row: a whole-profile summary at a glance.

    Carries the denormalised owner fields the list needs so the app renders
    without a second request per dog.
    """

    staff_only_fields = ('temperament', 'temperament_display', 'client_uid')

    client_uid = serializers.CharField(source='client.uid', read_only=True)
    client_first_name = serializers.CharField(source='client.first_name', read_only=True)
    client_full_name = serializers.CharField(source='client.full_name', read_only=True)
    client_phone = serializers.CharField(source='client.phone', read_only=True)
    breed_label = serializers.CharField(read_only=True)
    # Jess's own wording for the grade, not the frozen enum label — she
    # renames these in Settings. See models.temperament_label.
    temperament_display = serializers.SerializerMethodField()
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

    def get_temperament_display(self, obj):
        return temperament_label(obj.temperament)


class DogSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    staff_only_fields = ('temperament', 'temperament_display', 'temperament_notes', 'problem_areas')

    client_detail = ClientSerializer(source='client', read_only=True)
    breed_label = serializers.CharField(read_only=True)
    # Jess's own wording for the grade, not the frozen enum label — she
    # renames these in Settings. See models.temperament_label.
    temperament_display = serializers.SerializerMethodField()
    problem_areas = ProblemAreaSerializer(many=True, read_only=True)
    # What this dog usually has. Not staff-only — it is what the owner asked
    # for, and a client needs it to request the right kind of booking.
    default_services_detail = ServiceSerializer(
        source='default_services', many=True, read_only=True,
    )
    groom_minutes_effective = serializers.IntegerField(source='effective_groom_minutes', read_only=True)
    price_effective = serializers.DecimalField(
        source='effective_price', max_digits=7, decimal_places=2, read_only=True,
    )
    schedule_weeks_effective = serializers.IntegerField(source='effective_schedule_weeks', read_only=True)

    class Meta:
        model = Dog
        fields = [
            'id', 'client', 'client_detail', 'name', 'breed', 'breed_other', 'breed_label',
            'date_of_birth', 'sex', 'is_neutered', 'colour', 'microchip_number', 'profile_image',
            'temperament', 'temperament_display', 'temperament_notes',
            'groom_minutes', 'price', 'schedule_weeks',
            'groom_minutes_effective', 'price_effective', 'schedule_weeks_effective',
            'pref_body', 'pref_feet', 'pref_tail', 'pref_face', 'pref_ears', 'pref_skirt',
            'default_services', 'default_services_detail',
            'allergies', 'medications', 'medical_issues', 'vaccinations',
            'medical_notes', 'vet', 'last_vet_visit', 'owner_grooming',
            'general_notes', 'is_active',
            'problem_areas', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']

    def get_temperament_display(self, obj):
        return temperament_label(obj.temperament)


# ── Scheduling ─────────────────────────────────────────────────────────

class AppointmentSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    # A client seeing their own booking has no business seeing the handling
    # notes Jess keeps about their dog.
    staff_only_fields = ('dog_temperament', 'dog_temperament_display')

    dog_name = serializers.CharField(source='dog.name', read_only=True)
    dog_temperament = serializers.CharField(source='dog.temperament', read_only=True)
    # The code alone left the diary's badges showing the seed wording after
    # Jess renamed a grade — the calendar had nothing else to draw with.
    dog_temperament_display = serializers.SerializerMethodField()
    services_detail = ServiceSerializer(source='services', many=True, read_only=True)
    client_id = serializers.IntegerField(source='dog.client_id', read_only=True)
    client_name = serializers.CharField(source='dog.client.full_name', read_only=True)
    client_phone = serializers.CharField(source='dog.client.phone', read_only=True)
    duration_minutes = serializers.IntegerField(read_only=True)

    class Meta:
        model = Appointment
        fields = [
            'id', 'dog', 'dog_name', 'dog_temperament', 'dog_temperament_display',
            'client_id', 'client_name', 'client_phone',
            'start_at', 'end_at', 'duration_minutes', 'booking_type', 'service_type', 'status',
            'services', 'services_detail',
            'price_quoted', 'notes', 'series', 'created_at', 'updated_at',
        ]
        # end_at is optional on input — the model fills it from the dog's groom
        # time when omitted.
        extra_kwargs = {'end_at': {'required': False}}

    def get_dog_temperament_display(self, obj):
        return temperament_label(obj.dog.temperament)

    def create(self, validated_data):
        """Save, attach the services, then re-derive from them.

        The order matters and is not negotiable: `Appointment.save()` cannot
        read `self.services` on a create — there is no pk yet — so the length
        and quote it works out come from an empty list. They are recomputed
        once the relation exists.

        `force_*` is False for anything the caller actually sent, so a start
        and end time Jess typed, or a price she overrode, is never replaced by
        a computed one.
        """
        sent_end = 'end_at' in validated_data
        sent_price = 'price_quoted' in validated_data
        appointment = super().create(validated_data)
        if appointment.services.exists():
            appointment.apply_service_defaults(
                force_end=not sent_end, force_price=not sent_price,
            )
        return appointment

    def update(self, instance, validated_data):
        sent_end = 'end_at' in validated_data
        sent_price = 'price_quoted' in validated_data
        # Whether the services changed at all — re-deriving on an unrelated
        # edit (a note, a status) would overwrite figures Jess had adjusted.
        touched_services = 'services' in validated_data
        appointment = super().update(instance, validated_data)
        if touched_services:
            appointment.apply_service_defaults(
                force_end=not sent_end, force_price=not sent_price,
            )
        return appointment
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
    service_type = serializers.ChoiceField(
        choices=ServiceType.choices, required=False, default=ServiceType.GROOM,
    )
    services = serializers.PrimaryKeyRelatedField(
        queryset=Service.objects.all(), many=True, required=False,
        help_text='What is being done. Drives the suggested length and price.',
    )


# ── Groom timing ───────────────────────────────────────────────────────

class EquipmentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Equipment
        fields = [
            'id', 'name', 'uid', 'last_sharpened', 'pat_tested', 'pat_tested_date',
            'notes', 'is_active', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']


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

    visit_type_display = serializers.CharField(source='get_visit_type_display', read_only=True)
    temperament_observed_display = serializers.CharField(
        source='get_temperament_observed_display', read_only=True,
    )
    matting_found = serializers.BooleanField(read_only=True)
    equipment_used_detail = EquipmentSerializer(source='equipment_used', many=True, read_only=True)

    class Meta:
        model = GroomSession
        fields = [
            'id', 'dog', 'dog_name', 'appointment', 'visit_type', 'visit_type_display',
            'started_at', 'finished_at', 'recorded_minutes',
            'health_check_notes',
            'matting_paws', 'matting_armpits', 'matting_ears', 'matting_elsewhere',
            'matting_notes', 'matting_found',
            'bathed_well_behaved', 'high_velocity_dryer', 'shampoo_used',
            'equipment_used', 'equipment_used_detail',
            'final_body', 'final_feet', 'final_tail',
            'nails_done', 'fleas_treated', 'ticks_removed',
            'notes', 'sensitive_notes',
            'temperament_observed', 'temperament_observed_display',
            'timings', 'total_seconds', 'total_minutes', 'applied_to_dog_at', 'created_at',
        ]
        read_only_fields = ['id', 'applied_to_dog_at', 'created_at']

    def validate(self, attrs):
        """A nails visit has to say which of the three it was for.

        Otherwise the record says a visit happened and nothing about what was
        done, which is the one thing that card exists to capture.
        """
        visit_type = attrs.get(
            'visit_type', getattr(self.instance, 'visit_type', ServiceType.GROOM),
        )
        if visit_type != ServiceType.NAILS_FLEAS_TICKS:
            return attrs

        def flag(name):
            return attrs.get(name, getattr(self.instance, name, False))

        if not any(flag(name) for name in ('nails_done', 'fleas_treated', 'ticks_removed')):
            raise serializers.ValidationError(
                {'nails_done': 'Say whether this was nails, fleas or ticks.'},
            )
        return attrs

    def create(self, validated_data):
        timings = validated_data.pop('timings', [])
        equipment = validated_data.pop('equipment_used', None)
        session = GroomSession.objects.create(**validated_data)
        if equipment is not None:
            session.equipment_used.set(equipment)
        for timing in timings:
            PhaseTiming.objects.create(session=session, **timing)
        return session

    def update(self, instance, validated_data):
        timings = validated_data.pop('timings', None)
        equipment = validated_data.pop('equipment_used', None)
        for attr, value in validated_data.items():
            setattr(instance, attr, value)
        instance.save()
        if equipment is not None:
            instance.equipment_used.set(equipment)
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


class InvoiceSerializer(StaffOnlyFieldsMixin, serializers.ModelSerializer):
    # Reachable by a client once `invoicing_visible_to_clients` is on, so the
    # UID has to be gated on this route too.
    staff_only_fields = ('client_uid',)

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
            'status', 'sent_at', 'paid_at', 'notes', 'lines', 'payments',
            'total', 'amount_paid', 'balance', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']

    def validate_status(self, value):
        """Refuse a move the lifecycle does not allow.

        Here as well as on the actions, because `status` is a plain writable
        field and the app has always PATCHed it directly — enforcing the rule
        only inside `mark_sent`/`mark_paid` would leave the front door open.
        """
        if self.instance is None:
            return value
        if not self.instance.can_transition_to(value):
            current = self.instance.get_status_display().lower()
            raise serializers.ValidationError(
                f'This invoice is {current}. It cannot go back to '
                f'{Invoice.Status(value).label.lower()} from there.'
            )
        return value

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
            'emergency_contact_name', 'emergency_contact_phone',
            'dogs', 'consents', 'signature',
            'status', 'review_notes', 'reviewed_at', 'created_client', 'created_at',
        ]
        read_only_fields = ['id', 'invite', 'status', 'reviewed_at', 'created_client', 'created_at']


class PublicIntakeSubmissionSerializer(serializers.ModelSerializer):
    """What an unauthenticated visitor may submit through an invite link.

    Deliberately narrow: no status, no review fields, no client link. Whoever
    holds the token can only lodge details for review, never touch live records.
    """

    class Meta:
        model = IntakeSubmission
        fields = [
            'first_name', 'last_name', 'email', 'phone', 'address', 'postcode',
            'emergency_contact_name', 'emergency_contact_phone',
            'dogs', 'consents', 'signature',
        ]

    def validate_consents(self, value):
        """Every disclaimer bar the photo one has to be agreed to.

        Enforced here rather than only in the page's JavaScript, because the
        endpoint is public and the page is not the only thing that can post to
        it. The photo question is deliberately absent from the check — it is
        optional on the paper card too, and declining it must still let the
        form through.
        """
        if not isinstance(value, dict):
            raise serializers.ValidationError('Malformed consents.')
        missing = [kind for kind in REQUIRED_CONSENTS if value.get(kind) is not True]
        if missing:
            labels = ', '.join(ConsentKind(kind).label for kind in missing)
            raise serializers.ValidationError(f'Please agree to: {labels}')
        return value

    def validate(self, attrs):
        # The signature only means anything next to the consents, so it is
        # checked here rather than as a field-level requirement.
        if not str(attrs.get('signature', '')).strip():
            raise serializers.ValidationError(
                {'signature': 'Please type your name to sign the form.'},
            )
        if not attrs.get('consents'):
            raise serializers.ValidationError(
                {'consents': 'Please read and agree to the terms before sending.'},
            )
        return attrs

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
