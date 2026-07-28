"""Integration tests for the API.

The bulk of these guard the two access-control rules the whole design rests on:
a client may only ever reach their own records, and Jess's private working
notes (temperament, chatty, staff notes) never reach a client. Everything else
tests behaviour the notes call out explicitly — warnings that don't block,
single-use intake links, groom timings feeding back into the diary.
"""

from datetime import date, time, timedelta
from decimal import Decimal

from django.contrib.auth.models import User
from django.core.cache import cache
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from .models import (
    AppSettings,
    Appointment,
    AppointmentStatus,
    Breed,
    Client,
    ClientClaimRequest,
    ClosureDay,
    Dog,
    GroomPhase,
    GroomSession,
    IntakeInvite,
    Invoice,
    OpeningHours,
    PhaseTiming,
    ProblemArea,
    Temperament,
    TemperamentLimit,
)


class BaseAPITestCase(APITestCase):
    """Two clients with a dog each, plus a staff login."""

    def setUp(self):
        # DRF keeps throttle history in the cache, which persists for the whole
        # test run. Without this, tests silently start throttling each other
        # and fail with 429s that have nothing to do with what they assert.
        cache.clear()

        self.staff = User.objects.create_user('jess', password='pw', is_staff=True, is_superuser=True)

        self.breed = Breed.objects.create(
            name='Cockapoo (small)', coat_type='curly',
            avg_groom_minutes=105, avg_price=Decimal('50.00'), avg_schedule_weeks=6,
        )

        self.alice_user = User.objects.create_user('alice', password='pw')
        self.alice = Client.objects.create(
            uid='MOJO-001', first_name='Alice', last_name='Adams',
            email='alice@example.com', phone='07700900001', postcode='RG1 1AA',
            user=self.alice_user, chatty=True, leaflet_received=True, notes='Always late.',
        )
        self.alice_dog = Dog.objects.create(
            client=self.alice, name='Biscuit', breed=self.breed,
            temperament=Temperament.FEISTY, temperament_notes='Muzzle for nails.',
        )

        self.bob_user = User.objects.create_user('bob', password='pw')
        self.bob = Client.objects.create(
            uid='MOJO-002', first_name='Bob', last_name='Brown',
            email='bob@example.com', phone='07700900002', postcode='RG2 2BB',
            user=self.bob_user,
        )
        self.bob_dog = Dog.objects.create(client=self.bob, name='Rolo', breed=self.breed)

        self.staff_client = APIClient()
        self.staff_client.force_authenticate(self.staff)
        self.alice_client = APIClient()
        self.alice_client.force_authenticate(self.alice_user)


class ClientIsolationTests(BaseAPITestCase):
    """A client must never reach another client's records."""

    def test_client_dog_list_shows_only_own_dogs(self):
        response = self.alice_client.get('/api/dogs/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        names = [dog['name'] for dog in response.data['results']]
        self.assertEqual(names, ['Biscuit'])

    def test_client_cannot_fetch_another_clients_dog(self):
        response = self.alice_client.get(f'/api/dogs/{self.bob_dog.pk}/')
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_client_cannot_fetch_another_client_record(self):
        response = self.alice_client.get(f'/api/clients/{self.bob.pk}/')
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_client_cannot_see_another_clients_appointments(self):
        start = timezone.now() + timedelta(days=1)
        Appointment.objects.create(dog=self.bob_dog, start_at=start, end_at=start + timedelta(hours=2))
        response = self.alice_client.get('/api/appointments/')
        self.assertEqual(response.data['count'], 0)

    def test_staff_sees_everything(self):
        response = self.staff_client.get('/api/dogs/')
        self.assertEqual(response.data['count'], 2)

    def test_user_with_no_client_record_sees_nothing(self):
        stranger = User.objects.create_user('stranger', password='pw')
        client = APIClient()
        client.force_authenticate(stranger)
        self.assertEqual(client.get('/api/dogs/').data['count'], 0)
        self.assertEqual(client.get('/api/clients/').data['count'], 0)

    def test_anonymous_access_is_refused(self):
        self.assertEqual(APIClient().get('/api/dogs/').status_code, status.HTTP_401_UNAUTHORIZED)


class StaffOnlyFieldTests(BaseAPITestCase):
    """Jess's private notes must not appear in any client-facing payload."""

    HIDDEN_DOG_FIELDS = ['temperament', 'temperament_display', 'temperament_notes', 'problem_areas']
    HIDDEN_CLIENT_FIELDS = ['chatty', 'leaflet_received', 'notes']

    def test_dog_detail_hides_temperament_from_client(self):
        response = self.alice_client.get(f'/api/dogs/{self.alice_dog.pk}/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        for field in self.HIDDEN_DOG_FIELDS:
            self.assertNotIn(field, response.data, f'{field} leaked to a client')

    def test_dog_list_hides_temperament_from_client(self):
        response = self.alice_client.get('/api/dogs/')
        row = response.data['results'][0]
        self.assertNotIn('temperament', row)
        self.assertNotIn('temperament_display', row)
        # The non-sensitive summary values are still there.
        self.assertEqual(row['groom_minutes_effective'], 105)

    def test_client_detail_hides_chatty_and_notes(self):
        response = self.alice_client.get(f'/api/clients/{self.alice.pk}/')
        for field in self.HIDDEN_CLIENT_FIELDS:
            self.assertNotIn(field, response.data, f'{field} leaked to a client')

    def test_nested_client_detail_on_dog_also_hides_fields(self):
        """The embedded owner block must be gated too, not just the top level."""
        response = self.alice_client.get(f'/api/dogs/{self.alice_dog.pk}/')
        nested = response.data['client_detail']
        for field in self.HIDDEN_CLIENT_FIELDS:
            self.assertNotIn(field, nested, f'{field} leaked via client_detail')

    def test_appointment_hides_dog_temperament_from_client(self):
        start = timezone.now() + timedelta(days=1)
        Appointment.objects.create(dog=self.alice_dog, start_at=start, end_at=start + timedelta(hours=2))
        response = self.alice_client.get('/api/appointments/')
        self.assertNotIn('dog_temperament', response.data['results'][0])

    def test_staff_still_sees_the_gated_fields(self):
        response = self.staff_client.get(f'/api/dogs/{self.alice_dog.pk}/')
        self.assertEqual(response.data['temperament'], Temperament.FEISTY)
        self.assertEqual(response.data['temperament_notes'], 'Muzzle for nails.')
        self.assertIn('problem_areas', response.data)

        client_response = self.staff_client.get(f'/api/clients/{self.alice.pk}/')
        self.assertTrue(client_response.data['chatty'])
        self.assertEqual(client_response.data['notes'], 'Always late.')

    def test_client_cannot_write_a_gated_field(self):
        """A dropped field is ignored on input, so the value must not change."""
        response = self.alice_client.patch(
            f'/api/dogs/{self.alice_dog.pk}/',
            {'temperament': Temperament.EASY, 'general_notes': 'Likes a biscuit'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.temperament, Temperament.FEISTY)
        self.assertEqual(self.alice_dog.general_notes, 'Likes a biscuit')

    def test_client_cannot_read_problem_areas_endpoint(self):
        ProblemArea.objects.create(dog=self.alice_dog, grid_cells=['r3c5'], reason='Sore hip')
        self.assertEqual(
            self.alice_client.get('/api/problem-areas/').status_code, status.HTTP_403_FORBIDDEN,
        )
        self.assertEqual(
            self.alice_client.get(f'/api/dogs/{self.alice_dog.pk}/problem_areas/').status_code,
            status.HTTP_403_FORBIDDEN,
        )


class PrivilegeEscalationTests(BaseAPITestCase):
    def test_user_cannot_grant_themselves_capabilities(self):
        response = self.alice_client.patch(
            '/api/me/',
            {'can_manage_bookings': True, 'can_manage_invoices': True, 'phone': '07700900999'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.alice_user.profile.refresh_from_db()
        self.assertFalse(self.alice_user.profile.can_manage_bookings)
        self.assertFalse(self.alice_user.profile.can_manage_invoices)
        # The legitimate field on the same request still applied.
        self.assertEqual(self.alice_user.profile.phone, '07700900999')

    def test_client_cannot_create_a_dog(self):
        response = self.alice_client.post(
            '/api/dogs/', {'client': self.alice.pk, 'name': 'Sneaky'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_client_cannot_create_a_client_record(self):
        response = self.alice_client.post(
            '/api/clients/', {'uid': 'MOJO-999', 'first_name': 'Mallory'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_client_cannot_edit_or_delete_a_booking(self):
        start = timezone.now() + timedelta(days=1)
        appointment = Appointment.objects.create(
            dog=self.alice_dog, start_at=start, end_at=start + timedelta(hours=2),
        )
        patch = self.alice_client.patch(
            f'/api/appointments/{appointment.pk}/', {'notes': 'move it'}, format='json',
        )
        self.assertEqual(patch.status_code, status.HTTP_403_FORBIDDEN)
        delete = self.alice_client.delete(f'/api/appointments/{appointment.pk}/')
        self.assertEqual(delete.status_code, status.HTTP_403_FORBIDDEN)

    def test_client_appointment_request_lands_as_requested(self):
        start = timezone.now() + timedelta(days=3)
        response = self.alice_client.post(
            '/api/appointments/',
            {'dog': self.alice_dog.pk, 'start_at': start.isoformat()},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data['status'], AppointmentStatus.REQUESTED)

    def test_client_cannot_request_for_another_clients_dog(self):
        start = timezone.now() + timedelta(days=3)
        response = self.alice_client.post(
            '/api/appointments/',
            {'dog': self.bob_dog.pk, 'start_at': start.isoformat()},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_client_cannot_reach_staff_only_endpoints(self):
        for path in ['/api/equipment/', '/api/todos/', '/api/groom-sessions/',
                     '/api/intake-submissions/', '/api/temperament-limits/', '/api/booking-series/']:
            self.assertEqual(
                self.alice_client.get(path).status_code, status.HTTP_403_FORBIDDEN,
                f'{path} was reachable by a client',
            )


class BookingWarningTests(BaseAPITestCase):
    """Warnings must surface, and must never block the booking."""

    def setUp(self):
        super().setUp()
        TemperamentLimit.objects.create(temperament=Temperament.FEISTY, max_per_day=1)
        TemperamentLimit.objects.create(temperament=Temperament.FIDGETY, max_per_day=2)
        TemperamentLimit.objects.create(temperament=Temperament.EASY, max_per_day=None)
        for weekday in range(5):
            OpeningHours.objects.create(
                weekday=weekday, open_time=time(9, 0), close_time=time(17, 0),
            )
        OpeningHours.objects.create(weekday=5, is_closed=True)
        OpeningHours.objects.create(weekday=6, is_closed=True)

    def _next_weekday_at(self, hour, minute=0):
        """A datetime on the next Monday, so opening-hours tests are stable."""
        today = timezone.localdate()
        days_ahead = (7 - today.weekday()) % 7 or 7
        target = today + timedelta(days=days_ahead)
        return timezone.make_aware(
            timezone.datetime.combine(target, time(hour, minute)),
            timezone.get_current_timezone(),
        )

    def test_second_feisty_dog_warns_but_booking_still_succeeds(self):
        start = self._next_weekday_at(9, 30)
        Appointment.objects.create(dog=self.alice_dog, start_at=start, end_at=start + timedelta(minutes=105))

        other_feisty = Dog.objects.create(
            client=self.bob, name='Tank', breed=self.breed, temperament=Temperament.FEISTY,
        )
        later = self._next_weekday_at(13, 0)

        check = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': other_feisty.pk, 'start_at': later.isoformat()},
            format='json',
        )
        self.assertEqual(check.status_code, status.HTTP_200_OK)
        codes = [warning['code'] for warning in check.data['warnings']]
        self.assertIn('temperament_limit', codes)

        # The warning is advisory — the booking must still go through.
        created = self.staff_client.post(
            '/api/appointments/',
            {'dog': other_feisty.pk, 'start_at': later.isoformat()},
            format='json',
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)

    def test_third_fidgety_dog_warns(self):
        fidgety = [
            Dog.objects.create(
                client=self.bob, name=f'Fidget{index}', breed=self.breed,
                temperament=Temperament.FIDGETY,
            )
            for index in range(3)
        ]
        base = self._next_weekday_at(9, 0)
        for index in range(2):
            Appointment.objects.create(
                dog=fidgety[index],
                start_at=base + timedelta(hours=index * 2),
                end_at=base + timedelta(hours=index * 2 + 1),
            )

        response = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': fidgety[2].pk, 'start_at': (base + timedelta(hours=6)).isoformat()},
            format='json',
        )
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertIn('temperament_limit', codes)

    def test_under_the_limit_produces_no_temperament_warning(self):
        easy = Dog.objects.create(
            client=self.bob, name='Mellow', breed=self.breed, temperament=Temperament.EASY,
        )
        response = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': easy.pk, 'start_at': self._next_weekday_at(10, 0).isoformat()},
            format='json',
        )
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertNotIn('temperament_limit', codes)

    def test_booking_outside_opening_hours_warns_but_succeeds(self):
        start = self._next_weekday_at(19, 0)
        check = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': self.bob_dog.pk, 'start_at': start.isoformat()},
            format='json',
        )
        codes = [warning['code'] for warning in check.data['warnings']]
        self.assertIn('outside_opening_hours', codes)

        created = self.staff_client.post(
            '/api/appointments/',
            {'dog': self.bob_dog.pk, 'start_at': start.isoformat()},
            format='json',
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)

    def test_closure_day_warns(self):
        start = self._next_weekday_at(10, 0)
        ClosureDay.objects.create(date=timezone.localtime(start).date(), reason='Training day')
        response = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': self.bob_dog.pk, 'start_at': start.isoformat()},
            format='json',
        )
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertIn('closure_day', codes)

    def test_overlapping_booking_warns(self):
        start = self._next_weekday_at(10, 0)
        Appointment.objects.create(
            dog=self.alice_dog, start_at=start, end_at=start + timedelta(minutes=105),
        )
        response = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': self.bob_dog.pk, 'start_at': (start + timedelta(minutes=30)).isoformat()},
            format='json',
        )
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertIn('overlap', codes)

    def test_editing_a_booking_does_not_flag_itself(self):
        """Excluding the appointment under edit stops it clashing with itself."""
        start = self._next_weekday_at(10, 0)
        appointment = Appointment.objects.create(
            dog=self.alice_dog, start_at=start, end_at=start + timedelta(minutes=105),
        )
        response = self.staff_client.post(
            '/api/appointments/check/',
            {
                'dog': self.alice_dog.pk,
                'start_at': start.isoformat(),
                'exclude_appointment': appointment.pk,
            },
            format='json',
        )
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertNotIn('overlap', codes)
        self.assertNotIn('temperament_limit', codes)

    def test_cancelled_bookings_do_not_count_towards_limits(self):
        start = self._next_weekday_at(9, 30)
        Appointment.objects.create(
            dog=self.alice_dog, start_at=start, end_at=start + timedelta(minutes=105),
            status=AppointmentStatus.CANCELLED,
        )
        other_feisty = Dog.objects.create(
            client=self.bob, name='Tank', breed=self.breed, temperament=Temperament.FEISTY,
        )
        response = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': other_feisty.pk, 'start_at': self._next_weekday_at(13, 0).isoformat()},
            format='json',
        )
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertNotIn('temperament_limit', codes)


class AppointmentDefaultsTests(BaseAPITestCase):
    def test_end_time_defaults_to_the_dogs_groom_time(self):
        start = timezone.now() + timedelta(days=1)
        response = self.staff_client.post(
            '/api/appointments/', {'dog': self.alice_dog.pk, 'start_at': start.isoformat()},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data['duration_minutes'], 105)
        self.assertEqual(Decimal(response.data['price_quoted']), Decimal('50.00'))

    def test_dog_override_beats_the_breed_default(self):
        self.alice_dog.groom_minutes = 150
        self.alice_dog.price = Decimal('70.00')
        self.alice_dog.save()

        start = timezone.now() + timedelta(days=1)
        response = self.staff_client.post(
            '/api/appointments/', {'dog': self.alice_dog.pk, 'start_at': start.isoformat()},
            format='json',
        )
        self.assertEqual(response.data['duration_minutes'], 150)
        self.assertEqual(Decimal(response.data['price_quoted']), Decimal('70.00'))

    def test_end_before_start_is_rejected(self):
        start = timezone.now() + timedelta(days=1)
        response = self.staff_client.post(
            '/api/appointments/',
            {
                'dog': self.alice_dog.pk,
                'start_at': start.isoformat(),
                'end_at': (start - timedelta(hours=1)).isoformat(),
            },
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class GroomSessionTests(BaseAPITestCase):
    def test_applying_a_session_updates_the_dogs_groom_time(self):
        session = GroomSession.objects.create(dog=self.alice_dog)
        PhaseTiming.objects.create(session=session, phase=GroomPhase.PREP, duration_seconds=600)
        PhaseTiming.objects.create(session=session, phase=GroomPhase.WASH, duration_seconds=1200)
        PhaseTiming.objects.create(session=session, phase=GroomPhase.CLIP, duration_seconds=3600)

        response = self.staff_client.post(f'/api/groom-sessions/{session.pk}/apply_to_dog/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.groom_minutes, 90)  # 600 + 1200 + 3600 = 90 minutes
        self.assertEqual(self.alice_dog.effective_groom_minutes, 90)

    def test_applying_an_empty_session_is_rejected(self):
        session = GroomSession.objects.create(dog=self.alice_dog)
        response = self.staff_client.post(f'/api/groom-sessions/{session.pk}/apply_to_dog/')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_partial_phases_are_fine(self):
        """A wash and blow-dry records no clip or strip."""
        response = self.staff_client.post(
            '/api/groom-sessions/',
            {
                'dog': self.alice_dog.pk,
                'timings': [
                    {'phase': GroomPhase.WASH, 'duration_seconds': 900},
                    {'phase': GroomPhase.DRY, 'duration_seconds': 1500},
                ],
            },
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data['total_minutes'], 40)


class IntakeFormTests(BaseAPITestCase):
    def setUp(self):
        super().setUp()
        self.invite = IntakeInvite.objects.create(
            email='newclient@example.com',
            expires_at=timezone.now() + timedelta(days=7),
        )
        self.public = APIClient()

    def _payload(self):
        return {
            'first_name': 'Carol',
            'last_name': 'Clark',
            'email': 'newclient@example.com',
            'phone': '07700900003',
            'postcode': 'RG3 3CC',
            'dogs': [{
                'name': 'Pepper',
                'breed': 'Cockapoo (small)',
                'pref_feet': 'Round',
                'problem_areas': [{'grid_cells': ['r2c4', 'r2c5'], 'reason': 'Dislikes back feet touched'}],
            }],
        }

    def test_intake_form_works_without_a_login(self):
        response = self.public.get(f'/api/intake/{self.invite.token}/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['email'], 'newclient@example.com')

    def test_submission_creates_a_pending_record(self):
        response = self.public.post(
            f'/api/intake/{self.invite.token}/', self._payload(), format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        # Nothing has entered the live records yet.
        self.assertFalse(Client.objects.filter(email='newclient@example.com').exists())

    def test_token_is_single_use(self):
        self.public.post(f'/api/intake/{self.invite.token}/', self._payload(), format='json')
        second = self.public.post(f'/api/intake/{self.invite.token}/', self._payload(), format='json')
        self.assertEqual(second.status_code, status.HTTP_410_GONE)
        self.assertEqual(
            self.public.get(f'/api/intake/{self.invite.token}/').status_code, status.HTTP_410_GONE,
        )

    def test_expired_token_is_refused(self):
        expired = IntakeInvite.objects.create(
            email='late@example.com', expires_at=timezone.now() - timedelta(days=1),
        )
        response = self.public.get(f'/api/intake/{expired.token}/')
        self.assertEqual(response.status_code, status.HTTP_410_GONE)

    def test_unknown_token_is_not_found(self):
        self.assertEqual(
            self.public.get('/api/intake/not-a-real-token/').status_code, status.HTTP_404_NOT_FOUND,
        )

    def test_submission_requires_at_least_one_named_dog(self):
        payload = self._payload()
        payload['dogs'] = []
        self.assertEqual(
            self.public.post(f'/api/intake/{self.invite.token}/', payload, format='json').status_code,
            status.HTTP_400_BAD_REQUEST,
        )

        payload['dogs'] = [{'name': '  '}]
        self.assertEqual(
            self.public.post(f'/api/intake/{self.invite.token}/', payload, format='json').status_code,
            status.HTTP_400_BAD_REQUEST,
        )

    def test_off_grid_problem_area_is_rejected(self):
        payload = self._payload()
        payload['dogs'][0]['problem_areas'] = [{'grid_cells': ['r99c99'], 'reason': 'nope'}]
        self.assertEqual(
            self.public.post(f'/api/intake/{self.invite.token}/', payload, format='json').status_code,
            status.HTTP_400_BAD_REQUEST,
        )

    def test_approval_creates_client_dog_and_problem_areas(self):
        self.public.post(f'/api/intake/{self.invite.token}/', self._payload(), format='json')
        submission_id = self.staff_client.get('/api/intake-submissions/').data['results'][0]['id']

        response = self.staff_client.post(
            f'/api/intake-submissions/{submission_id}/approve/',
            {'client_uid': 'MOJO-003'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        client = Client.objects.get(uid='MOJO-003')
        dog = client.dogs.get(name='Pepper')
        self.assertEqual(dog.breed, self.breed)
        self.assertEqual(dog.pref_feet, 'Round')

        area = dog.problem_areas.first()
        self.assertEqual(area.grid_cells, ['r2c4', 'r2c5'])
        self.assertEqual(area.source, ProblemArea.Source.INTAKE)

    def test_approval_rejects_a_duplicate_uid(self):
        self.public.post(f'/api/intake/{self.invite.token}/', self._payload(), format='json')
        submission_id = self.staff_client.get('/api/intake-submissions/').data['results'][0]['id']
        response = self.staff_client.post(
            f'/api/intake-submissions/{submission_id}/approve/',
            {'client_uid': 'MOJO-001'},  # Alice already has this.
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)


class IntakeFormPageTests(BaseAPITestCase):
    """The intake form is a web page, opened from an email by someone who has
    no account and no app. If this 404s, the whole intake feature is unusable
    no matter how well the API behind it works."""

    def setUp(self):
        super().setUp()
        self.invite = IntakeInvite.objects.create(
            email='newclient@example.com',
            expires_at=timezone.now() + timedelta(days=7),
        )
        self.public = APIClient()

    def test_the_link_staff_send_actually_resolves(self):
        response = self.public.get(f'/intake/{self.invite.token}/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn('text/html', response['Content-Type'])

    def test_it_works_without_a_trailing_slash(self):
        # Email clients and hand-typed links routinely drop it.
        self.assertEqual(
            self.public.get(f'/intake/{self.invite.token}').status_code,
            status.HTTP_200_OK,
        )

    def test_the_page_carries_what_the_form_needs(self):
        html = self.public.get(f'/intake/{self.invite.token}/').content.decode()
        self.assertIn(self.invite.email, html)
        self.assertIn(f'/api/intake/{self.invite.token}/', html)
        # The silhouette is inlined, not linked, so there is no second request.
        self.assertIn('<svg', html)
        self.assertIn('viewBox', html)
        # Breeds are rendered server-side for the datalist.
        self.assertIn(self.breed.name, html)

    def test_the_grid_matches_the_server_constants(self):
        html = self.public.get(f'/intake/{self.invite.token}/').content.decode()
        self.assertIn(f'var COLS = {ProblemArea.GRID_COLUMNS}', html)
        self.assertIn(f'var ROWS = {ProblemArea.GRID_ROWS}', html)

    def test_a_used_link_explains_itself_rather_than_erroring(self):
        self.invite.used_at = timezone.now()
        self.invite.save()
        response = self.public.get(f'/intake/{self.invite.token}/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn('already been filled in', response.content.decode())

    def test_an_expired_link_explains_itself(self):
        self.invite.expires_at = timezone.now() - timedelta(days=1)
        self.invite.save()
        html = self.public.get(f'/intake/{self.invite.token}/').content.decode()
        self.assertIn('expired', html)

    def test_an_unknown_token_is_404_not_a_crash(self):
        response = self.public.get('/intake/not-a-real-token/')
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_the_page_does_not_leak_the_token_to_search_engines(self):
        html = self.public.get(f'/intake/{self.invite.token}/').content.decode()
        self.assertIn('noindex', html)

    def test_the_grid_is_reachable_without_a_pointer(self):
        """96 silent shapes would make this section unusable on a screen
        reader, on a public form filled in by members of the public."""
        html = self.public.get(f'/intake/{self.invite.token}/').content.decode()
        for attribute in ["role', 'checkbox'", "aria-checked", "aria-label", "tabindex"]:
            self.assertIn(attribute, html, f'{attribute} wiring is missing')
        # Space and Enter toggle a focused cell.
        self.assertIn("keydown", html)
        # The grid announces which way the dog faces; there is no other cue.
        self.assertIn('faces left', html)

    def test_grid_strokes_do_not_scale_with_the_viewbox(self):
        """The grid shares the artwork's 2605-unit viewBox, so a plain
        stroke-width of 1 renders at about 0.12 CSS px — invisible."""
        html = self.public.get(f'/intake/{self.invite.token}/').content.decode()
        self.assertIn('non-scaling-stroke', html)

    def test_silhouette_is_shared_with_the_mobile_app(self):
        """One copy of the artwork, so the web form and the app never drift."""
        from api.views import load_silhouette_svg

        markup = load_silhouette_svg()
        self.assertTrue(markup, 'silhouette asset failed to load')
        self.assertNotIn('<?xml', markup, 'XML prolog must be stripped for inlining')
        self.assertIn('<svg', markup)


class ClaimRequestTests(BaseAPITestCase):
    def setUp(self):
        super().setUp()
        self.unclaimed = Client.objects.create(
            uid='MOJO-010', first_name='Dana', last_name='Doe',
            email='dana@example.com', postcode='RG4 4DD',
        )
        self.dana_user = User.objects.create_user('dana', password='pw')
        self.dana_client = APIClient()
        self.dana_client.force_authenticate(self.dana_user)

    def test_claim_matches_on_email_but_does_not_auto_link(self):
        response = self.dana_client.post(
            '/api/claim-requests/',
            {'claimed_name': 'Dana Doe', 'claimed_email': 'dana@example.com', 'claimed_postcode': 'RG4 4DD'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data['matched_client'], self.unclaimed.pk)

        # Matching is a hint for staff, never an authorisation.
        self.unclaimed.refresh_from_db()
        self.assertIsNone(self.unclaimed.user)
        self.assertEqual(self.dana_client.get('/api/dogs/').data['count'], 0)

    def test_claim_matches_on_surname_and_postcode_despite_the_space(self):
        """The fallback must survive postcodes written the normal way.

        Stored postcodes are typed by hand and usually carry the space, while
        the claimed one is stripped before comparison. Comparing the two
        directly meant this fallback never fired in practice.
        """
        spaced = Client.objects.create(
            uid='MOJO-011', first_name='Marco', last_name='Baldanza',
            email='someone-else@example.com', postcode='SL7 2HE',
        )
        user = User.objects.create_user('marco.baldanza', password='pw')
        client = APIClient()
        client.force_authenticate(user)

        response = client.post(
            '/api/claim-requests/',
            {
                # A different address to the one on file, so only the
                # surname + postcode route can find the record.
                'claimed_name': 'Marco Baldanza',
                'claimed_email': 'marco@example.com',
                'claimed_postcode': 'SL7 2HE',
            },
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data['matched_client'], spaced.pk)

    def test_claim_matches_when_the_claimant_omits_the_space(self):
        spaced = Client.objects.create(
            uid='MOJO-012', first_name='Erin', last_name='Ellis',
            email='on-file@example.com', postcode='RG9 9EE',
        )
        user = User.objects.create_user('erin', password='pw')
        client = APIClient()
        client.force_authenticate(user)

        response = client.post(
            '/api/claim-requests/',
            {
                'claimed_name': 'Erin Ellis',
                'claimed_email': 'erin@example.com',
                'claimed_postcode': 'rg99ee',
            },
            format='json',
        )
        self.assertEqual(response.data['matched_client'], spaced.pk)

    def test_staff_can_approve_against_a_client_they_pick_themselves(self):
        """No suggested match must not mean no way to approve.

        The auto-match is a hint; when it misses, staff name the record and
        that choice is what gets linked.
        """
        unmatchable = Client.objects.create(
            uid='MOJO-013', first_name='Fay', last_name='Fisher',
            email='fay@example.com', postcode='RG5 5FF',
        )
        user = User.objects.create_user('fay', password='pw')
        client = APIClient()
        client.force_authenticate(user)
        client.post(
            '/api/claim-requests/',
            {
                'claimed_name': 'Totally Different',
                'claimed_email': 'nothing@example.com',
                'claimed_postcode': 'ZZ1 1ZZ',
            },
            format='json',
        )
        claim = ClientClaimRequest.objects.get(user=user)
        self.assertIsNone(claim.matched_client)

        response = self.staff_client.post(
            f'/api/claim-requests/{claim.pk}/approve/',
            {'client_id': unmatchable.pk},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        unmatchable.refresh_from_db()
        self.assertEqual(unmatchable.user, user)

    def test_a_walk_up_signup_can_be_given_a_brand_new_client_record(self):
        """Someone Jess never entered still has to get through.

        There is nothing to link them to, so approving creates the record from
        what they gave and attaches their login in one step.
        """
        user = User.objects.create_user('gareth', password='pw')
        client = APIClient()
        client.force_authenticate(user)
        client.post(
            '/api/claim-requests/',
            {
                'claimed_name': 'Gareth Green',
                'claimed_email': 'gareth@example.com',
                'claimed_postcode': 'RG7 7GG',
            },
            format='json',
        )
        claim = ClientClaimRequest.objects.get(user=user)
        self.assertIsNone(claim.matched_client, 'nothing on file should match')

        response = self.staff_client.post(
            f'/api/claim-requests/{claim.pk}/approve_as_new_client/',
            {'client_uid': 'MOJO-020'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        created = Client.objects.get(uid='MOJO-020')
        self.assertEqual(created.first_name, 'Gareth')
        self.assertEqual(created.last_name, 'Green')
        self.assertEqual(created.email, 'gareth@example.com')
        self.assertEqual(created.user, user)

        claim.refresh_from_db()
        self.assertEqual(claim.status, 'APPROVED')
        self.assertEqual(claim.matched_client, created)

        # And they are through: their own record is now visible to them.
        self.assertEqual(client.get('/api/clients/').data['count'], 1)

    def test_a_double_barrelled_surname_survives(self):
        user = User.objects.create_user('hana', password='pw')
        client = APIClient()
        client.force_authenticate(user)
        client.post(
            '/api/claim-requests/',
            {
                'claimed_name': 'Hana de la Cruz',
                'claimed_email': 'hana@example.com',
                'claimed_postcode': 'RG8 8HH',
            },
            format='json',
        )
        claim = ClientClaimRequest.objects.get(user=user)
        self.staff_client.post(
            f'/api/claim-requests/{claim.pk}/approve_as_new_client/',
            {'client_uid': 'MOJO-021'},
            format='json',
        )
        created = Client.objects.get(uid='MOJO-021')
        self.assertEqual(created.first_name, 'Hana')
        self.assertEqual(created.last_name, 'de la Cruz')

    def test_creating_a_new_client_rejects_a_uid_already_in_use(self):
        user = User.objects.create_user('ivan', password='pw')
        client = APIClient()
        client.force_authenticate(user)
        client.post(
            '/api/claim-requests/',
            {
                'claimed_name': 'Ivan Ives',
                'claimed_email': 'ivan@example.com',
                'claimed_postcode': 'RG9 9II',
            },
            format='json',
        )
        claim = ClientClaimRequest.objects.get(user=user)

        response = self.staff_client.post(
            f'/api/claim-requests/{claim.pk}/approve_as_new_client/',
            {'client_uid': self.alice.uid},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        claim.refresh_from_db()
        self.assertEqual(claim.status, 'PENDING', 'a rejected UID must not approve the claim')

    def test_a_client_cannot_create_their_own_record_from_a_claim(self):
        user = User.objects.create_user('jen', password='pw')
        client = APIClient()
        client.force_authenticate(user)
        client.post(
            '/api/claim-requests/',
            {
                'claimed_name': 'Jen Jones',
                'claimed_email': 'jen@example.com',
                'claimed_postcode': 'RG1 1JJ',
            },
            format='json',
        )
        claim = ClientClaimRequest.objects.get(user=user)

        response = client.post(
            f'/api/claim-requests/{claim.pk}/approve_as_new_client/',
            {'client_uid': 'MOJO-022'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(Client.objects.filter(uid='MOJO-022').exists())

    def test_staff_approval_links_the_record(self):
        self.dana_client.post(
            '/api/claim-requests/',
            {'claimed_name': 'Dana Doe', 'claimed_email': 'dana@example.com', 'claimed_postcode': 'RG4 4DD'},
            format='json',
        )
        claim_id = self.staff_client.get('/api/claim-requests/').data['results'][0]['id']
        response = self.staff_client.post(f'/api/claim-requests/{claim_id}/approve/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        self.unclaimed.refresh_from_db()
        self.assertEqual(self.unclaimed.user, self.dana_user)

    def test_a_client_cannot_approve_their_own_claim(self):
        self.dana_client.post(
            '/api/claim-requests/',
            {'claimed_name': 'Dana Doe', 'claimed_email': 'dana@example.com', 'claimed_postcode': 'RG4 4DD'},
            format='json',
        )
        claim_id = self.dana_client.get('/api/claim-requests/').data['results'][0]['id']
        response = self.dana_client.post(f'/api/claim-requests/{claim_id}/approve/')
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_cannot_claim_a_record_already_linked_to_someone_else(self):
        claim = self.dana_client.post(
            '/api/claim-requests/',
            {'claimed_name': 'Alice Adams', 'claimed_email': 'alice@example.com', 'claimed_postcode': 'RG1 1AA'},
            format='json',
        )
        response = self.staff_client.post(
            f'/api/claim-requests/{claim.data["id"]}/approve/',
            {'client_id': self.alice.pk},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)

    def test_claimants_only_see_their_own_claims(self):
        self.dana_client.post(
            '/api/claim-requests/',
            {'claimed_name': 'Dana Doe', 'claimed_email': 'dana@example.com', 'claimed_postcode': 'RG4 4DD'},
            format='json',
        )
        self.assertEqual(self.alice_client.get('/api/claim-requests/').data['count'], 0)


class InvoiceVisibilityTests(BaseAPITestCase):
    """Invoicing starts hidden from clients and is revealed by a settings flag."""

    def setUp(self):
        super().setUp()
        self.invoice = Invoice.objects.create(client=self.alice, number='INV-001')

    def test_hidden_from_clients_by_default(self):
        settings_row = AppSettings.get()
        self.assertFalse(settings_row.invoicing_visible_to_clients)
        self.assertEqual(self.alice_client.get('/api/invoices/').data['count'], 0)

    def test_visible_once_the_flag_is_on(self):
        settings_row = AppSettings.get()
        settings_row.invoicing_visible_to_clients = True
        settings_row.save()

        response = self.alice_client.get('/api/invoices/')
        self.assertEqual(response.data['count'], 1)

    def test_client_still_only_sees_their_own_once_visible(self):
        settings_row = AppSettings.get()
        settings_row.invoicing_visible_to_clients = True
        settings_row.save()
        Invoice.objects.create(client=self.bob, number='INV-002')

        response = self.alice_client.get('/api/invoices/')
        self.assertEqual(response.data['count'], 1)
        self.assertEqual(response.data['results'][0]['number'], 'INV-001')

    def test_client_cannot_raise_an_invoice(self):
        settings_row = AppSettings.get()
        settings_row.invoicing_visible_to_clients = True
        settings_row.save()
        response = self.alice_client.post(
            '/api/invoices/', {'client': self.alice.pk, 'number': 'INV-FAKE'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_invoice_totals_add_up(self):
        response = self.staff_client.post(
            '/api/invoices/',
            {
                'client': self.alice.pk,
                'number': 'INV-100',
                'lines': [
                    {'description': 'Full groom', 'quantity': '1.00', 'unit_price': '50.00'},
                    {'description': 'Nail clip', 'quantity': '2.00', 'unit_price': '7.50'},
                ],
            },
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        invoice = Invoice.objects.get(number='INV-100')
        self.assertEqual(invoice.total, Decimal('65.00'))
        self.assertEqual(invoice.balance, Decimal('65.00'))


class DogumentsSearchTests(BaseAPITestCase):
    """The Doguments list searches dog name, client name and phone number."""

    def test_search_by_dog_name(self):
        response = self.staff_client.get('/api/dogs/?search=Biscuit')
        self.assertEqual([d['name'] for d in response.data['results']], ['Biscuit'])

    def test_search_by_client_name(self):
        response = self.staff_client.get('/api/dogs/?search=Brown')
        self.assertEqual([d['name'] for d in response.data['results']], ['Rolo'])

    def test_search_by_phone_number(self):
        response = self.staff_client.get('/api/dogs/?search=07700900001')
        self.assertEqual([d['name'] for d in response.data['results']], ['Biscuit'])

    def test_search_by_client_uid(self):
        response = self.staff_client.get('/api/dogs/?search=MOJO-002')
        self.assertEqual([d['name'] for d in response.data['results']], ['Rolo'])

    def test_list_row_carries_the_summary_fields(self):
        row = self.staff_client.get('/api/dogs/?search=Biscuit').data['results'][0]
        self.assertEqual(row['client_first_name'], 'Alice')
        self.assertEqual(row['client_uid'], 'MOJO-001')
        self.assertEqual(row['groom_minutes_effective'], 105)
        self.assertEqual(Decimal(row['price_effective']), Decimal('50.00'))
        self.assertEqual(row['schedule_weeks_effective'], 6)
        self.assertEqual(row['temperament'], Temperament.FEISTY)

    def test_inactive_dogs_are_hidden_unless_asked_for(self):
        self.bob_dog.is_active = False
        self.bob_dog.save()
        self.assertEqual(self.staff_client.get('/api/dogs/').data['count'], 1)
        self.assertEqual(self.staff_client.get('/api/dogs/?include_inactive=1').data['count'], 2)


class ProblemAreaValidationTests(BaseAPITestCase):
    def test_valid_cells_are_normalised(self):
        response = self.staff_client.post(
            '/api/problem-areas/',
            {'dog': self.alice_dog.pk, 'grid_cells': ['R2C4', 'r3c5'], 'reason': 'Matting'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data['grid_cells'], ['r2c4', 'r3c5'])

    def test_out_of_range_cells_are_rejected(self):
        response = self.staff_client.post(
            '/api/problem-areas/',
            {'dog': self.alice_dog.pk, 'grid_cells': ['r8c0'], 'reason': 'Off grid'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_malformed_cells_are_rejected(self):
        response = self.staff_client.post(
            '/api/problem-areas/',
            {'dog': self.alice_dog.pk, 'grid_cells': ['top-left'], 'reason': 'Bad ref'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_multiple_areas_per_dog_are_allowed(self):
        for cells, reason in [(['r1c1'], 'Sore ear'), (['r5c8'], 'Matted tail')]:
            response = self.staff_client.post(
                '/api/problem-areas/',
                {'dog': self.alice_dog.pk, 'grid_cells': cells, 'reason': reason},
                format='json',
            )
            self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(self.alice_dog.problem_areas.count(), 2)


class BreedInheritanceTests(BaseAPITestCase):
    def test_dog_inherits_breed_values(self):
        self.assertEqual(self.bob_dog.effective_groom_minutes, 105)
        self.assertEqual(self.bob_dog.effective_price, Decimal('50.00'))
        self.assertEqual(self.bob_dog.effective_schedule_weeks, 6)

    def test_override_wins(self):
        self.bob_dog.groom_minutes = 60
        self.assertEqual(self.bob_dog.effective_groom_minutes, 60)

    def test_dog_with_no_breed_falls_back_to_sane_defaults(self):
        mystery = Dog.objects.create(client=self.bob, name='Scruff', breed_other='Some kind of terrier')
        self.assertEqual(mystery.effective_groom_minutes, 90)
        self.assertEqual(mystery.effective_schedule_weeks, 8)
        self.assertEqual(mystery.breed_label, 'Some kind of terrier')

    def test_suggested_next_groom_uses_the_interval(self):
        start = timezone.now() - timedelta(days=14)
        Appointment.objects.create(
            dog=self.bob_dog, start_at=start, end_at=start + timedelta(hours=2),
            status=AppointmentStatus.COMPLETED,
        )
        response = self.staff_client.get(f'/api/dogs/{self.bob_dog.pk}/suggested_next_groom/')
        expected = (timezone.localtime(start).date() + timedelta(weeks=6)).isoformat()
        self.assertEqual(response.data['due_date'], expected)


class HealthTests(APITestCase):
    def test_health_needs_no_login(self):
        response = APIClient().get('/api/health/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['status'], 'ok')
