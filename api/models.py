"""Domain model for the Mojo & Co grooming business.

Three conventions run through this file and matter for security:

* Fields commented ``STAFF ONLY`` are stripped from API responses for
  non-staff users (see ``api/serializers.py``). They are Jess's private
  working notes — temperament, whether an owner is chatty — and must never
  reach a client.
* A ``Client`` exists independently of a ``User``. Jess creates client records
  from day one; the client may later claim the record by signing up and
  proving their name/email/postcode (``ClientClaimRequest``).
* Dogs inherit groom time, price and schedule interval from their ``Breed``
  unless explicitly overridden. Always read through ``effective_*``.
"""

import secrets
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.contrib.auth.models import User
from django.core.cache import cache
from django.core.validators import MinValueValidator
from django.db import models
from django.db.models.signals import post_save
from django.dispatch import receiver
from django.utils import timezone


# ── Choice vocabularies ────────────────────────────────────────────────

class Temperament(models.TextChoices):
    """The five handling grades, by code.

    Jess asked for five rather than three — "may up bitey not hard" — because
    the old middle grade, "Fidgety / bitey", was doing two jobs at once.

    **The labels here are seed defaults, not the labels the app shows.** Jess
    renames grades herself in Settings, so the wording lives on
    :class:`TemperamentGrade` rows in the database. Read a label with
    :func:`temperament_label`; ``get_temperament_display()`` would return this
    frozen wording and quietly contradict what she has on screen.

    The *codes* are permanent. Every ``Dog.temperament`` and
    ``GroomSession.temperament_observed`` stores one, so changing a code means
    rewriting history; changing a label means changing a word.
    """

    EASY = 'EASY', 'Easy'
    WRIGGLY = 'WRIGGLY', 'Wriggly, but fine'
    FIDGETY = 'FIDGETY', 'Fidgety'
    BITEY = 'BITEY', 'Bitey, not hard'
    FEISTY = 'FEISTY', 'Feisty / hard'


#: Easiest to hardest. ``TextChoices`` has no inherent order, and at five
#: grades the order is the whole point — a list sorted alphabetically reads
#: BITEY, EASY, FEISTY, FIDGETY, WRIGGLY, which is nonsense to look at.
TEMPERAMENT_ORDER = {
    Temperament.EASY: 1,
    Temperament.WRIGGLY: 2,
    Temperament.FIDGETY: 3,
    Temperament.BITEY: 4,
    Temperament.FEISTY: 5,
}


class GroomPhase(models.TextChoices):
    PREP = 'PREP', 'Prep'
    WASH = 'WASH', 'Wash'
    DRY = 'DRY', 'Dry'
    CLIP = 'CLIP', 'Clip'
    STRIP = 'STRIP', 'Strip'


class BookingType(models.TextChoices):
    FIRST_GROOM = 'FIRST_GROOM', 'First groom'
    ADHOC = 'ADHOC', 'Ad hoc'
    SCHEDULED = 'SCHEDULED', 'Scheduled'


# Only used to give a nails booking *some* length when Jess hasn't set one
# yet — a diary block of zero minutes would be invisible. It is never used as
# a price: an unset price stays unset, and the booking warns instead.
FALLBACK_NAIL_VISIT_MINUTES = 20


class ServiceType(models.TextChoices):
    """What the visit is for, as opposed to :class:`BookingType`, which is why.

    Jess keeps two separate record cards, and the second one is the only
    evidence that Mojo and Co sells anything but a full groom. A nails, flea or
    tick visit is minutes rather than hours, so it cannot inherit the dog's
    groom time or price — see ``AppSettings.nail_visit_minutes``.
    """

    GROOM = 'GROOM', 'Groom'
    NAILS_FLEAS_TICKS = 'NAILS', 'Nails, fleas or ticks'


class AppointmentStatus(models.TextChoices):
    REQUESTED = 'REQUESTED', 'Requested'
    BOOKED = 'BOOKED', 'Booked'
    CONFIRMED = 'CONFIRMED', 'Confirmed'
    IN_PROGRESS = 'IN_PROGRESS', 'In progress'
    COMPLETED = 'COMPLETED', 'Completed'
    CANCELLED = 'CANCELLED', 'Cancelled'
    NO_SHOW = 'NO_SHOW', 'No show'


class ReviewStatus(models.TextChoices):
    PENDING = 'PENDING', 'Pending'
    APPROVED = 'APPROVED', 'Approved'
    REJECTED = 'REJECTED', 'Rejected'


class ConsentKind(models.TextChoices):
    """The six disclaimers on the paper booking card.

    The wording here is what the client sees and what gets recorded against
    their name, so it is deliberately plain rather than a paraphrase of the
    card — but it says the same things.
    """

    POLICIES = 'policies', 'I have read and agree to the grooming policies and the privacy policy'
    ACCURACY = 'accuracy', 'These details are right, and I will tell you if anything changes'
    MATTING = 'matting', 'If my dog is badly matted, the coat may have to come off entirely'
    RESTRAINT = 'restraint', 'A collar or muzzle may be used if my dog will not settle'
    VET = 'vet', 'In an emergency a vet will be contacted, and treatment is at my cost'
    PHOTOS = 'photos', 'Photos of my dog may be used on the website and social media'


# Five of the six are conditions of being groomed at all. PHOTOS is the only
# one phrased as a question on the card, and it is genuinely optional —
# declining it must not block the form.
REQUIRED_CONSENTS = [
    ConsentKind.POLICIES,
    ConsentKind.ACCURACY,
    ConsentKind.MATTING,
    ConsentKind.RESTRAINT,
    ConsentKind.VET,
]


WEEKDAY_CHOICES = [
    (0, 'Monday'),
    (1, 'Tuesday'),
    (2, 'Wednesday'),
    (3, 'Thursday'),
    (4, 'Friday'),
    (5, 'Saturday'),
    (6, 'Sunday'),
]


# ── Staff ──────────────────────────────────────────────────────────────

class UserProfile(models.Model):
    """Per-user settings and capability flags.

    Capability flags are assignable ONLY by a superuser. They must never be
    writable through the self-service profile endpoint, or any authenticated
    user could grant themselves manager capabilities.
    """

    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name='profile')
    phone = models.CharField(max_length=20, blank=True)
    profile_photo = models.ImageField(upload_to='staff_photos/', null=True, blank=True)

    can_manage_clients = models.BooleanField(default=False, help_text='Create and edit client and dog records.')
    can_manage_bookings = models.BooleanField(default=False, help_text='Create, move and cancel appointments.')
    can_manage_invoices = models.BooleanField(default=False, help_text='Raise invoices and record payments.')
    can_manage_equipment = models.BooleanField(default=False, help_text='Maintain the equipment register.')
    can_manage_settings = models.BooleanField(default=False, help_text='Change opening hours, temperament limits and app settings.')

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f'Profile for {self.user.username}'


@receiver(post_save, sender=User)
def ensure_user_profile(sender, instance, created, **kwargs):
    """Every user has a profile; staff created via the admin get one too."""
    if created:
        UserProfile.objects.get_or_create(user=instance)


# ── Clients ────────────────────────────────────────────────────────────

class Client(models.Model):
    """A dog owner. Exists whether or not they have signed up for a login."""

    uid = models.CharField(
        max_length=32,
        unique=True,
        help_text="Jess's own reference for this client, e.g. MOJO-014. Editable by staff.",
    )
    first_name = models.CharField(max_length=100)
    last_name = models.CharField(max_length=100, blank=True)
    email = models.EmailField(blank=True)
    phone = models.CharField(max_length=20, blank=True)
    address = models.TextField(blank=True)
    postcode = models.CharField(max_length=10, blank=True)

    # "Additional contact name and number (ICE)" on the paper booking card —
    # who to ring if the owner can't be reached while their dog is here.
    emergency_contact_name = models.CharField(max_length=100, blank=True)
    emergency_contact_phone = models.CharField(max_length=20, blank=True)

    # Set when the client signs up and their claim is approved. Until then the
    # record is staff-maintained only.
    user = models.OneToOneField(
        User, on_delete=models.SET_NULL, null=True, blank=True, related_name='client',
    )

    # STAFF ONLY — Jess's working notes. Never serialised for a client.
    chatty = models.BooleanField(
        default=False,
        help_text='This owner likes a chat — allow extra time at drop-off/collection. Hidden from clients.',
    )
    leaflet_received = models.BooleanField(default=False, help_text='Has been given the welcome leaflet.')
    notes = models.TextField(blank=True, help_text='Private staff notes about this client. Hidden from clients.')

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['first_name', 'last_name']
        indexes = [models.Index(fields=['uid']), models.Index(fields=['phone'])]

    def __str__(self):
        return f'{self.full_name} ({self.uid})'

    @property
    def full_name(self):
        return f'{self.first_name} {self.last_name}'.strip()

    @property
    def photo_consent(self):
        """Has this client agreed to photos being used publicly?

        ``None`` means nobody has ever asked — which is not the same as "no",
        and is why this is nullable rather than a boolean defaulting to False.
        Anything about to publish a photo must treat None as "don't".
        """
        latest = self.consents.filter(kind=ConsentKind.PHOTOS).first()
        return latest.agreed if latest else None

    UID_PREFIX = 'MOJO-'

    @classmethod
    def next_uid(cls):
        """The next free UID in the MOJO-### series.

        Only used where staff leave the field blank — Jess numbers her own
        clients and nothing here overrides a UID she has typed.

        UIDs outside the series are ignored rather than parsed: there is a live
        record numbered "1337", and letting a one-off like that set the
        sequence would push every later client into the wrong range. Counting
        only MOJO-### keeps the generated run predictable no matter what else
        is in the table.

        Always one past the highest, so gaps left by deleted clients stay gaps
        rather than being handed to somebody new.
        """
        highest = 0
        existing = cls.objects.filter(uid__istartswith=cls.UID_PREFIX)
        for uid in existing.values_list('uid', flat=True):
            suffix = uid[len(cls.UID_PREFIX):]
            if suffix.isdigit():
                highest = max(highest, int(suffix))
        return f'{cls.UID_PREFIX}{highest + 1:03d}'


class Consent(models.Model):
    """One disclaimer, agreed or declined, with who signed it and when.

    The paper booking card has each of the six signed and dated separately, so
    these are rows rather than booleans on Client. Two reasons that matters:
    what somebody agreed to *on the day* is the record, and the wording of a
    policy changes over time — a boolean would quietly claim they had agreed to
    whatever the current text says. A change of mind is a new row, and
    ``photo_consent`` reads the latest.

    Nothing here is deleted when consent is withdrawn, for the same reason.
    """

    client = models.ForeignKey(Client, on_delete=models.CASCADE, related_name='consents')
    kind = models.CharField(max_length=20, choices=ConsentKind.choices)
    agreed = models.BooleanField()
    signed_name = models.CharField(
        max_length=120,
        help_text='Typed by the client on the form — the web equivalent of a signature.',
    )
    signed_at = models.DateTimeField(
        default=timezone.now,
        help_text='When it was agreed. Defaults to now, but a card signed on paper keeps its own date.',
    )
    wording = models.TextField(
        blank=True,
        help_text='The text as it was shown at the time, so a later rewording cannot rewrite history.',
    )

    class Meta:
        ordering = ['-signed_at']
        indexes = [models.Index(fields=['client', 'kind'])]

    def __str__(self):
        return f'{self.client.full_name}: {self.get_kind_display()} — {"yes" if self.agreed else "no"}'


class ClientClaimRequest(models.Model):
    """A signed-up user asking to be linked to an existing client record.

    They prove themselves with name, email and postcode; staff review the
    match before the link is made, since approving grants access to that
    client's dogs, bookings and invoices.
    """

    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='claim_requests')
    claimed_name = models.CharField(max_length=200)
    claimed_email = models.EmailField()
    claimed_postcode = models.CharField(max_length=10)

    matched_client = models.ForeignKey(
        Client, on_delete=models.SET_NULL, null=True, blank=True, related_name='claim_requests',
        help_text='Best server-side match, for staff to confirm or override.',
    )
    status = models.CharField(max_length=10, choices=ReviewStatus.choices, default=ReviewStatus.PENDING)
    reviewed_by = models.ForeignKey(
        User, on_delete=models.SET_NULL, null=True, blank=True, related_name='reviewed_claims',
    )
    reviewed_at = models.DateTimeField(null=True, blank=True)
    review_notes = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'Claim by {self.user.username} → {self.matched_client or "unmatched"} ({self.status})'


# ── Passwords ──────────────────────────────────────────────────────────

def generate_reset_token():
    return secrets.token_urlsafe(32)


class PasswordResetToken(models.Model):
    """A single-use link that sets a new password without knowing the old one.

    Issued by a superuser from the app, or from the command line when nobody
    can get in at all (``manage.py reset_link``). Like an intake invite, the
    token *is* the credential: single-use, time-limited, and long enough not to
    be guessable — so it is never listed back out of the API after the moment
    it is created.

    Issuing a new one voids the user's outstanding tokens, and using one drops
    their API tokens, so a reset also signs the account out everywhere. That
    matters when the reason for the reset is "someone else has my password".
    """

    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='password_reset_tokens')
    token = models.CharField(max_length=64, unique=True, default=generate_reset_token)
    expires_at = models.DateTimeField()
    used_at = models.DateTimeField(null=True, blank=True)
    created_by = models.ForeignKey(
        User, on_delete=models.SET_NULL, null=True, blank=True, related_name='issued_password_resets',
        help_text='The superuser who issued it. Blank when issued from the command line.',
    )
    sent_to = models.EmailField(
        blank=True, help_text='Where the link was emailed, when email is configured.',
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'Password reset for {self.user.username}'

    def save(self, *args, **kwargs):
        if not self.expires_at:
            self.expires_at = timezone.now() + timedelta(hours=settings.PASSWORD_RESET_TTL_HOURS)
        super().save(*args, **kwargs)

    @property
    def is_usable(self):
        return self.used_at is None and self.expires_at > timezone.now()

    @classmethod
    def issue(cls, user, created_by=None):
        """Void any outstanding links for this user, then mint a fresh one."""
        cls.objects.filter(user=user, used_at__isnull=True).update(used_at=timezone.now())
        return cls.objects.create(user=user, created_by=created_by)


class PasswordResetRequest(models.Model):
    """Someone signed out saying they have forgotten their password.

    There is no automated email path in this deployment, so a request is not a
    reset — it is a note that lands in the app for Jess, who checks it is really
    them and issues a link. That is the honest shape for a one-groomer business
    where she knows every client by name.

    ``identifier`` is whatever they typed. ``user`` is resolved server-side and
    is never echoed back to the person who asked: the public endpoint answers
    identically whether or not the account exists, so it cannot be used to find
    out who has an account.
    """

    class Status(models.TextChoices):
        PENDING = 'PENDING', 'Pending'
        SENT = 'SENT', 'Link sent'
        DISMISSED = 'DISMISSED', 'Dismissed'

    identifier = models.CharField(max_length=254, help_text='The username or email they typed.')
    user = models.ForeignKey(
        User, on_delete=models.CASCADE, null=True, blank=True, related_name='password_reset_requests',
        help_text='Resolved from the identifier. Null when nothing matched.',
    )
    note = models.CharField(max_length=300, blank=True, help_text='Anything they added, e.g. a phone number.')
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.PENDING)
    handled_by = models.ForeignKey(
        User, on_delete=models.SET_NULL, null=True, blank=True, related_name='handled_password_resets',
    )
    handled_at = models.DateTimeField(null=True, blank=True)
    issued_token = models.ForeignKey(
        PasswordResetToken, on_delete=models.SET_NULL, null=True, blank=True, related_name='requests',
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'Password help for {self.identifier} ({self.status})'


# ── Breeds and dogs ────────────────────────────────────────────────────

class Breed(models.Model):
    """Reference data: what a typical groom of this breed takes and costs.

    Seeded by ``manage.py seed_breeds`` with general grooming estimates. These
    are starting points — Jess edits them to match her own pricing.
    """

    name = models.CharField(max_length=120, unique=True)
    coat_type = models.CharField(max_length=60, blank=True, help_text='e.g. double, curly, wire, smooth.')
    avg_groom_minutes = models.PositiveIntegerField(help_text='Typical full groom time in minutes.')
    avg_price = models.DecimalField(max_digits=7, decimal_places=2, help_text='Typical full groom price in GBP.')
    avg_schedule_weeks = models.PositiveIntegerField(help_text='Typical interval between grooms, in weeks.')
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ['name']

    def __str__(self):
        return self.name


class Dog(models.Model):
    SEX_CHOICES = [('M', 'Male'), ('F', 'Female')]

    client = models.ForeignKey(Client, on_delete=models.CASCADE, related_name='dogs')
    name = models.CharField(max_length=100)
    breed = models.ForeignKey(Breed, on_delete=models.SET_NULL, null=True, blank=True, related_name='dogs')
    breed_other = models.CharField(
        max_length=120, blank=True,
        help_text='Free text when the breed is a cross or not on the list.',
    )
    date_of_birth = models.DateField(null=True, blank=True)
    sex = models.CharField(max_length=1, choices=SEX_CHOICES, blank=True)
    # Three states, not two: null is "never asked", which is not the same as
    # "intact". It defaulted to False, so a dog nobody had asked about was
    # indistinguishable from one confirmed entire — and the profile would have
    # labelled every one of them "Intact". Same rule as photo_consent and
    # bathed_well_behaved: null is not false, on both sides of the wire.
    is_neutered = models.BooleanField(null=True, blank=True, default=None)
    colour = models.CharField(max_length=60, blank=True)
    microchip_number = models.CharField(max_length=30, blank=True)
    profile_image = models.ImageField(upload_to='dog_profiles/', null=True, blank=True)

    # STAFF ONLY — drives the per-day booking limits. Never shown to clients.
    temperament = models.CharField(
        max_length=10, choices=Temperament.choices, default=Temperament.EASY,
        help_text='Handling difficulty. Drives the per-day booking limit. Hidden from clients.',
    )
    temperament_notes = models.TextField(blank=True, help_text='How to handle this dog. Hidden from clients.')

    # Overrides for the breed averages. Null means "use the breed's value".
    groom_minutes = models.PositiveIntegerField(
        null=True, blank=True,
        help_text='Overrides the breed average. Blank = use the breed default.',
    )
    price = models.DecimalField(
        max_digits=7, decimal_places=2, null=True, blank=True,
        help_text='Overrides the breed average price. Blank = use the breed default.',
    )
    schedule_weeks = models.PositiveIntegerField(
        null=True, blank=True,
        help_text='Overrides the breed average grooming interval. Blank = use the breed default.',
    )

    # Grooming preferences, one free-text note per area.
    pref_body = models.TextField(blank=True, verbose_name='Body')
    pref_feet = models.TextField(blank=True, verbose_name='Feet shape')
    pref_tail = models.TextField(blank=True, verbose_name='Tail')
    pref_face = models.TextField(blank=True, verbose_name='Face')
    pref_ears = models.TextField(blank=True, verbose_name='Ears')
    pref_skirt = models.TextField(blank=True, verbose_name='Skirt')

    # The paper booking card asks these as separate yes/no-and-explain
    # questions rather than one "anything medical?" box, because a groomer
    # needs to see an allergy without reading a paragraph to find it.
    # ``medical_notes`` stays for anything that doesn't fit the three.
    allergies = models.TextField(blank=True)
    medications = models.TextField(blank=True)
    medical_issues = models.TextField(blank=True, verbose_name='Known medical issues')
    vaccinations = models.TextField(blank=True, help_text='Which vaccinations, and when.')
    medical_notes = models.TextField(blank=True)
    vet = models.TextField(blank=True, help_text='Practice name, address and phone number.')
    last_vet_visit = models.TextField(blank=True, help_text='What the last vet trip was for.')
    owner_grooming = models.TextField(
        blank=True,
        help_text='What the owner does themselves between grooms, and how often.',
    )
    general_notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['name']
        indexes = [models.Index(fields=['name'])]

    def __str__(self):
        return f'{self.name} ({self.client.full_name})'

    # The three ``effective_*`` properties are the only correct way to read
    # these values — a bare ``dog.price`` is null whenever the breed default
    # applies, which is the common case.

    @property
    def effective_groom_minutes(self):
        if self.groom_minutes is not None:
            return self.groom_minutes
        if self.breed_id:
            return self.breed.avg_groom_minutes
        return 90  # Fallback for an unknown breed with no override.

    @property
    def effective_price(self):
        if self.price is not None:
            return self.price
        if self.breed_id:
            return self.breed.avg_price
        return Decimal('0.00')

    @property
    def effective_schedule_weeks(self):
        if self.schedule_weeks is not None:
            return self.schedule_weeks
        if self.breed_id:
            return self.breed.avg_schedule_weeks
        return 8

    @property
    def breed_label(self):
        """What to show in a list row — the breed, or the free-text fallback."""
        if self.breed_id:
            return self.breed.name
        return self.breed_other or 'Unknown breed'


class ProblemArea(models.Model):
    """A marked-up region of the dog with a reason.

    STAFF ONLY on the dog profile, but clients fill these in on the intake
    form — that's the one place an owner supplies the information.

    ``grid_cells`` holds cell references over a fixed 12x8 grid laid on a
    side-profile dog silhouette, as ``r{row}c{col}`` strings (0-indexed).
    Storing references rather than pixel coordinates keeps the markup valid at
    any render size.
    """

    GRID_COLUMNS = 12
    GRID_ROWS = 8

    class Source(models.TextChoices):
        STAFF = 'STAFF', 'Added by staff'
        INTAKE = 'INTAKE', 'From intake form'

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='problem_areas')
    grid_cells = models.JSONField(default=list, help_text='Selected silhouette cells, e.g. ["r3c5", "r3c6"].')
    reason = models.TextField(help_text='Why this area is marked — sore, matted, dislikes being touched, etc.')
    source = models.CharField(max_length=10, choices=Source.choices, default=Source.STAFF)
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='problem_areas')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['created_at']

    def __str__(self):
        return f'{self.dog.name}: {self.reason[:40]}'


class DogPhoto(models.Model):
    """Groom photos, newest first on the dog profile."""

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='photos')
    image = models.ImageField(upload_to='dog_photos/')
    taken_at = models.DateTimeField(default=timezone.now, help_text='When the photo was taken — drives date sorting.')
    caption = models.CharField(max_length=200, blank=True)
    appointment = models.ForeignKey(
        'Appointment', on_delete=models.SET_NULL, null=True, blank=True, related_name='photos',
    )
    uploaded_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='dog_photos')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-taken_at', '-id']

    def __str__(self):
        return f'{self.dog.name} photo {self.taken_at:%Y-%m-%d}'


# ── Scheduling ─────────────────────────────────────────────────────────

class TemperamentGrade(models.Model):
    """One handling grade: what Jess calls it, and how many she'll take a day.

    Was ``TemperamentLimit``, when a daily cap was all it held. It now owns the
    *label* too, because the five names we shipped were our reading of Jess's
    "may up bitey not hard" and she should be able to correct them without a
    deploy. See :class:`Temperament` for why the codes cannot move the same
    way.

    Exceeding a cap produces a warning, never a block — the notes are explicit
    that Jess can always override her own rule.
    """

    temperament = models.CharField(max_length=10, choices=Temperament.choices, unique=True)
    label = models.CharField(
        max_length=40,
        help_text="What this grade is called in the app. Jess's wording wins.",
    )
    max_per_day = models.PositiveIntegerField(
        null=True, blank=True, help_text='Blank means no limit.',
    )
    sort_order = models.PositiveIntegerField(
        default=0, help_text='Easiest first. Seeded from TEMPERAMENT_ORDER.',
    )

    #: Where the label map lives between requests. A list of dogs renders one
    #: label per row, and re-querying five rows for each would be silly.
    #:
    #: Invalidated in ``save`` and ``delete``, which covers every path the app
    #: takes. A queryset-level ``.update()`` would slip past that, so the entry
    #: also expires on its own — five rows every few minutes costs nothing and
    #: bounds how long a missed invalidation could show Jess the old wording.
    CACHE_KEY = 'temperament_labels'
    CACHE_SECONDS = 300

    class Meta:
        ordering = ['sort_order', 'temperament']

    def __str__(self):
        cap = 'no limit' if self.max_per_day is None else f'max {self.max_per_day}/day'
        return f'{self.label}: {cap}'

    def save(self, *args, **kwargs):
        super().save(*args, **kwargs)
        cache.delete(self.CACHE_KEY)

    def delete(self, *args, **kwargs):
        super().delete(*args, **kwargs)
        cache.delete(self.CACHE_KEY)

    @classmethod
    def labels(cls):
        """``{code: label}`` for every grade, falling back to the seed wording.

        The fallback matters on two paths: a fresh database before the seed has
        run, and a code that has no row yet because the seed added it after
        this deployment booted. Neither should render a blank chip.
        """
        cached = cache.get(cls.CACHE_KEY)
        if cached is not None:
            return cached
        labels = dict(Temperament.choices)
        labels.update(cls.objects.values_list('temperament', 'label'))
        cache.set(cls.CACHE_KEY, labels, cls.CACHE_SECONDS)
        return labels


def temperament_label(code):
    """What to call ``code`` on screen, or '' if it isn't set.

    Always use this rather than ``get_temperament_display()``: the latter reads
    the frozen labels off :class:`Temperament` and would disagree with anything
    Jess has renamed.
    """
    if not code:
        return ''
    return TemperamentGrade.labels().get(code, code)


class OpeningHours(models.Model):
    """Normal working hours. Staff can still book outside them."""

    weekday = models.IntegerField(choices=WEEKDAY_CHOICES, unique=True)
    open_time = models.TimeField(null=True, blank=True)
    close_time = models.TimeField(null=True, blank=True)
    is_closed = models.BooleanField(default=False)

    class Meta:
        ordering = ['weekday']
        verbose_name_plural = 'Opening hours'

    def __str__(self):
        if self.is_closed or not self.open_time:
            return f'{self.get_weekday_display()}: closed'
        return f'{self.get_weekday_display()}: {self.open_time:%H:%M}–{self.close_time:%H:%M}'


class ClosureDay(models.Model):
    """One-off closures — holidays, training days."""

    date = models.DateField(unique=True)
    reason = models.CharField(max_length=200, blank=True)

    class Meta:
        ordering = ['date']

    def __str__(self):
        return f'{self.date:%d %b %Y} — {self.reason or "closed"}'


class BookingSeries(models.Model):
    """A standing appointment every N weeks, materialised into Appointments."""

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='booking_series')
    interval_weeks = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    start_date = models.DateField()
    end_date = models.DateField(null=True, blank=True, help_text='Blank = runs indefinitely.')
    preferred_time = models.TimeField()
    active = models.BooleanField(default=True)
    notes = models.TextField(blank=True)
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='booking_series')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']
        verbose_name_plural = 'Booking series'

    def __str__(self):
        return f'{self.dog.name} every {self.interval_weeks} weeks from {self.start_date:%d %b %Y}'

    def occurrence_dates(self, horizon_weeks=None):
        """Dates this series should occupy between start and the horizon."""
        if horizon_weeks is None:
            horizon_weeks = settings.BOOKING_SERIES_HORIZON_WEEKS
        horizon = timezone.localdate() + timedelta(weeks=horizon_weeks)
        if self.end_date and self.end_date < horizon:
            horizon = self.end_date

        dates = []
        current = self.start_date
        while current <= horizon:
            dates.append(current)
            current = current + timedelta(weeks=self.interval_weeks)
        return dates


class Appointment(models.Model):
    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='appointments')
    start_at = models.DateTimeField()
    end_at = models.DateTimeField()
    booking_type = models.CharField(max_length=12, choices=BookingType.choices, default=BookingType.ADHOC)
    service_type = models.CharField(
        max_length=10, choices=ServiceType.choices, default=ServiceType.GROOM,
    )
    status = models.CharField(max_length=12, choices=AppointmentStatus.choices, default=AppointmentStatus.BOOKED)
    price_quoted = models.DecimalField(max_digits=7, decimal_places=2, null=True, blank=True)
    notes = models.TextField(blank=True)
    series = models.ForeignKey(
        BookingSeries, on_delete=models.SET_NULL, null=True, blank=True, related_name='appointments',
    )
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='appointments')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['start_at']
        indexes = [models.Index(fields=['start_at']), models.Index(fields=['status'])]

    def __str__(self):
        return f'{self.dog.name} on {timezone.localtime(self.start_at):%d %b %Y %H:%M}'

    def save(self, *args, **kwargs):
        # Default the slot length and the quote so a booking made with just a
        # start time is still complete. A nails/fleas/ticks visit takes neither
        # from the dog: the breed grid prices full grooms, and inheriting it
        # would block out three hours and quote £80 for a nail trim.
        if self.service_type == ServiceType.NAILS_FLEAS_TICKS:
            settings_row = AppSettings.get()
            minutes = settings_row.nail_visit_minutes or FALLBACK_NAIL_VISIT_MINUTES
            # Left as None when Jess hasn't set one. An invented price on an
            # invoice is worse than a blank to fill in, and the booking check
            # warns about it.
            price = settings_row.nail_visit_price
        else:
            minutes = self.dog.effective_groom_minutes
            price = self.dog.effective_price
        if self.start_at and not self.end_at:
            self.end_at = self.start_at + timedelta(minutes=minutes)
        if self.price_quoted is None:
            self.price_quoted = price
        super().save(*args, **kwargs)

    @property
    def duration_minutes(self):
        return int((self.end_at - self.start_at).total_seconds() // 60)

    # Statuses that still occupy a slot in the diary — used by the overlap and
    # temperament-limit checks so cancellations don't count against capacity.
    ACTIVE_STATUSES = (
        AppointmentStatus.REQUESTED,
        AppointmentStatus.BOOKED,
        AppointmentStatus.CONFIRMED,
        AppointmentStatus.IN_PROGRESS,
        AppointmentStatus.COMPLETED,
    )


# ── Groom timing ───────────────────────────────────────────────────────

class GroomSession(models.Model):
    """One worked visit — Jess's "Ongoing Record", filled in as it happens.

    Covers both of her record cards. A ``GROOM`` carries the whole thing:
    phases timed, matting found, what was used, how the dog was. A
    ``NAILS_FLEAS_TICKS`` visit is minutes rather than hours and fills in far
    less — which of the three was done, how long, how the dog took it.

    One model rather than two because the cards are the same shape and Jess's
    are filed per dog: splitting them would split a dog's history in half.

    Phases are optional — a wash-and-blow-dry records no clip or strip, and a
    nails visit records none at all, which is what ``recorded_minutes`` is for.
    The total can be written back to the dog so future bookings block out the
    right amount of diary time.
    """

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='groom_sessions')
    appointment = models.ForeignKey(
        Appointment, on_delete=models.SET_NULL, null=True, blank=True, related_name='groom_sessions',
    )
    visit_type = models.CharField(
        max_length=10, choices=ServiceType.choices, default=ServiceType.GROOM,
    )
    started_at = models.DateTimeField(default=timezone.now)
    finished_at = models.DateTimeField(null=True, blank=True)
    recorded_minutes = models.PositiveIntegerField(
        null=True, blank=True,
        help_text='How long the visit took, when the timer was not used. Overrides the phase total.',
    )

    # ── The groom card ─────────────────────────────────────────────────
    health_check_notes = models.TextField(blank=True, help_text='Anything found on the health check.')
    matting_paws = models.BooleanField(default=False)
    matting_armpits = models.BooleanField(default=False)
    matting_ears = models.BooleanField(default=False)
    matting_elsewhere = models.BooleanField(default=False)
    matting_notes = models.TextField(blank=True, help_text='Where else, and how bad.')
    # Null, not False: "not bathed" and "bathed and hated it" are different
    # things, and defaulting to False would claim the second.
    bathed_well_behaved = models.BooleanField(null=True, blank=True)
    high_velocity_dryer = models.BooleanField(default=False)
    shampoo_used = models.CharField(max_length=120, blank=True)
    equipment_used = models.ManyToManyField(
        'Equipment', blank=True, related_name='groom_sessions',
    )
    # What was actually done, which is not the same as the pref_* fields on the
    # dog — those are what the owner asked for at intake.
    final_body = models.TextField(blank=True, verbose_name='Final body trim')
    final_feet = models.TextField(blank=True, verbose_name='Final feet shape')
    final_tail = models.TextField(blank=True, verbose_name='Final tail')

    # ── The nails / fleas / ticks card ─────────────────────────────────
    nails_done = models.BooleanField(default=False)
    fleas_treated = models.BooleanField(default=False)
    ticks_removed = models.BooleanField(default=False)

    # ── Both cards ─────────────────────────────────────────────────────
    notes = models.TextField(blank=True, help_text='Anything to note about the visit.')
    sensitive_notes = models.TextField(
        blank=True, help_text="Anywhere the dog didn't want to be touched, was fidgety or sensitive.",
    )
    # A record of how the dog was on the day. Deliberately does not write back
    # to Dog.temperament, which drives the booking limits — one bad afternoon
    # should not silently halve how many dogs Jess can take.
    temperament_observed = models.CharField(
        max_length=10, choices=Temperament.choices, blank=True,
    )

    applied_to_dog_at = models.DateTimeField(
        null=True, blank=True,
        help_text="Set when this session's total was written to the dog's default groom time.",
    )
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='groom_sessions')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-started_at']

    def __str__(self):
        return f'{self.dog.name} {self.get_visit_type_display().lower()} {self.started_at:%d %b %Y}'

    @property
    def total_seconds(self):
        if self.recorded_minutes is not None:
            return self.recorded_minutes * 60
        return sum(timing.duration_seconds for timing in self.timings.all())

    @property
    def total_minutes(self):
        return round(self.total_seconds / 60)

    @property
    def matting_found(self):
        return any([
            self.matting_paws, self.matting_armpits,
            self.matting_ears, self.matting_elsewhere,
        ])

    def apply_to_dog(self):
        """Make this session's total the dog's default groom time.

        Refused for a nails visit: twenty minutes is how long a nail trim
        takes, and writing it to the dog would book the next full groom into a
        twenty-minute slot.
        """
        if self.visit_type != ServiceType.GROOM:
            return False
        minutes = self.total_minutes
        if minutes <= 0:
            return False
        self.dog.groom_minutes = minutes
        self.dog.save(update_fields=['groom_minutes', 'updated_at'])
        self.applied_to_dog_at = timezone.now()
        self.save(update_fields=['applied_to_dog_at'])
        return True


class PhaseTiming(models.Model):
    """One phase of a groom session. Timed live or typed in afterwards."""

    session = models.ForeignKey(GroomSession, on_delete=models.CASCADE, related_name='timings')
    phase = models.CharField(max_length=10, choices=GroomPhase.choices)
    duration_seconds = models.PositiveIntegerField(default=0)
    started_at = models.DateTimeField(null=True, blank=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    entered_manually = models.BooleanField(
        default=False, help_text='True when the duration was typed in rather than timed.',
    )

    class Meta:
        ordering = ['session', 'phase']
        unique_together = [('session', 'phase')]

    def __str__(self):
        return f'{self.get_phase_display()}: {self.duration_seconds // 60}m'


# ── Money ──────────────────────────────────────────────────────────────

class Invoice(models.Model):
    class Status(models.TextChoices):
        DRAFT = 'DRAFT', 'Draft'
        SENT = 'SENT', 'Sent'
        PAID = 'PAID', 'Paid'
        VOID = 'VOID', 'Void'

    client = models.ForeignKey(Client, on_delete=models.PROTECT, related_name='invoices')
    number = models.CharField(max_length=32, unique=True)
    issue_date = models.DateField(default=timezone.localdate)
    due_date = models.DateField(null=True, blank=True)
    status = models.CharField(max_length=6, choices=Status.choices, default=Status.DRAFT)
    notes = models.TextField(blank=True)
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='invoices')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-issue_date', '-id']

    def __str__(self):
        return f'{self.number} — {self.client.full_name}'

    @property
    def total(self):
        return sum((line.line_total for line in self.lines.all()), Decimal('0.00'))

    @property
    def amount_paid(self):
        return sum((payment.amount for payment in self.payments.all()), Decimal('0.00'))

    @property
    def balance(self):
        return self.total - self.amount_paid


class InvoiceLine(models.Model):
    invoice = models.ForeignKey(Invoice, on_delete=models.CASCADE, related_name='lines')
    appointment = models.ForeignKey(
        Appointment, on_delete=models.SET_NULL, null=True, blank=True, related_name='invoice_lines',
    )
    description = models.CharField(max_length=200)
    quantity = models.DecimalField(max_digits=6, decimal_places=2, default=Decimal('1.00'))
    unit_price = models.DecimalField(max_digits=7, decimal_places=2)

    class Meta:
        ordering = ['id']

    def __str__(self):
        return f'{self.description} x{self.quantity}'

    @property
    def line_total(self):
        return (self.quantity * self.unit_price).quantize(Decimal('0.01'))


class Payment(models.Model):
    class Method(models.TextChoices):
        CASH = 'CASH', 'Cash'
        CARD = 'CARD', 'Card'
        BANK = 'BANK', 'Bank transfer'
        OTHER = 'OTHER', 'Other'

    invoice = models.ForeignKey(Invoice, on_delete=models.CASCADE, related_name='payments')
    amount = models.DecimalField(max_digits=7, decimal_places=2)
    paid_at = models.DateField(default=timezone.localdate)
    method = models.CharField(max_length=6, choices=Method.choices, default=Method.CARD)
    reference = models.CharField(max_length=100, blank=True)
    recorded_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='payments')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-paid_at', '-id']

    def __str__(self):
        return f'£{self.amount} on {self.invoice.number}'


# ── Equipment ──────────────────────────────────────────────────────────

class Equipment(models.Model):
    name = models.CharField(max_length=120)
    uid = models.CharField(max_length=32, unique=True, help_text='Asset reference, e.g. BLADE-07.')
    last_sharpened = models.DateField(null=True, blank=True)
    pat_tested = models.BooleanField(default=False)
    pat_tested_date = models.DateField(null=True, blank=True)
    notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['name']
        verbose_name_plural = 'Equipment'

    def __str__(self):
        return f'{self.name} ({self.uid})'


# ── Intake ─────────────────────────────────────────────────────────────

def generate_intake_token():
    return secrets.token_urlsafe(32)


class IntakeInvite(models.Model):
    """A one-time link to the electronic intake form.

    The form is filled in by someone who has no login, so the token *is* the
    credential: single-use, time-limited, and never reusable once submitted.
    """

    client = models.ForeignKey(
        Client, on_delete=models.CASCADE, null=True, blank=True, related_name='intake_invites',
        help_text='Set when inviting an existing client to complete their details.',
    )
    email = models.EmailField()
    token = models.CharField(max_length=64, unique=True, default=generate_intake_token)
    expires_at = models.DateTimeField()
    used_at = models.DateTimeField(null=True, blank=True)
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='intake_invites')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'Intake invite for {self.email}'

    def save(self, *args, **kwargs):
        if not self.expires_at:
            self.expires_at = timezone.now() + timedelta(days=settings.INTAKE_INVITE_TTL_DAYS)
        super().save(*args, **kwargs)

    @property
    def is_usable(self):
        return self.used_at is None and self.expires_at > timezone.now()


class IntakeSubmission(models.Model):
    """A completed intake form, awaiting staff review.

    ``dogs`` holds the submitted dog details as JSON rather than real Dog rows,
    because nothing should enter the live records until Jess has looked at it.
    Approval creates the Client, Dogs and ProblemAreas in one transaction.
    """

    invite = models.ForeignKey(
        IntakeInvite, on_delete=models.SET_NULL, null=True, blank=True, related_name='submissions',
    )
    first_name = models.CharField(max_length=100)
    last_name = models.CharField(max_length=100, blank=True)
    email = models.EmailField()
    phone = models.CharField(max_length=20, blank=True)
    address = models.TextField(blank=True)
    postcode = models.CharField(max_length=10, blank=True)
    emergency_contact_name = models.CharField(max_length=100, blank=True)
    emergency_contact_phone = models.CharField(max_length=20, blank=True)
    dogs = models.JSONField(
        default=list,
        help_text='Submitted dogs: name, breed, dob, sex, preferences and problem areas.',
    )
    # {kind: bool} for the six disclaimers, plus the name typed to sign them.
    # Held as JSON alongside the dogs for the same reason: nothing becomes a
    # real Consent row until Jess approves the submission.
    consents = models.JSONField(default=dict, help_text='Which disclaimers were agreed, by kind.')
    signature = models.CharField(max_length=120, blank=True)

    status = models.CharField(max_length=10, choices=ReviewStatus.choices, default=ReviewStatus.PENDING)
    reviewed_by = models.ForeignKey(
        User, on_delete=models.SET_NULL, null=True, blank=True, related_name='reviewed_intakes',
    )
    reviewed_at = models.DateTimeField(null=True, blank=True)
    review_notes = models.TextField(blank=True)
    created_client = models.ForeignKey(
        Client, on_delete=models.SET_NULL, null=True, blank=True, related_name='intake_submissions',
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'Intake from {self.first_name} {self.last_name} ({self.status})'


# ── Odds and ends ──────────────────────────────────────────────────────

class TodoItem(models.Model):
    """The to-do list docked at the bottom of the Calendar page."""

    text = models.CharField(max_length=300)
    is_done = models.BooleanField(default=False)
    due_date = models.DateField(null=True, blank=True)
    sort_order = models.IntegerField(default=0)
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='todos')
    created_at = models.DateTimeField(auto_now_add=True)
    completed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ['is_done', 'sort_order', 'created_at']

    def __str__(self):
        return ('[x] ' if self.is_done else '[ ] ') + self.text


class AppSettings(models.Model):
    """Singleton row of business-wide switches."""

    business_name = models.CharField(max_length=120, default='Mojo and Co')
    contact_phone = models.CharField(max_length=20, default='07743 525 386')
    contact_email = models.EmailField(default='info@mojoandco.uk')
    invoicing_visible_to_clients = models.BooleanField(
        default=False,
        help_text='Invoicing starts hidden from clients; flip this on when ready to share it.',
    )
    booking_slot_buffer_minutes = models.PositiveIntegerField(
        default=0, help_text='Extra minutes added after each appointment when suggesting slots.',
    )
    # A nails/fleas/ticks visit can't take its length or price from the breed
    # grid — that grid prices full grooms only, and Jess's price list has
    # nothing for this at all.
    #
    # Both are null until she fills them in, deliberately. A made-up default
    # is indistinguishable from a real figure once it is in the database, and
    # the one thing worse than no price on an invoice is a wrong one nobody
    # knew was invented. Null means "not set yet" and the app says so.
    nail_visit_minutes = models.PositiveIntegerField(
        null=True, blank=True,
        help_text='How long to block out for a nails, flea or tick visit. Blank until set.',
    )
    nail_visit_price = models.DecimalField(
        max_digits=7, decimal_places=2, null=True, blank=True,
        help_text='What a nails, flea or tick visit costs. Not from the breed price list.',
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name_plural = 'App settings'

    def __str__(self):
        return self.business_name

    def save(self, *args, **kwargs):
        self.pk = 1  # Enforce a single row.
        super().save(*args, **kwargs)

    @classmethod
    def get(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj
