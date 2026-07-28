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
from django.core.validators import MinValueValidator
from django.db import models
from django.db.models.signals import post_save
from django.dispatch import receiver
from django.utils import timezone


# ── Choice vocabularies ────────────────────────────────────────────────

class Temperament(models.TextChoices):
    EASY = 'EASY', 'Easy'
    FIDGETY = 'FIDGETY', 'Fidgety / bitey'
    FEISTY = 'FEISTY', 'Feisty / hard'


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
    is_neutered = models.BooleanField(default=False)
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

    medical_notes = models.TextField(blank=True)
    vet = models.TextField(blank=True, help_text='Practice name, address and phone number.')
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

class TemperamentLimit(models.Model):
    """How many dogs of a given temperament Jess will take in one day.

    Exceeding a limit produces a warning, never a block — the notes are
    explicit that Jess can always override her own rule.
    """

    temperament = models.CharField(max_length=10, choices=Temperament.choices, unique=True)
    max_per_day = models.PositiveIntegerField(
        null=True, blank=True, help_text='Blank means no limit.',
    )

    class Meta:
        ordering = ['temperament']

    def __str__(self):
        cap = 'no limit' if self.max_per_day is None else f'max {self.max_per_day}/day'
        return f'{self.get_temperament_display()}: {cap}'


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
        # Default the slot length to the dog's groom time, and the quote to its
        # price, so a booking made with just a start time is still complete.
        if self.start_at and not self.end_at:
            self.end_at = self.start_at + timedelta(minutes=self.dog.effective_groom_minutes)
        if self.price_quoted is None:
            self.price_quoted = self.dog.effective_price
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
    """One worked groom, timed by phase.

    Phases are optional — a wash-and-blow-dry records no clip or strip. The
    total can be written back to the dog so future bookings block out the
    right amount of diary time.
    """

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='groom_sessions')
    appointment = models.ForeignKey(
        Appointment, on_delete=models.SET_NULL, null=True, blank=True, related_name='groom_sessions',
    )
    started_at = models.DateTimeField(default=timezone.now)
    finished_at = models.DateTimeField(null=True, blank=True)
    notes = models.TextField(blank=True)
    applied_to_dog_at = models.DateTimeField(
        null=True, blank=True,
        help_text="Set when this session's total was written to the dog's default groom time.",
    )
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='groom_sessions')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-started_at']

    def __str__(self):
        return f'{self.dog.name} groom {self.started_at:%d %b %Y}'

    @property
    def total_seconds(self):
        return sum(timing.duration_seconds for timing in self.timings.all())

    @property
    def total_minutes(self):
        return round(self.total_seconds / 60)

    def apply_to_dog(self):
        """Make this session's total the dog's default groom time."""
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
    dogs = models.JSONField(
        default=list,
        help_text='Submitted dogs: name, breed, dob, sex, preferences and problem areas.',
    )

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
