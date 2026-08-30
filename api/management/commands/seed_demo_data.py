"""Create or refresh the demo client the store screenshots sign in as.

The Store Screenshots workflow (and App Review, eventually) signs into the
live app with a demo account and photographs what it sees, so the account has
to exist on the real backend and have something worth photographing: a dog, an
upcoming booking, and a couple of written-up grooms whose reports the owner
can open.

A **client** account, never staff. The credentials leave the building — they
sit in GitHub secrets and will be handed to App Review — and a staff login is
Jess's entire client book. ``ClientScopedMixin`` confines this account to the
records seeded here.

Idempotent on purpose: CI may run it before every capture, and the fixed UID
(``MOJO-DEMO``) is both the marker that makes re-runs update-in-place and the
flag that keeps the record recognisable in Jess's client list. Nothing outside
the demo client is ever touched.

    python manage.py seed_demo_data --password 's3cret'
    python manage.py seed_demo_data --username demo --password 's3cret' --email demo@mojoandco.uk
"""

from datetime import timedelta

from django.contrib.auth.models import User
from django.core.management.base import BaseCommand
from django.utils import timezone

from api.models import (
    Appointment,
    AppointmentStatus,
    BookingType,
    Breed,
    Client,
    Dog,
    GroomSession,
    ServiceType,
    Temperament,
)

DEMO_UID = 'MOJO-DEMO'


class Command(BaseCommand):
    help = 'Create or refresh the demo client account the store screenshots sign in as.'

    def add_arguments(self, parser):
        parser.add_argument('--username', default='demo')
        parser.add_argument('--password', required=True,
                            help='Set every run — this is the only place it is ever supplied.')
        parser.add_argument('--email', default='demo@mojoandco.uk')

    def handle(self, *args, **options):
        username = options['username']
        email = options['email']

        user, created_user = User.objects.get_or_create(
            username=username, defaults={'email': email},
        )
        user.email = email
        user.set_password(options['password'])
        user.save()

        client, created_client = Client.objects.get_or_create(
            uid=DEMO_UID,
            defaults={
                'first_name': 'Daisy',
                'last_name': 'Demo',
                'email': email,
                'phone': '07700 900123',
                'postcode': 'RG9 6SN',
            },
        )
        # Always repointed, so a demo login recreated under a new name still
        # reaches the same seeded records.
        client.user = user
        client.save()

        breed = (
            Breed.objects.filter(name__icontains='Cockapoo').first()
            or Breed.objects.first()
        )
        dog, _ = Dog.objects.get_or_create(
            client=client,
            name='Mojo',
            defaults={
                'breed': breed,
                'sex': 'M',
                'is_neutered': True,
                'date_of_birth': timezone.localdate() - timedelta(days=3 * 365),
                'colour': 'Apricot',
                'pref_body': 'Teddy trim, about an inch all over',
                'pref_face': 'Round teddy face, eyes clear',
                'pref_tail': 'Natural, tidied',
            },
        )

        # An upcoming booking, so My Bookings has a future to show. 10:00 a
        # week on Tuesday, sized to the dog's effective groom time.
        now = timezone.localtime()
        if not dog.appointments.filter(
            start_at__gte=now, status__in=Appointment.ACTIVE_STATUSES,
        ).exists():
            days_ahead = (1 - now.weekday()) % 7 + 7  # next week's Tuesday
            start = (now + timedelta(days=days_ahead)).replace(
                hour=10, minute=0, second=0, microsecond=0,
            )
            Appointment.objects.create(
                dog=dog,
                start_at=start,
                end_at=start + timedelta(minutes=dog.effective_groom_minutes),
                status=AppointmentStatus.BOOKED,
                booking_type=BookingType.SCHEDULED,
                service_type=ServiceType.GROOM,
            )

        # Two written-up grooms, so the dog profile carries groom reports the
        # walkthrough can open. Only owner-readable fields carry wording — the
        # report is a whitelist, but a demo account is still no place to write
        # pretend staff notes.
        if dog.groom_sessions.count() < 2:
            for weeks_ago, notes, checklist_notes, ears in (
                (6, 'Lovely as always — coat in great condition.', '', True),
                (12, 'Settled quickly and stood beautifully for the dryer.',
                 'Left the ears this time — a little tender after swimming.', False),
            ):
                GroomSession.objects.create(
                    dog=dog,
                    visit_type=ServiceType.GROOM,
                    started_at=now - timedelta(weeks=weeks_ago),
                    health_check_done=True,
                    nails_done=True,
                    ears_cleaned=ears,
                    hygiene_area_done=True,
                    feet_clipped_out=True,
                    bathed=True,
                    blow_dried=True,
                    usual_groom_done=True,
                    checklist_notes=checklist_notes,
                    notes=notes,
                    temperament_observed=Temperament.EASY,
                    recorded_minutes=95,
                )

        self.stdout.write(self.style.SUCCESS(
            f'Demo account ready: {username} → {client.full_name} ({DEMO_UID}), '
            f'dog {dog.name}, {dog.appointments.count()} booking(s), '
            f'{dog.groom_sessions.count()} visit(s). '
            f'{"Created" if created_user else "Updated"} the login; '
            f'{"created" if created_client else "kept"} the client record.'
        ))
