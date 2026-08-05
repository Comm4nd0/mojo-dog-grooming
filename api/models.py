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
from pathlib import Path

from django.conf import settings
from django.contrib.auth.models import User
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.core.files.storage import FileSystemStorage
from django.core.validators import MinValueValidator
from django.db import IntegrityError, models, transaction
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

#: Monday-first labels, indexed by the same number ``date.weekday()`` returns.
WEEKDAY_LABELS = [label for _, label in WEEKDAY_CHOICES]


def validate_weekdays(value):
    """A list of weekday numbers, 0 = Monday, no duplicates.

    A ``JSONField`` accepts anything JSON will carry, so this is the only thing
    between the column and a string, a null in the middle of a list, or a 7
    that would render as nothing at all on the app side. It runs on both sides:
    Django calls it from ``full_clean`` for the admin form, and DRF copies
    model-field validators onto the serializer field.
    """
    if not isinstance(value, list):
        raise ValidationError('Expected a list of weekday numbers.')
    seen = set()
    for entry in value:
        # bools are ints in Python, and `True` would quietly mean Tuesday.
        if isinstance(entry, bool) or not isinstance(entry, int):
            raise ValidationError(f'{entry!r} is not a weekday number.')
        if not 0 <= entry <= 6:
            raise ValidationError(f'{entry} is not a weekday — 0 is Monday, 6 is Sunday.')
        if entry in seen:
            raise ValidationError(f'{WEEKDAY_LABELS[entry]} is listed twice.')
        seen.add(entry)


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
    # Jess's request, and it belongs with chatty rather than on the dog: it is
    # a fact about the *owner*, and it applies to every dog they bring. What it
    # is for is knowing before the groom starts that this one gets checked over
    # at the door — which is not something to tell the owner you have written
    # down, hence staff-only with the rest of this block.
    particular_about_standard = models.BooleanField(
        default=False,
        verbose_name='Particular about groom standard',
        help_text='This owner is particular about the finish. Hidden from clients.',
    )
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


#: The only fields a client may ask to change about themselves.
#:
#: This is the security-critical part of :class:`ClientChangeRequest`, not a
#: tidiness measure. Approving a request applies ``changes`` with ``setattr``,
#: which is an arbitrary-field-write primitive unless it is fenced:
#: ``{"notes": "..."}`` writes one of Jess's private staff fields,
#: ``{"uid": "MOJO-001"}`` collides her numbering, and ``{"user": 3}``
#: re-points the record at somebody else's login.
CLIENT_SELF_SERVICE_FIELDS = (
    'first_name',
    'last_name',
    'phone',
    'email',
    'address',
    'postcode',
    'emergency_contact_name',
    'emergency_contact_phone',
)


class ClientChangeRequest(models.Model):
    """A client asking Jess to correct their own details.

    Same shape as :class:`ClientClaimRequest` on purpose — pending, approved
    or rejected, with who reviewed it and when. Everything else a client sends
    in is a request Jess reviews (a booking, a claim, an intake form); their
    own details were the one thing they could edit unreviewed, which is what
    Jess's "can they request detail changes as well?" is about.

    ``client`` is resolved from the session, never from the request body.
    Taking it from the body would let any signed-in user lodge a request
    against any client, and put another client's data in front of Jess for
    approval.
    """

    client = models.ForeignKey(Client, on_delete=models.CASCADE, related_name='change_requests')
    requested_by = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name='change_requests',
    )
    changes = models.JSONField(
        default=dict,
        help_text='Field name to new value. Whitelisted by CLIENT_SELF_SERVICE_FIELDS.',
    )
    status = models.CharField(max_length=10, choices=ReviewStatus.choices, default=ReviewStatus.PENDING)
    reviewed_by = models.ForeignKey(
        User, on_delete=models.SET_NULL, null=True, blank=True, related_name='reviewed_changes',
    )
    reviewed_at = models.DateTimeField(null=True, blank=True)
    review_notes = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'Change request from {self.client.full_name} ({self.status})'

    def apply(self):
        """Write the requested changes onto the client record.

        Re-checks the whitelist on the way out as well as on the way in. A
        request could have been lodged before the whitelist shrank, and the
        cost of checking twice is nothing next to the cost of missing one.
        """
        applied = []
        for field, value in (self.changes or {}).items():
            if field not in CLIENT_SELF_SERVICE_FIELDS:
                continue
            setattr(self.client, field, value)
            applied.append(field)
        if applied:
            self.client.save(update_fields=[*applied, 'updated_at'])
        return applied


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

class KennelClubGroup(models.TextChoices):
    """The UK Kennel Club's seven breed groups."""

    GUNDOG = 'GUNDOG', 'Gundog'
    HOUND = 'HOUND', 'Hound'
    PASTORAL = 'PASTORAL', 'Pastoral'
    TERRIER = 'TERRIER', 'Terrier'
    TOY = 'TOY', 'Toy'
    UTILITY = 'UTILITY', 'Utility'
    WORKING = 'WORKING', 'Working'


class ActivityLevel(models.TextChoices):
    HIGH = 'HIGH', 'High'
    MEDIUM = 'MEDIUM', 'Medium'
    LOW = 'LOW', 'Low'


class SizeBand(models.TextChoices):
    """Jess's five size bands.

    **The values are the keys of ``PRICING`` in ``seed_breeds``**, lower case
    and spelled exactly as they are there. That grid is size band × coat type,
    so a mismatch here silently loses a breed its price.
    """

    TOY = 'toy', 'Toy'
    SMALL = 'small', 'Small'
    MEDIUM = 'medium', 'Medium'
    LARGE = 'large', 'Large'
    COLOSSAL = 'colossal', 'Colossal (45kg and over)'


class CoatType(models.TextChoices):
    """Coat types, as Jess lists them on her breed standards record.

    The first five are the ``PRICING`` grid's coat axis and their values are
    spelled to match it exactly — changing one of those strings unprices every
    breed that carries it.

    **The last three are hers and are not on the grid.** Her price list covers
    the original five, so a breed in a hairless, corded or silky coat gets no
    price until she sets one, and the booking check says so. Mapping them onto
    a neighbouring coat would price three of them as something they are not,
    and an invented price is indistinguishable from a real one once it is in
    the table — the same reasoning as ``nail_visit_price``.
    """

    SMOOTH = 'smooth', 'Smooth'
    SHORT_DOUBLE = 'short double', 'Short double'
    LONG_DOUBLE = 'long double', 'Long double'
    CURLY = 'curly', 'Curly'
    WIRE = 'wire', 'Wire'
    # Not on the price grid — see above.
    HAIRLESS = 'hairless', 'Hairless'
    CORDED = 'corded', 'Corded'
    SILKY = 'silky', 'Silky / drop'


class Breed(models.Model):
    """Jess's breed standards record — "a little snippet of the whole dog".

    Started life as three numbers (time, price, interval) seeded by
    ``manage.py seed_breeds``. It is now also the reference sheet she looks a
    breed up in, so most of what follows is descriptive rather than
    operational.

    Two fields are **not** merely descriptive and need care:

    * ``size_band`` and ``coat_type`` are the two axes of ``PRICING`` in
      ``seed_breeds``. The band was implicit in the seed data until now — the
      grid knew it, the model did not — so storing it makes the pricing
      derivable rather than a thing you have to go and read the seed file for.
    * The ``groom_style_*`` fields pre-fill a new dog's ``pref_*`` preferences
      in the dog form. They are a starting point that Jess edits per dog, never
      an override: once a dog has its own, the dog's win.

    Everything descriptive is free text on purpose. Jess is still working out
    what belongs on this record, and a choice list fixed now would be a set of
    options she has to work around rather than with. The four fields she *did*
    enumerate — group, activity, size, coat — are choices.
    """

    name = models.CharField(max_length=120, unique=True)

    # ── The operational three, and the two that price them ─────────────
    coat_type = models.CharField(
        max_length=60, blank=True, choices=CoatType.choices,
        help_text='One axis of the price grid. The last three are not on it.',
    )
    size_band = models.CharField(
        max_length=10, blank=True, choices=SizeBand.choices,
        help_text='The other axis of the price grid.',
    )
    avg_groom_minutes = models.PositiveIntegerField(help_text='Typical full groom time in minutes.')
    avg_price = models.DecimalField(max_digits=7, decimal_places=2, help_text='Typical full groom price in GBP.')
    avg_schedule_weeks = models.PositiveIntegerField(help_text='Typical interval between grooms, in weeks.')

    # ── The breed itself ───────────────────────────────────────────────
    kennel_club_group = models.CharField(
        max_length=10, blank=True, choices=KennelClubGroup.choices,
        verbose_name='UK Kennel Club group',
    )
    activity_level = models.CharField(max_length=6, blank=True, choices=ActivityLevel.choices)
    # Ranges, because that is how every one of these is actually quoted — "12
    # to 15 years", "a 4-6kg dog". Both halves optional so a half-known figure
    # can still be written down.
    life_span_min_years = models.PositiveSmallIntegerField(null=True, blank=True)
    life_span_max_years = models.PositiveSmallIntegerField(null=True, blank=True)
    # Centimetres. Jess's list says "Height (kg)", which is a slip for cm —
    # weight is the line below it.
    height_min_cm = models.PositiveSmallIntegerField(null=True, blank=True, verbose_name='Height from (cm)')
    height_max_cm = models.PositiveSmallIntegerField(null=True, blank=True, verbose_name='Height to (cm)')
    weight_min_kg = models.DecimalField(max_digits=5, decimal_places=1, null=True, blank=True)
    weight_max_kg = models.DecimalField(max_digits=5, decimal_places=1, null=True, blank=True)
    original_purpose = models.TextField(blank=True, help_text='What the breed was originally bred to do.')
    # Free text, and nothing seeds it — Jess types these in herself off the UK
    # Kennel Club's breed pages. Same rule as MedicalNote: this is somebody
    # else's description of a breed, and text that merely sounds right is worse
    # than a blank, because the blank is honest about not knowing.
    #
    # It is about the *breed*, not the dog in front of you: a dog's own
    # handling grade is Dog.temperament, which drives the booking limits, and
    # this must never be read as a substitute for it.
    typical_temperament = models.TextField(
        blank=True,
        help_text='What the breed is generally like. Not this dog — see the dog record for that.',
    )

    # ── Shape, which is what a groomer is actually looking at ──────────
    chest_shape = models.CharField(max_length=120, blank=True)
    head_type = models.CharField(max_length=120, blank=True)
    ear_shape = models.CharField(max_length=120, blank=True)
    # Was `head_shape`, renamed at Jess's request — `head_type` was already
    # covering the head and the tail was the thing with nowhere to go.
    tail_shape = models.CharField(max_length=120, blank=True)
    coat_colours = models.TextField(blank=True, verbose_name='Colours of coat')

    # ── How it is groomed ──────────────────────────────────────────────
    grooming_technique = models.TextField(blank=True)
    groom_style_body = models.TextField(blank=True, verbose_name='Groom style — body')
    groom_style_head = models.TextField(blank=True, verbose_name='Groom style — head')
    groom_style_feet = models.TextField(blank=True, verbose_name='Groom style — feet')
    groom_style_tail = models.TextField(blank=True, verbose_name='Groom style — tail')
    groom_style_ears = models.TextField(blank=True, verbose_name='Groom style — ears')

    common_ailments = models.TextField(
        blank=True,
        help_text='What this breed tends to suffer from. Link the detail under Medical notes.',
    )
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ['name']

    def __str__(self):
        return self.name

    @property
    def is_priced_by_the_grid(self):
        """Whether this breed's coat is one the price list actually covers.

        False for hairless, corded and silky: Jess's list prices the other
        five, so these carry whatever she sets and nothing is guessed.
        """
        return self.coat_type in {
            CoatType.SMOOTH, CoatType.SHORT_DOUBLE,
            CoatType.LONG_DOUBLE, CoatType.CURLY, CoatType.WIRE,
        }

    #: Breed groom style -> the dog preference it seeds.
    #:
    #: Head to face is the one that is not a rename: the breed record says
    #: "head", a dog's preferences say "face", and for styling purposes a
    #: groomer means the same area. `pref_skirt` has no breed counterpart and
    #: is left alone.
    GROOM_STYLE_TO_PREFERENCE = {
        'groom_style_body': 'pref_body',
        'groom_style_head': 'pref_face',
        'groom_style_feet': 'pref_feet',
        'groom_style_tail': 'pref_tail',
        'groom_style_ears': 'pref_ears',
    }

    def preference_defaults(self):
        """The dog preferences this breed suggests, skipping the blanks.

        Used to pre-fill the dog form so Jess is not retyping the same styling
        for every Cockapoo. Only ever a starting point — see the class
        docstring.
        """
        return {
            preference: getattr(self, style)
            for style, preference in self.GROOM_STYLE_TO_PREFERENCE.items()
            if getattr(self, style)
        }


class MedicalNote(models.Model):
    """A thing that can be wrong with a dog, and what it means when grooming.

    Jess's idea: *"if medical issue with the dog you can look up what it means
    or if you need to take care when grooming"*.

    **Nothing here is seeded and nothing is written by this codebase.** This is
    veterinary information, and text that merely sounds right is worse than an
    empty field — somebody would act on it. Every entry carries a ``source`` so
    what is in the table is attributable to whoever or whatever said it.

    Deliberately not on ``Dog``: a dog's own conditions live in
    ``Dog.medical_issues`` and ``Dog.medical_notes``, which are that dog's
    record. This is the reference you look the term up in.
    """

    class Kind(models.TextChoices):
        AILMENT = 'AILMENT', 'Condition or ailment'
        FIRST_AID = 'FIRST_AID', 'First aid'
        GROOMING_CARE = 'GROOMING_CARE', 'Care when grooming'

    title = models.CharField(max_length=120, unique=True)
    kind = models.CharField(max_length=15, choices=Kind.choices, default=Kind.AILMENT)
    what_it_means = models.TextField(
        blank=True, help_text='Plain-English explanation of the term.',
    )
    grooming_care = models.TextField(
        blank=True, help_text='What to watch for, or do differently, when grooming a dog with this.',
    )
    first_aid = models.TextField(
        blank=True, help_text='What to do if it happens in the salon.',
    )
    source = models.CharField(
        max_length=200, blank=True,
        help_text='Where this came from — your vet, a course, a book. Left blank it is nobody in particular.',
    )
    breeds = models.ManyToManyField(
        Breed, blank=True, related_name='medical_notes',
        help_text='Breeds this is common in. Optional — plenty of these are not breed-specific.',
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['title']

    def __str__(self):
        return self.title


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
    # Jess's request, and it sits with the handling notes rather than beside
    # the consent of the same name: the RESTRAINT consent is the owner
    # *permitting* a collar or muzzle, this is Jess recording that this dog
    # actually needs one. Somebody can agree and never need it.
    #
    # **Staff only**, like everything else in this block. A client opening
    # their dog's profile must not be told their dog gets muzzled.
    requires_restraint = models.BooleanField(
        default=False,
        verbose_name='Restraints required',
        help_text='This dog needs a collar or muzzle to be groomed safely. Hidden from clients.',
    )

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
    #: No regular interval — this one comes when the owner rings.
    #:
    #: Jess found a dog on her overdue list the evening of the day she groomed
    #: it. The list is "last groom + interval", and *every* dog has an interval
    #: whether or not one was ever agreed, so an ad hoc dog is permanently
    #: about to be late for a groom nobody booked. It is left off ``dogs_due``
    #: rather than given an invented date — the same call as a never-groomed
    #: dog getting a null due date instead of today's.
    #:
    #: It deliberately does **not** change ``effective_schedule_weeks``.
    #: ``suggested_next_groom`` still answers for this dog when Jess asks about
    #: it directly, which is a fair question about any dog; what changes is
    #: that nothing volunteers the answer.
    is_ad_hoc = models.BooleanField(
        default=False,
        verbose_name='Ad hoc — no regular interval',
        help_text='Comes when the owner asks. Kept off the "who is due" list.',
    )
    #: What this dog's grooms have actually taken — Jess's "once sessions added
    #: can the average groom time be the approximate dog groom time?".
    #:
    #: Denormalised rather than computed on read, because ``Doguments`` renders
    #: ``effective_groom_minutes`` for every dog in the book and a query per row
    #: would be an N+1 on the busiest screen in the app.
    #:
    #: Null means "not enough real grooms yet" — see
    #: ``recalculate_average_groom_minutes``. Null is not zero: a dog with no
    #: history falls back to its breed, it does not book a nil-minute slot.
    average_groom_minutes = models.PositiveIntegerField(
        null=True, blank=True,
        editable=False,
        help_text='Worked out from past grooms. Not edited by hand.',
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

    # What this dog usually has done. NOT staff-only, deliberately: it is what
    # the owner asked for, and a client needs to read it to request the right
    # kind of booking. Do not "helpfully" add it to staff_only_fields later.
    #
    # By name rather than the class, because Service is declared further down
    # the file — it needs Dog for the resolver.
    default_services = models.ManyToManyField(
        'Service', blank=True, related_name='dogs',
        help_text='What this dog normally has. Pre-fills a new booking.',
    )

    # ── Daycare ────────────────────────────────────────────────────────
    # Jess: "can there be a daycare dog tickbox and be able to put what days
    # they're in?"
    #
    # NOT staff-only, deliberately. This is the arrangement the owner made and
    # already knows about — unlike the handling notes above, which are Jess's
    # private reading of their dog. Same reasoning as `default_services`.
    #
    # A flag *and* a list of days, rather than the empty list standing in for
    # "not a daycare dog": a dog can be signed up for daycare before the days
    # are settled, and a tickbox that silently unticks itself when you clear
    # the days is a tickbox that argues with you.
    is_daycare = models.BooleanField(
        default=False,
        verbose_name='Daycare dog',
        help_text='Comes in for daycare as well as grooming.',
    )
    daycare_days = models.JSONField(
        default=list, blank=True,
        validators=[validate_weekdays],
        verbose_name='Daycare days',
        help_text='Which days, 0 = Monday. Kept sorted, no repeats.',
    )

    is_active = models.BooleanField(default=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['name']
        indexes = [models.Index(fields=['name'])]

    def __str__(self):
        return f'{self.name} ({self.client.full_name})'

    def save(self, *args, **kwargs):
        # Sorted on the way in so nothing downstream has to. The validator
        # rejects duplicates and out-of-range days; this only fixes the order,
        # which neither the admin form nor a PATCH has any reason to get right.
        if isinstance(self.daycare_days, list):
            self.daycare_days = sorted(
                day for day in self.daycare_days if isinstance(day, int) and not isinstance(day, bool)
            )
        super().save(*args, **kwargs)

    @property
    def daycare_days_label(self):
        """The daycare days as words, e.g. "Mon, Wed, Fri". Blank if none."""
        return ', '.join(
            WEEKDAY_LABELS[day][:3] for day in self.daycare_days or [] if 0 <= day <= 6
        )

    # The three ``effective_*`` properties are the only correct way to read
    # these values — a bare ``dog.price`` is null whenever the breed default
    # applies, which is the common case.

    #: How many past grooms to average, and the fewest that will do.
    #:
    #: Recent, because a puppy's first groom and its fifth are different jobs
    #: and the old ones should fall out of the reckoning. At least two, because
    #: a single visit is as likely to be a bad afternoon as a true measure —
    #: and the breed grid, for all that it is an estimate, is at least a
    #: considered one.
    AVERAGE_OVER_SESSIONS = 5
    MIN_SESSIONS_FOR_AVERAGE = 2

    @property
    def effective_groom_minutes(self):
        # An explicit override still wins. `apply_to_dog()` writes to it, and
        # so does the dog form, and both are somebody deciding — that should
        # not be quietly outvoted by an average.
        if self.groom_minutes is not None:
            return self.groom_minutes
        # What this dog's grooms actually take, ahead of what the breed grid
        # guesses they might. The grid prices by size band and coat, and its
        # times are general estimates; two real grooms of this dog beat them.
        if self.average_groom_minutes:
            return self.average_groom_minutes
        if self.breed_id:
            return self.breed.avg_groom_minutes
        return 90  # Fallback for an unknown breed with no override.

    def recalculate_average_groom_minutes(self, save=True):
        """Re-derive :attr:`average_groom_minutes` from this dog's history.

        Only **whole grooms** count, via the same ``_was_a_whole_groom()``
        guard ``apply_to_dog()`` uses. A nails visit is twenty minutes and a
        "Tidy Up" is twenty-five; averaging either into a full groom books the
        next one into a slot far too short, which is the bug that guard exists
        to prevent, arrived at by a different road.

        Called from ``GroomSession.save()`` and ``delete()`` rather than left
        to a nightly job — the figure has to be right the moment Jess finishes
        writing up a visit and books the next one.
        """
        # `_was_a_whole_groom` reads appointment.services and `total_seconds`
        # reads timings, so both are prefetched — this runs on every session
        # save and should not fan out into a query per visit.
        #
        # Over-fetch a little, because sessions that fail the whole-groom guard
        # are skipped and we still want the most recent five that pass.
        sessions = (
            self.groom_sessions
            .filter(visit_type=ServiceType.GROOM)
            .order_by('-started_at', '-id')
            .select_related('appointment')
            .prefetch_related('appointment__services', 'timings')[
                : self.AVERAGE_OVER_SESSIONS * 3
            ]
        )

        minutes = []
        for session in sessions:
            if not session._was_a_whole_groom():
                continue
            total = session.total_minutes
            if total > 0:
                minutes.append(total)
            if len(minutes) >= self.AVERAGE_OVER_SESSIONS:
                break

        average = (
            round(sum(minutes) / len(minutes))
            if len(minutes) >= self.MIN_SESSIONS_FOR_AVERAGE
            else None
        )

        if average == self.average_groom_minutes:
            return average
        self.average_groom_minutes = average
        if save:
            self.save(update_fields=['average_groom_minutes', 'updated_at'])
        return average

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


def private_storage():
    """Storage for scanned paperwork, outside the Caddy-served tree.

    A callable rather than an instance so the absolute path is not baked into
    the migration — it differs between a laptop and the container.
    """
    return FileSystemStorage(location=settings.PRIVATE_MEDIA_ROOT)


def document_upload_path(instance, filename):
    """``dog_documents/<dog id>/<random>.<ext>``.

    Never the uploader's own filename: it defends against path traversal, and
    against the filename itself leaking the client's name into a path that
    ends up in a log.
    """
    extension = Path(filename).suffix.lower().lstrip('.') or 'bin'
    return f'dog_documents/{instance.dog_id}/{secrets.token_hex(8)}.{extension}'


class DogDocument(models.Model):
    """A scanned or photographed document filed against a dog.

    Jess asked to attach the original paper intake form to a dog's profile and
    let the owner see it. Not a :class:`DogPhoto`: that is an image in a
    date-ordered gallery with caption and appointment semantics that do not
    apply here, no notion of kind, no way to say "this one is shareable", and
    no room for a PDF. A signed intake form is evidence, not a picture of a
    haircut.

    The file lives under ``PRIVATE_MEDIA_ROOT`` and is only ever reached
    through a gated download view — see that setting for why an unguessable
    filename under ``/media/`` is not good enough here.
    """

    class Kind(models.TextChoices):
        INTAKE_FORM = 'INTAKE_FORM', 'Intake form'
        VACCINATION = 'VACCINATION', 'Vaccination record'
        VET = 'VET', 'Vet letter'
        OTHER = 'OTHER', 'Other'

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='documents')
    file = models.FileField(upload_to=document_upload_path, storage=private_storage)
    title = models.CharField(max_length=200)
    kind = models.CharField(max_length=20, choices=Kind.choices, default=Kind.OTHER)
    visible_to_client = models.BooleanField(
        default=True,
        help_text=(
            "Whether the dog's owner can see and download this. On by "
            'default because the point of the feature is letting them see '
            'their own form — turn it off for anything you are filing for '
            'yourself.'
        ),
    )
    # Kept alongside the stored file so a listing does not have to stat every
    # one, and so the original name survives for the download.
    original_filename = models.CharField(max_length=255, blank=True)
    content_type = models.CharField(max_length=100, blank=True)
    size_bytes = models.PositiveIntegerField(default=0)
    uploaded_by = models.ForeignKey(
        User, on_delete=models.SET_NULL, null=True, blank=True, related_name='dog_documents',
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at', '-id']

    def __str__(self):
        return f'{self.dog.name}: {self.title}'


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


class Service(models.Model):
    """One thing Jess does, from the list she sent.

    Nail Clipping, Full Groom, Health Check, Ear Cleaning, De-Shedding, Paws
    Clipped, Hygiene Clip, Tick/Flea Removal, Puppy's First Groom, Bath and
    Blow Dry, Tidy Up, Clipped Coat, Hand Stripping.

    **This does not replace :class:`ServiceType`.** That stays as the coarse
    category, for three reasons:

    * ``GroomSession.visit_type`` is a *paper-card discriminator*. Jess keeps
      two record cards and one model exists precisely so a dog's history isn't
      split in half; keying record cards off a thirteen-row catalogue would
      split it thirteen ways.
    * ``apply_to_dog()`` needs a coarse guard, and the catalogue makes it need
      a stricter one — a 25-minute "Tidy Up" recorded against a groom would
      otherwise overwrite a 105-minute ``Dog.groom_minutes``.
    * It is purely additive. An appointment with no services behaves
      byte-identically to one from before this existed, which is the property
      that makes it safe to ship.

    Keyed by ``code``, not name — a deliberate improvement on :class:`Breed`,
    which is keyed by name, so renaming a breed in the app makes the next
    boot's seed re-create the old row.
    """

    code = models.SlugField(max_length=40, unique=True)
    name = models.CharField(max_length=120)
    category = models.CharField(
        max_length=10, choices=ServiceType.choices, default=ServiceType.GROOM,
        help_text='Which record card this belongs to, and how it is priced.',
    )
    default_minutes = models.PositiveIntegerField(
        null=True, blank=True, help_text='Blank until Jess sets one.',
    )
    default_price = models.DecimalField(
        max_digits=7, decimal_places=2, null=True, blank=True,
        help_text='Blank until Jess sets one. Never invent a figure here.',
    )
    takes_dog_defaults = models.BooleanField(
        default=False,
        help_text=(
            'Take both the length and the price from the dog — i.e. from the '
            'breed grid. Set on Full Groom only.'
        ),
    )
    is_active = models.BooleanField(default=True)
    sort_order = models.IntegerField(default=0)

    class Meta:
        ordering = ['sort_order', 'name']

    def __str__(self):
        return self.name


def resolve_slot(dog, service_type, services=()):
    """How long a booking runs, what it costs, and what has no price yet.

    Returns ``(minutes, price_or_None, unpriced_names)``.

    Three rules, in order:

    * **No services means exactly the old behaviour.** A nails visit takes its
      length and price from :class:`AppSettings`; anything else takes the
      dog's. This is the compatibility guarantee, and there is a test on it.
    * A service marked ``takes_dog_defaults`` contributes the dog's own
      figures — that is what "Full Groom" means, and the breed grid supplies
      both from the same row.
    * **If any chosen service has no price, the total is None**, and the names
      come back so the booking check can say which. A partial sum is a wrong
      number on an invoice, and getting a wrong number onto an invoice is the
      whole reason ``nail_visit_price`` is deliberately blank.
    """
    services = list(services)
    settings_row = AppSettings.get()

    if not services:
        if service_type == ServiceType.NAILS_FLEAS_TICKS:
            minutes = settings_row.nail_visit_minutes or FALLBACK_NAIL_VISIT_MINUTES
            return minutes, settings_row.nail_visit_price, []
        return dog.effective_groom_minutes, dog.effective_price, []

    minutes = 0
    total = Decimal('0.00')
    unpriced = []
    for service in services:
        if service.takes_dog_defaults:
            minutes += dog.effective_groom_minutes
            total += dog.effective_price
            continue
        minutes += service.default_minutes or 0
        if service.default_price is None:
            unpriced.append(service.name)
        else:
            total += service.default_price

    if minutes == 0:
        # Every chosen service has a blank length. A zero-minute booking is
        # invisible in the diary, so fall back to the category's figure —
        # same reasoning as FALLBACK_NAIL_VISIT_MINUTES.
        if service_type == ServiceType.NAILS_FLEAS_TICKS:
            minutes = settings_row.nail_visit_minutes or FALLBACK_NAIL_VISIT_MINUTES
        else:
            minutes = dog.effective_groom_minutes

    return minutes, (None if unpriced else total), unpriced


class Appointment(models.Model):
    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='appointments')
    start_at = models.DateTimeField()
    end_at = models.DateTimeField()
    booking_type = models.CharField(max_length=12, choices=BookingType.choices, default=BookingType.ADHOC)
    service_type = models.CharField(
        max_length=10, choices=ServiceType.choices, default=ServiceType.GROOM,
    )
    status = models.CharField(max_length=12, choices=AppointmentStatus.choices, default=AppointmentStatus.BOOKED)
    services = models.ManyToManyField(
        Service, blank=True, related_name='appointments',
        help_text='What is being done. Drives the length and the quote.',
    )
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
        # start time is still complete.
        #
        # Deliberately resolved *without* services: on a create there is no pk
        # yet, so `self.services` cannot be read, and DRF sets many-to-manys
        # after `.save()` anyway. Reading it here would silently resolve every
        # new appointment against an empty list. Callers that know the
        # services set them and then call `apply_service_defaults()`.
        #
        # Only on insert. On an update the caller has been explicit, and a
        # null price is a real answer — "nothing on this booking has a price
        # yet". Defaulting on every save meant `apply_service_defaults`
        # carefully worked out None and then `save()` immediately replaced it
        # with the dog's groom price, quoting £50 for an unpriced service.
        if self._state.adding:
            minutes, price, _ = resolve_slot(self.dog, self.service_type)
            if self.start_at and not self.end_at:
                self.end_at = self.start_at + timedelta(minutes=minutes)
            if self.price_quoted is None:
                self.price_quoted = price
        super().save(*args, **kwargs)

    def apply_service_defaults(self, force_end=False, force_price=False):
        """Re-derive the end time and quote from the attached services.

        Call this **after** ``services.set(...)``, never before — see
        :meth:`save` for why it cannot happen there.

        ``force_*`` says whether to overwrite a value the caller supplied. The
        serializers pass ``field not in validated_data``, so an end time or a
        price Jess typed in is never quietly replaced by a computed one.

        Easy to miss: :class:`BookingSeries` materialisation also has to call
        this, or a standing nail-trim series blocks out three hours a
        fortnight forever.
        """
        services = list(self.services.all())
        minutes, price, _ = resolve_slot(self.dog, self.service_type, services)

        changed = []
        if force_end or not self.end_at:
            self.end_at = self.start_at + timedelta(minutes=minutes)
            changed.append('end_at')
        if force_price or self.price_quoted is None:
            self.price_quoted = price
            changed.append('price_quoted')
        if changed:
            self.save(update_fields=[*changed, 'updated_at'])
        return self

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


class AppointmentChangeRequest(models.Model):
    """A client asking to cancel or move one of their own bookings.

    Same shape as :class:`ClientChangeRequest` and :class:`ClientClaimRequest`,
    for the same reason: everything a client sends in is a request Jess
    reviews, never a direct write. Bookings in particular are hers — the diary
    is the business, and a client silently removing a slot from it (or worse,
    moving one on top of another dog) is not something to find out about later.

    Before this, a client who could not make it had **no in-app path at all**.
    They phoned, or they did not turn up. A no-show costs Jess the slot; a
    cancellation she hears about is a slot she can refill.

    ``appointment`` is checked against the requester's own client record in the
    viewset, never trusted from the body — the same rule as ``client`` on
    ClientChangeRequest, and for the same reason.
    """

    class Kind(models.TextChoices):
        CANCEL = 'CANCEL', 'Cancel'
        RESCHEDULE = 'RESCHEDULE', 'Move'

    appointment = models.ForeignKey(
        Appointment, on_delete=models.CASCADE, related_name='change_requests',
    )
    requested_by = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name='appointment_change_requests',
    )
    kind = models.CharField(max_length=10, choices=Kind.choices)
    preferred_start_at = models.DateTimeField(
        null=True, blank=True,
        help_text='Only meaningful for a reschedule, and only ever a preference.',
    )
    note = models.TextField(blank=True)
    status = models.CharField(max_length=10, choices=ReviewStatus.choices, default=ReviewStatus.PENDING)
    reviewed_by = models.ForeignKey(
        User, on_delete=models.SET_NULL, null=True, blank=True,
        related_name='reviewed_appointment_changes',
    )
    reviewed_at = models.DateTimeField(null=True, blank=True)
    review_notes = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'{self.get_kind_display()} request for {self.appointment} ({self.status})'

    def apply(self, start_at=None):
        """Carry out the request against the booking.

        ``start_at`` lets Jess approve a move to a *different* time from the one
        asked for, which is the common case — the client picks a time that
        clashes and she puts them in the next real gap. It mirrors
        ``ClientClaimRequestViewSet.approve`` taking a ``client_id`` the staff
        member chose rather than the one the server guessed.

        The length is carried over rather than recomputed. The booking's
        duration was already resolved from its services when it was made, and
        re-running ``resolve_slot`` here would silently re-price a booking Jess
        may have adjusted by hand.
        """
        appointment = self.appointment

        if self.kind == self.Kind.CANCEL:
            appointment.status = AppointmentStatus.CANCELLED
            appointment.save(update_fields=['status', 'updated_at'])
            return appointment

        new_start = start_at or self.preferred_start_at
        if new_start is None:
            # A reschedule with no time to move to is not actionable. Refusing
            # here rather than silently doing nothing, because "approved" on a
            # request that changed nothing is the worst of both.
            raise ValueError('A reschedule needs a time to move the booking to.')

        duration = appointment.end_at - appointment.start_at
        appointment.start_at = new_start
        appointment.end_at = new_start + duration
        appointment.save(update_fields=['start_at', 'end_at', 'updated_at'])
        return appointment


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
    # Nullable for the same reason, at Jess's request — "can we change to well
    # behaved like the bathed". A switch that starts off cannot tell "the dryer
    # was not used" from "nobody wrote it down", and on a dog that will not
    # tolerate one that is the fact worth having.
    high_velocity_dryer = models.BooleanField(null=True, blank=True)
    shampoo_used = models.CharField(max_length=120, blank=True)
    equipment_used = models.ManyToManyField(
        'Equipment', blank=True, related_name='groom_sessions',
    )
    # What was actually done, which is not the same as the pref_* fields on the
    # dog — those are what the owner asked for at intake.
    final_body = models.TextField(blank=True, verbose_name='Final body trim')
    final_feet = models.TextField(blank=True, verbose_name='Final feet shape')
    final_tail = models.TextField(blank=True, verbose_name='Final tail')
    # Jess's request. Note this goes **beyond the paper card**, which records
    # body, feet and tail only (docs/paper-cards.md) — the card is the spec for
    # everything else here, so the difference is deliberate rather than drift.
    # The dog still carries `pref_ears` and `pref_skirt` with no `final_`
    # counterpart; she asked for the face, so that is what this adds.
    final_face = models.TextField(blank=True, verbose_name='Final face shape')

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

        Refused too when the visit's appointment was only a *part* of a groom.
        The service catalogue made this necessary: before it, a GROOM visit
        was always a whole groom, but a 25-minute "Tidy Up" or "Bath and Blow
        Dry" is now one as well, and letting that overwrite a 105-minute
        ``Dog.groom_minutes`` is the same bug in a new coat.
        """
        if self.visit_type != ServiceType.GROOM:
            return False
        if not self._was_a_whole_groom():
            return False
        minutes = self.total_minutes
        if minutes <= 0:
            return False
        self.dog.groom_minutes = minutes
        self.dog.save(update_fields=['groom_minutes', 'updated_at'])
        self.applied_to_dog_at = timezone.now()
        self.save(update_fields=['applied_to_dog_at'])
        return True

    #: The status a booking held before this visit marked it completed, set by
    #: :meth:`link_to_appointment` and read straight back out by the serializer.
    #: Not a column: it is true of one save, not of the row.
    appointment_status_before = None

    def link_to_appointment(self):
        """Attach this visit to the booking it was worked against, and close it.

        Jess: *"did a 'groom for teddy', set an appointment and then did the
        timer and managed to add the session but wasn't automatically assigned
        to the appointment?"*. It wasn't. ``GroomTimerScreen`` took an
        ``appointmentId`` and the one place that opened it never passed one, so
        every session Jess has recorded came in unlinked.

        The second half matters more than the first. ``dogs_due`` counts
        *completed* appointments, so a groom that was worked but never marked
        off does not exist as far as the call list is concerned — which is how
        a dog groomed this morning is overdue by this evening.

        Narrow on purpose:

        * it only fills a **blank** appointment. An explicit one is Jess
          answering the question; this is a guess, and a guess does not get to
          overrule her.
        * only the **same local day**. That is what "today's booking" means in
          a diary, and a groom written up on Thursday must not close Tuesday's
          slot.
        * only a booking with **no session on it already**, so a nails visit
          and a groom on the same day don't both claim the one appointment.
        * only **active** bookings, so a cancelled one is never resurrected.
        * it only marks one done once it has actually **started**, so writing
          up this morning's groom cannot close this afternoon's booking.

        Returns the appointment now linked, or None. When it marked one
        completed it also leaves the status it replaced on
        ``appointment_status_before``, which the serializer hands to the app so
        the snack can offer to put it back. Marking a booking off the back of a
        different action is a fair thing to do and a poor thing to do silently
        — the app both says which booking it was and gives Jess one tap to
        undo it, which is what makes it reasonable to do automatically.
        """
        if self.appointment_id is None:
            day = timezone.localtime(self.started_at).date()
            candidates = (
                Appointment.objects
                .filter(
                    dog_id=self.dog_id,
                    start_at__date=day,
                    status__in=Appointment.ACTIVE_STATUSES,
                )
                .exclude(groom_sessions__isnull=False)
            )
            # Nearest to when the timer ran, for the rare day with two.
            match = min(
                candidates, key=lambda appt: abs(appt.start_at - self.started_at), default=None,
            )
            if match is None:
                return None
            self.appointment = match
            self.save(update_fields=['appointment'])

        appointment = self.appointment
        if (
            appointment.status != AppointmentStatus.COMPLETED
            and appointment.start_at <= timezone.now()
        ):
            self.appointment_status_before = appointment.status
            appointment.status = AppointmentStatus.COMPLETED
            appointment.save(update_fields=['status', 'updated_at'])
        return appointment

    def save(self, *args, **kwargs):
        """Save, then re-derive the dog's average groom time.

        Here rather than in a nightly job because the figure has to be right
        the moment Jess finishes writing a visit up and books the next one.
        """
        super().save(*args, **kwargs)
        self._refresh_dog_average()

    def delete(self, *args, **kwargs):
        # Hold the dog before the row goes, or there is nothing to recalculate
        # against afterwards.
        dog = self.dog
        result = super().delete(*args, **kwargs)
        dog.recalculate_average_groom_minutes()
        return result

    def _refresh_dog_average(self):
        # `update_fields` on the dog is deliberately narrow, so this cannot
        # clobber a concurrent edit to the rest of the profile.
        self.dog.recalculate_average_groom_minutes()

    def _was_a_whole_groom(self):
        """Whether this session's time is a fair default for a full groom.

        True when nothing says otherwise — no appointment, or an appointment
        with no services attached, which is every booking made before the
        catalogue existed. Once services *are* attached, only a full groom
        counts.
        """
        if self.appointment_id is None:
            return True
        services = list(self.appointment.services.all())
        if not services:
            return True
        return any(service.takes_dog_defaults for service in services)


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
    number = models.CharField(max_length=32, unique=True, blank=True)
    issue_date = models.DateField(default=timezone.localdate)
    due_date = models.DateField(null=True, blank=True)
    status = models.CharField(max_length=6, choices=Status.choices, default=Status.DRAFT)
    # When, not just whether. "Record sent" wants a date against it, and a
    # status column alone cannot say when it happened.
    sent_at = models.DateField(null=True, blank=True)
    # Not redundant with Payment.paid_at: Jess can mark cash-in-hand paid
    # without recording an amount against it.
    paid_at = models.DateField(null=True, blank=True)
    notes = models.TextField(blank=True)
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='invoices')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    #: Where an invoice may go next.
    #:
    #: Paid is the end of the road. Jess's complaint was that marking an
    #: invoice sent *after* recording payment left it showing as merely sent,
    #: so she would chase money she already had. ``PAID -> VOID`` stays,
    #: because a one-groomer business needs a way to cancel a mistake and a
    #: credit-note model is more machinery than this deserves.
    #:
    #: ``SENT -> DRAFT`` stays too: an invoice sent with the wrong figure on
    #: it has to be editable again.
    TRANSITIONS = {
        Status.DRAFT: {Status.SENT, Status.PAID, Status.VOID},
        Status.SENT: {Status.PAID, Status.VOID, Status.DRAFT},
        Status.PAID: {Status.VOID},
        Status.VOID: set(),
    }

    class Meta:
        ordering = ['-issue_date', '-id']

    def __str__(self):
        return f'{self.number} — {self.client.full_name}'

    #: Prefix for generated numbers. Kept short because it is read down the
    #: phone and copied onto a bank transfer.
    NUMBER_PREFIX = 'INV-'

    @classmethod
    def next_number(cls):
        """The next sequential invoice number, e.g. ``INV-0007``.

        Numbering belonged on the server rather than the app, which filled it
        with ``INV-${millisecondsSinceEpoch % 100000}``. That is not a number
        anybody can read down a phone, it does not sort, it tells a client
        nothing, and modulo a timestamp it can collide — two invoices raised in
        the same millisecond-mod-100000 window would hit the unique constraint
        and fail in front of Jess with nothing useful to say.

        Only ``NUMBER_PREFIX``-shaped numbers count towards the sequence, so a
        hand-typed one ("2026-04-CASH") sits alongside without shifting it.

        Not a global counter row: a one-groomer business raises a few invoices
        a week, and MAX+1 over an indexed unique column costs nothing next to
        another table to keep in step. The unique constraint is the real
        guarantee either way — see ``save``.
        """
        numbers = cls.objects.filter(
            number__startswith=cls.NUMBER_PREFIX,
        ).values_list('number', flat=True)

        highest = 0
        for number in numbers:
            tail = number[len(cls.NUMBER_PREFIX):]
            if tail.isdigit():
                highest = max(highest, int(tail))
        return f'{cls.NUMBER_PREFIX}{highest + 1:04d}'

    def save(self, *args, **kwargs):
        """Fill in a blank number, retrying if someone got there first.

        ``next_number`` reads then writes, so two invoices raised at once can
        pick the same one. The unique index catches that — this turns the
        IntegrityError into a second attempt rather than an error page. Bounded,
        because an unbounded retry on a genuinely duplicate hand-typed number
        would spin forever.
        """
        if self.number:
            return super().save(*args, **kwargs)

        for _ in range(5):
            self.number = self.next_number()
            try:
                with transaction.atomic():
                    return super().save(*args, **kwargs)
            except IntegrityError:
                # Someone else took it between the read and the write. Only
                # force_insert can be retried safely; on an update the pk is
                # already set and re-saving is fine either way.
                kwargs.pop('force_insert', None)
                continue

        raise IntegrityError(
            'Could not allocate an invoice number after several attempts.'
        )

    def can_transition_to(self, new_status):
        """Whether this invoice may move to ``new_status``.

        Checked by the ``mark_sent``/``mark_paid`` actions *and* by
        ``InvoiceSerializer.validate_status``. Status is a plain writable
        field that the app PATCHes directly, so governing only the actions
        would make them decorative.
        """
        if new_status == self.status:
            return True
        return new_status in self.TRANSITIONS.get(self.status, set())

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
