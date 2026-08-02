"""Integration tests for the API.

The bulk of these guard the two access-control rules the whole design rests on:
a client may only ever reach their own records, and Jess's private working
notes (temperament, chatty, staff notes) never reach a client. Everything else
tests behaviour the notes call out explicitly — warnings that don't block,
single-use intake links, groom timings feeding back into the diary.
"""

import re
from datetime import date, time, timedelta
from decimal import Decimal
from pathlib import Path

from django.conf import settings
from django.contrib.auth.models import User
from django.contrib.staticfiles import finders
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework import status
from rest_framework.request import Request
from rest_framework.test import APIClient, APIRequestFactory, APITestCase

from .serializers import DogSerializer

from .management.commands.seed_breeds import BREEDS
from .models import (
    AppSettings,
    Appointment,
    AppointmentChangeRequest,
    AppointmentStatus,
    Breed,
    Client,
    ClientChangeRequest,
    ClientClaimRequest,
    ClosureDay,
    Consent,
    ConsentKind,
    Dog,
    DogDocument,
    DogPhoto,
    Equipment,
    GroomPhase,
    GroomSession,
    IntakeInvite,
    IntakeSubmission,
    Invoice,
    InvoiceLine,
    OpeningHours,
    PasswordResetRequest,
    Payment,
    PasswordResetToken,
    PhaseTiming,
    ProblemArea,
    REQUIRED_CONSENTS,
    ReviewStatus,
    Service,
    ServiceType,
    Temperament,
    TemperamentGrade,
    temperament_label,
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
        self.bob_client = APIClient()
        self.bob_client.force_authenticate(self.bob_user)


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
        """A dropped field is ignored on *input*, not merely on output.

        Asserted against the serializer rather than through a PATCH, because
        StaffWriteOnlyMixin now refuses a client's PATCH outright (see
        PrivilegeEscalationTests) and this property has to keep being proven
        independently of that. The two are separate layers on purpose: if the
        viewset guard were ever relaxed, this is what would still stand between
        a crafted request and Jess's handling notes.
        """
        factory = APIRequestFactory()
        request = factory.patch('/api/dogs/')
        request.user = self.alice_user

        serializer = DogSerializer(
            self.alice_dog,
            data={'temperament': Temperament.EASY, 'general_notes': 'Likes a biscuit'},
            partial=True,
            context={'request': Request(request)},
        )
        self.assertTrue(serializer.is_valid(), serializer.errors)

        # Dropped from the field set entirely, so it never reaches the model.
        self.assertNotIn('temperament', serializer.validated_data)
        self.assertEqual(serializer.validated_data['general_notes'], 'Likes a biscuit')

        serializer.save()
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

    # ── Editing and deleting their *own* rows ──────────────────────────
    #
    # These are the cases the class was missing, and the gap is exactly why the
    # bug lived: creation was covered on both models, so the surface looked
    # tested. ClientScopedMixin deliberately puts a client's own dog and own
    # record in their queryset — that is how they read them — so get_object
    # finds the row and an unguarded PATCH/DELETE went straight through.

    def test_client_cannot_edit_their_own_dog(self):
        response = self.alice_client.patch(
            f'/api/dogs/{self.alice_dog.pk}/', {'price': '0.00'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.alice_dog.refresh_from_db()
        self.assertIsNone(self.alice_dog.price)

    def test_client_cannot_reassign_their_dog_to_another_client(self):
        response = self.alice_client.patch(
            f'/api/dogs/{self.alice_dog.pk}/', {'client': self.bob.pk}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.client_id, self.alice.pk)

    def test_client_cannot_delete_their_own_dog(self):
        # The cascade is the reason this one matters most: a dog takes its
        # appointments, photos, documents, problem areas and groom sessions
        # with it.
        response = self.alice_client.delete(f'/api/dogs/{self.alice_dog.pk}/')
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertTrue(Dog.objects.filter(pk=self.alice_dog.pk).exists())

    def test_client_cannot_edit_their_own_client_record(self):
        # Their details change through ClientChangeRequest, which exists so
        # Jess confirms them. A direct PATCH would bypass that entirely.
        response = self.alice_client.patch(
            '/api/clients/%d/' % self.alice.pk, {'phone': '07999999999'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.alice.refresh_from_db()
        self.assertEqual(self.alice.phone, '07700900001')

    def test_client_cannot_delete_their_own_client_record(self):
        response = self.alice_client.delete('/api/clients/%d/' % self.alice.pk)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertTrue(Client.objects.filter(pk=self.alice.pk).exists())

    def test_client_cannot_edit_or_delete_their_dogs_photos(self):
        photo = DogPhoto.objects.create(dog=self.alice_dog, image='dog_photos/x.jpg')
        patch = self.alice_client.patch(
            f'/api/dog-photos/{photo.pk}/', {'caption': 'mine now'}, format='json',
        )
        self.assertEqual(patch.status_code, status.HTTP_403_FORBIDDEN)
        delete = self.alice_client.delete(f'/api/dog-photos/{photo.pk}/')
        self.assertEqual(delete.status_code, status.HTTP_403_FORBIDDEN)
        self.assertTrue(DogPhoto.objects.filter(pk=photo.pk).exists())

    def test_staff_can_still_edit_and_delete_all_three(self):
        # The guard is about who, not about what: none of the above may cost
        # Jess the ability to do her job.
        photo = DogPhoto.objects.create(dog=self.alice_dog, image='dog_photos/x.jpg')

        self.assertEqual(
            self.staff_client.patch(
                f'/api/dogs/{self.alice_dog.pk}/', {'price': '60.00'}, format='json',
            ).status_code,
            status.HTTP_200_OK,
        )
        self.assertEqual(
            self.staff_client.patch(
                '/api/clients/%d/' % self.alice.pk, {'phone': '07711111111'}, format='json',
            ).status_code,
            status.HTTP_200_OK,
        )
        self.assertEqual(
            self.staff_client.delete(f'/api/dog-photos/{photo.pk}/').status_code,
            status.HTTP_204_NO_CONTENT,
        )
        self.assertEqual(
            self.staff_client.delete(f'/api/dogs/{self.alice_dog.pk}/').status_code,
            status.HTTP_204_NO_CONTENT,
        )

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
                     '/api/intake-submissions/', '/api/temperament-grades/', '/api/booking-series/']:
            self.assertEqual(
                self.alice_client.get(path).status_code, status.HTTP_403_FORBIDDEN,
                f'{path} was reachable by a client',
            )


class BookingWarningTests(BaseAPITestCase):
    """Warnings must surface, and must never block the booking."""

    def setUp(self):
        super().setUp()
        # All five grades exist from migration 0007, so these set the caps
        # rather than creating the rows.
        for temperament, cap in (
            (Temperament.FEISTY, 1),
            (Temperament.FIDGETY, 2),
            (Temperament.EASY, None),
        ):
            TemperamentGrade.objects.filter(temperament=temperament).update(max_per_day=cap)
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

    def _payload(self, **overrides):
        payload = {
            'first_name': 'Carol',
            'last_name': 'Clark',
            'email': 'newclient@example.com',
            'phone': '07700900003',
            'postcode': 'RG3 3CC',
            'emergency_contact_name': 'Dan Clark',
            'emergency_contact_phone': '07700900009',
            'signature': 'Carol Clark',
            'consents': {kind.value: True for kind in ConsentKind},
            'dogs': [{
                'name': 'Pepper',
                'breed': 'Cockapoo (small)',
                'pref_feet': 'Round',
                'colour': 'Apricot',
                'microchip_number': '956000012345678',
                'allergies': 'Chicken',
                'owner_grooming': 'Brush twice a week',
                'problem_areas': [{'grid_cells': ['r2c4', 'r2c5'], 'reason': 'Dislikes back feet touched'}],
            }],
        }
        payload.update(overrides)
        return payload

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
        self.assertEqual(dog.colour, 'Apricot')
        self.assertEqual(dog.microchip_number, '956000012345678')
        self.assertEqual(dog.allergies, 'Chicken')
        self.assertEqual(dog.owner_grooming, 'Brush twice a week')
        self.assertEqual(client.emergency_contact_name, 'Dan Clark')

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


class IntakeConsentTests(BaseAPITestCase):
    """The six disclaimers off the paper card.

    Enforced server-side rather than only in the page's JavaScript: the intake
    endpoint is public, and a signed disclaimer nobody can prove was shown is
    worth nothing.
    """

    def setUp(self):
        super().setUp()
        self.invite = IntakeInvite.objects.create(
            email='newclient@example.com',
            expires_at=timezone.now() + timedelta(days=7),
        )
        self.public = APIClient()

    def _payload(self, consents=None, signature='Carol Clark'):
        return {
            'first_name': 'Carol',
            'email': 'newclient@example.com',
            'signature': signature,
            'consents': {kind.value: True for kind in ConsentKind} if consents is None else consents,
            'dogs': [{'name': 'Pepper'}],
        }

    def _submit(self, **kwargs):
        return self.public.post(
            f'/api/intake/{self.invite.token}/', self._payload(**kwargs), format='json',
        )

    def test_a_required_disclaimer_left_unticked_is_refused(self):
        for kind in REQUIRED_CONSENTS:
            with self.subTest(kind=kind):
                consents = {k.value: True for k in ConsentKind}
                consents[kind.value] = False
                self.invite.used_at = None
                self.invite.save()
                response = self._submit(consents=consents)
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn('consents', response.data)

    def test_declining_photos_still_goes_through(self):
        """The only optional one. Blocking on it would be wrong — the paper
        card phrases it as a question, not a condition."""
        consents = {k.value: True for k in ConsentKind}
        consents[ConsentKind.PHOTOS.value] = False
        self.assertEqual(self._submit(consents=consents).status_code, status.HTTP_201_CREATED)

    def test_an_unsigned_form_is_refused(self):
        response = self._submit(signature='   ')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('signature', response.data)

    def test_approval_records_each_answer_against_the_client(self):
        consents = {k.value: True for k in ConsentKind}
        consents[ConsentKind.PHOTOS.value] = False
        self._submit(consents=consents)
        submission = IntakeSubmission.objects.get()
        self.staff_client.post(
            f'/api/intake-submissions/{submission.id}/approve/',
            {'client_uid': 'MOJO-004'}, format='json',
        )

        client = Client.objects.get(uid='MOJO-004')
        self.assertEqual(client.consents.count(), len(ConsentKind))
        self.assertFalse(client.photo_consent)
        self.assertTrue(client.consents.get(kind=ConsentKind.MATTING).agreed)

        signed = client.consents.get(kind=ConsentKind.POLICIES)
        self.assertEqual(signed.signed_name, 'Carol Clark')
        # Agreed when the form was sent, not when Jess got round to it.
        self.assertEqual(signed.signed_at, submission.created_at)
        # The wording is stored so a later rewrite can't rewrite history.
        self.assertEqual(signed.wording, ConsentKind.POLICIES.label)

    def test_never_asked_is_not_the_same_as_declined(self):
        """A client created any other way has no photo answer at all, and
        anything about to publish a photo must be able to tell that apart from
        a "no"."""
        self.assertIsNone(self.alice.photo_consent)

    def test_a_later_answer_wins(self):
        Consent.objects.create(
            client=self.alice, kind=ConsentKind.PHOTOS, agreed=True,
            signed_name='Alice Adams', signed_at=timezone.now() - timedelta(days=30),
        )
        self.assertTrue(self.alice.photo_consent)
        Consent.objects.create(
            client=self.alice, kind=ConsentKind.PHOTOS, agreed=False,
            signed_name='Alice Adams',
        )
        self.assertFalse(self.alice.photo_consent)

    def test_the_form_page_shows_every_disclaimer_and_the_policies(self):
        body = self.public.get(f'/intake/{self.invite.token}/').content.decode()
        for kind in ConsentKind:
            self.assertIn(f'data-c="{kind.value}"', body)
        self.assertIn('Animal Welfare Act 2007', body)


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
        # Asserted on the row, not the response: the match is staff-only and is
        # deliberately withheld from the claimant. See the enumeration test.
        claim = ClientClaimRequest.objects.get(pk=response.data['id'])
        self.assertEqual(claim.matched_client_id, self.unclaimed.pk)

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
        claim = ClientClaimRequest.objects.get(pk=response.data['id'])
        self.assertEqual(claim.matched_client_id, spaced.pk)

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
        claim = ClientClaimRequest.objects.get(pk=response.data['id'])
        self.assertEqual(claim.matched_client_id, spaced.pk)

    def test_a_claim_response_never_names_the_matched_client(self):
        """Registration is open, so this endpoint must not answer "who is that?".

        Anyone can make an account and POST an arbitrary email, or a surname
        and postcode. Echoing the match back would turn that into a lookup for
        whether someone is one of Jess's clients, and return their full name
        with it. PasswordResetRequestViewSet already answers identically
        whether or not the identifier matched; this is the same rule.
        """
        response = self.dana_client.post(
            '/api/claim-requests/',
            {'claimed_name': 'Dana Doe', 'claimed_email': 'dana@example.com', 'claimed_postcode': 'RG4 4DD'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertNotIn('matched_client', response.data)
        self.assertNotIn('matched_client_name', response.data)

        # Nor by reading it back afterwards.
        listed = self.dana_client.get('/api/claim-requests/')
        self.assertNotIn('matched_client_name', str(listed.data))

        # ...but staff still get the hint, which is the whole point of it.
        staff_view = self.staff_client.get('/api/claim-requests/')
        self.assertIn('Dana Doe', str(staff_view.data))

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

    def test_a_blank_uid_is_assigned_the_next_in_the_series(self):
        """Leaving the field empty must create the client, not quietly fail."""
        user = User.objects.create_user('kev', password='pw')
        client = APIClient()
        client.force_authenticate(user)
        client.post(
            '/api/claim-requests/',
            {
                'claimed_name': 'Kev King',
                'claimed_email': 'kev@example.com',
                'claimed_postcode': 'RG2 2KK',
            },
            format='json',
        )
        claim = ClientClaimRequest.objects.get(user=user)

        # setUp holds MOJO-001, MOJO-002 and MOJO-010.
        response = self.staff_client.post(
            f'/api/claim-requests/{claim.pk}/approve_as_new_client/',
            {'client_uid': ''},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(Client.objects.get(user=user).uid, 'MOJO-011')

    def test_a_uid_outside_the_series_does_not_drag_the_sequence(self):
        """A live record is numbered "1337"; it must not become the baseline."""
        self.assertEqual(Client.next_uid(), 'MOJO-011')

        Client.objects.create(uid='1337', first_name='Odd', last_name='One')
        self.assertEqual(
            Client.next_uid(), 'MOJO-011',
            'a UID outside the series must not move the sequence',
        )

    def test_next_uid_does_not_backfill_gaps(self):
        """MOJO-003 to MOJO-009 are unused, and stay that way.

        Reusing a gap would hand a new client a number that may still be
        written on old paperwork for someone else.
        """
        self.assertEqual(Client.next_uid(), 'MOJO-011')

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


class TemperamentScaleTests(BaseAPITestCase):
    """Five grades, named by Jess, keyed by codes that never move.

    She asked for five rather than three — "may up bitey not hard" — and the
    names we picked are our reading of that one line, so she can rename them in
    Settings. That is the whole reason the label lives in the database: a
    label is a word, but a *code* is what every dog points at, and moving one
    would rewrite history.
    """

    def test_all_five_grades_are_seeded_in_order(self):
        grades = list(TemperamentGrade.objects.values_list('temperament', flat=True))
        self.assertEqual(
            grades, ['EASY', 'WRIGGLY', 'FIDGETY', 'BITEY', 'FEISTY'],
            'easiest to hardest — alphabetical order reads as nonsense here',
        )

    def test_the_new_grades_have_no_invented_cap(self):
        for code in ('WRIGGLY', 'BITEY'):
            grade = TemperamentGrade.objects.get(temperament=code)
            self.assertIsNone(
                grade.max_per_day,
                'blank means no limit; interpolating between 2 and 1 would '
                'invent a rule Jess never set',
            )

    def test_every_grade_is_accepted_on_a_dog(self):
        for code in ('EASY', 'WRIGGLY', 'FIDGETY', 'BITEY', 'FEISTY'):
            response = self.staff_client.patch(
                f'/api/dogs/{self.alice_dog.pk}/', {'temperament': code}, format='json',
            )
            self.assertEqual(response.status_code, status.HTTP_200_OK, code)
            self.assertEqual(response.data['temperament'], code)

    def test_a_renamed_grade_shows_through_on_a_dog(self):
        TemperamentGrade.objects.filter(temperament=Temperament.FIDGETY).update(
            label='Wiggly little sod',
        )
        cache.delete(TemperamentGrade.CACHE_KEY)
        self.alice_dog.temperament = Temperament.FIDGETY
        self.alice_dog.save()

        response = self.staff_client.get(f'/api/dogs/{self.alice_dog.pk}/')
        self.assertEqual(
            response.data['temperament_display'], 'Wiggly little sod',
            "the app must show Jess's wording, not the frozen enum label",
        )

    def test_renaming_a_grade_invalidates_the_cached_labels(self):
        # Reading it first is the point: a stale entry is exactly what a
        # cache-invalidation bug would leave behind.
        self.assertEqual(temperament_label(Temperament.EASY), 'Easy')

        grade = TemperamentGrade.objects.get(temperament=Temperament.EASY)
        grade.label = 'Good as gold'
        grade.save()

        self.assertEqual(temperament_label(Temperament.EASY), 'Good as gold')

    def test_a_grade_cannot_be_repointed_at_another_code(self):
        grade = TemperamentGrade.objects.get(temperament=Temperament.EASY)
        response = self.staff_client.patch(
            f'/api/temperament-grades/{grade.pk}/',
            {'temperament': 'FEISTY', 'label': 'Easy'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        grade.refresh_from_db()
        self.assertEqual(
            grade.temperament, Temperament.EASY,
            'every dog stores the code; the settings screen renames, it does '
            'not repoint',
        )

    def test_a_grade_cannot_be_deleted(self):
        grade = TemperamentGrade.objects.get(temperament=Temperament.EASY)
        response = self.staff_client.delete(f'/api/temperament-grades/{grade.pk}/')
        self.assertEqual(response.status_code, status.HTTP_405_METHOD_NOT_ALLOWED)

    def test_a_blank_label_is_refused(self):
        grade = TemperamentGrade.objects.get(temperament=Temperament.EASY)
        response = self.staff_client.patch(
            f'/api/temperament-grades/{grade.pk}/', {'label': '   '}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_cap_on_a_new_grade_warns_but_still_books(self):
        TemperamentGrade.objects.filter(temperament=Temperament.BITEY).update(max_per_day=1)
        cache.delete(TemperamentGrade.CACHE_KEY)
        for dog in (self.alice_dog, self.bob_dog):
            dog.temperament = Temperament.BITEY
            dog.save()

        start = timezone.now() + timedelta(days=3)
        start = start.replace(hour=10, minute=0, second=0, microsecond=0)
        Appointment.objects.create(
            dog=self.alice_dog, start_at=start, status=AppointmentStatus.BOOKED,
        )

        response = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': self.bob_dog.pk, 'start_at': (start + timedelta(hours=4)).isoformat()},
            format='json',
        )
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertIn('temperament_limit', codes)

        # And it is still only a warning.
        booked = self.staff_client.post(
            '/api/appointments/',
            {'dog': self.bob_dog.pk, 'start_at': (start + timedelta(hours=4)).isoformat()},
            format='json',
        )
        self.assertEqual(booked.status_code, status.HTTP_201_CREATED)

    def test_the_warning_uses_jesss_wording(self):
        TemperamentGrade.objects.filter(temperament=Temperament.FEISTY).update(
            max_per_day=1, label='Proper handful',
        )
        cache.delete(TemperamentGrade.CACHE_KEY)
        for dog in (self.alice_dog, self.bob_dog):
            dog.temperament = Temperament.FEISTY
            dog.save()

        start = (timezone.now() + timedelta(days=3)).replace(
            hour=10, minute=0, second=0, microsecond=0,
        )
        Appointment.objects.create(
            dog=self.alice_dog, start_at=start, status=AppointmentStatus.BOOKED,
        )

        response = self.staff_client.post(
            '/api/appointments/check/',
            {'dog': self.bob_dog.pk, 'start_at': (start + timedelta(hours=4)).isoformat()},
            format='json',
        )
        warning = next(w for w in response.data['warnings'] if w['code'] == 'temperament_limit')
        self.assertIn('proper handful', warning['message'])

    def test_a_client_still_cannot_see_a_temperament(self):
        # The scale getting wider must not widen who can see it.
        response = self.alice_client.get(f'/api/dogs/{self.alice_dog.pk}/')
        self.assertNotIn('temperament', response.data)
        self.assertNotIn('temperament_display', response.data)

    def test_a_client_cannot_read_the_grades(self):
        self.assertEqual(
            self.alice_client.get('/api/temperament-grades/').status_code,
            status.HTTP_403_FORBIDDEN,
        )

    def test_the_old_route_and_field_still_work(self):
        """The build in Jess's hands calls `/temperament-limits/` and reads
        `temperament_display`.

        A push to main deploys the server; the app only reaches her through
        TestFlight. Renaming the route in a backend deploy would have broken
        her Settings screen until the next release went out — days at best,
        and a review queue at worst.
        """
        response = self.staff_client.get('/api/temperament-limits/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['count'], 5)

        row = response.data['results'][0]
        self.assertEqual(row['temperament_display'], row['label'])

        # And the one write that screen makes still lands.
        patched = self.staff_client.patch(
            f'/api/temperament-limits/{row["id"]}/', {'max_per_day': 4}, format='json',
        )
        self.assertEqual(patched.status_code, status.HTTP_200_OK)
        self.assertEqual(
            TemperamentGrade.objects.get(pk=row['id']).max_per_day, 4,
        )


class NeuterUnknownTests(BaseAPITestCase):
    """"Nobody asked" is not "intact".

    ``is_neutered`` was ``BooleanField(default=False)``, so a dog whose owner
    was never asked was stored identically to one confirmed entire — and the
    tag on the dog profile would have called every one of them "Intact". Same
    rule as ``photo_consent`` and ``bathed_well_behaved``: null is not false,
    on both sides of the wire.
    """

    def test_a_dog_created_without_an_answer_is_unknown(self):
        response = self.staff_client.post(
            '/api/dogs/',
            {'client': self.alice.pk, 'name': 'Pip'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertIsNone(response.data['is_neutered'])

    def test_null_round_trips_and_does_not_come_back_as_false(self):
        self.staff_client.patch(
            f'/api/dogs/{self.alice_dog.pk}/', {'is_neutered': True}, format='json',
        )
        response = self.staff_client.patch(
            f'/api/dogs/{self.alice_dog.pk}/', {'is_neutered': None}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.data['is_neutered'])

    def test_all_three_answers_are_distinguishable(self):
        for sent in (True, False, None):
            response = self.staff_client.patch(
                f'/api/dogs/{self.alice_dog.pk}/', {'is_neutered': sent}, format='json',
            )
            self.assertIs(response.data['is_neutered'], sent)

    def test_an_intake_form_that_skips_the_question_approves_to_unknown(self):
        invite = IntakeInvite.objects.create(email='new@example.com', created_by=self.staff)
        submission = IntakeSubmission.objects.create(
            invite=invite,
            first_name='Nina', last_name='Novak', email='new@example.com',
            dogs=[{'name': 'Sooty'}],
            consents={kind: True for kind in REQUIRED_CONSENTS},
        )

        response = self.staff_client.post(
            f'/api/intake-submissions/{submission.pk}/approve/',
            {'client_uid': 'MOJO-901'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        dog = Dog.objects.get(name='Sooty')
        self.assertIsNone(
            dog.is_neutered,
            'the old bool() coercion turned "did not say" straight back into '
            '"intact" on the way in',
        )

    def test_an_intake_form_answering_no_approves_to_no(self):
        invite = IntakeInvite.objects.create(email='new2@example.com', created_by=self.staff)
        submission = IntakeSubmission.objects.create(
            invite=invite,
            first_name='Omar', last_name='Osei', email='new2@example.com',
            dogs=[{'name': 'Rex', 'is_neutered': False}],
            consents={kind: True for kind in REQUIRED_CONSENTS},
        )

        self.staff_client.post(
            f'/api/intake-submissions/{submission.pk}/approve/',
            {'client_uid': 'MOJO-902'},
            format='json',
        )
        self.assertIs(Dog.objects.get(name='Rex').is_neutered, False)

    def test_an_intake_form_answering_yes_approves_to_yes(self):
        invite = IntakeInvite.objects.create(email='new3@example.com', created_by=self.staff)
        submission = IntakeSubmission.objects.create(
            invite=invite,
            first_name='Pat', last_name='Price', email='new3@example.com',
            dogs=[{'name': 'Bramble', 'is_neutered': True}],
            consents={kind: True for kind in REQUIRED_CONSENTS},
        )

        self.staff_client.post(
            f'/api/intake-submissions/{submission.pk}/approve/',
            {'client_uid': 'MOJO-903'},
            format='json',
        )
        self.assertIs(Dog.objects.get(name='Bramble').is_neutered, True)


class AppointmentChangeRequestTests(BaseAPITestCase):
    """A client asking to cancel or move their own booking.

    Bookings stay read-only to clients — this is the way to *ask*, not a way
    round AppointmentViewSet's guards. Several of these check exactly that.
    """

    def setUp(self):
        super().setUp()
        self.start = timezone.now() + timedelta(days=7)
        self.appointment = Appointment.objects.create(
            dog=self.alice_dog, start_at=self.start, end_at=self.start + timedelta(hours=2),
        )

    def _request(self, client, body):
        return client.post('/api/appointment-change-requests/', body, format='json')

    def test_a_client_can_ask_to_cancel_their_own_booking(self):
        response = self._request(self.alice_client, {
            'appointment': self.appointment.pk, 'kind': 'CANCEL', 'note': 'Away that week',
        })
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data['status'], ReviewStatus.PENDING)

        # Asking is not doing. The booking stands until Jess approves.
        self.appointment.refresh_from_db()
        self.assertEqual(self.appointment.status, AppointmentStatus.BOOKED)

    def test_approving_a_cancellation_cancels_the_booking(self):
        change = AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user, kind='CANCEL',
        )
        response = self.staff_client.post(
            f'/api/appointment-change-requests/{change.pk}/approve/', {}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.appointment.refresh_from_db()
        self.assertEqual(self.appointment.status, AppointmentStatus.CANCELLED)

    def test_approving_a_move_keeps_the_length(self):
        """The duration was resolved from the services when the booking was
        made. Recomputing it here would silently re-price a slot Jess may have
        adjusted by hand."""
        wanted = self.start + timedelta(days=3)
        change = AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user,
            kind='RESCHEDULE', preferred_start_at=wanted,
        )
        self.staff_client.post(
            f'/api/appointment-change-requests/{change.pk}/approve/', {}, format='json',
        )
        self.appointment.refresh_from_db()
        self.assertEqual(self.appointment.start_at, wanted)
        self.assertEqual(self.appointment.end_at - self.appointment.start_at, timedelta(hours=2))

    def test_jess_can_approve_a_move_to_a_different_time(self):
        """The common case: the client picks a time that clashes and she puts
        them in the next real gap."""
        wanted = self.start + timedelta(days=3)
        hers = self.start + timedelta(days=4)
        change = AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user,
            kind='RESCHEDULE', preferred_start_at=wanted,
        )
        response = self.staff_client.post(
            f'/api/appointment-change-requests/{change.pk}/approve/',
            {'start_at': hers.isoformat()}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.appointment.refresh_from_db()
        self.assertEqual(self.appointment.start_at, hers)

    def test_a_clashing_move_warns_and_still_goes_through(self):
        """Warnings never block — the rule the whole diary runs on."""
        clash_start = self.start + timedelta(days=3)
        Appointment.objects.create(
            dog=self.bob_dog, start_at=clash_start, end_at=clash_start + timedelta(hours=2),
        )
        change = AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user,
            kind='RESCHEDULE', preferred_start_at=clash_start,
        )
        response = self.staff_client.post(
            f'/api/appointment-change-requests/{change.pk}/approve/', {}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data['warnings'], 'an overlapping move should warn')
        self.appointment.refresh_from_db()
        self.assertEqual(self.appointment.start_at, clash_start)

    def test_rejecting_leaves_the_booking_alone(self):
        change = AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user, kind='CANCEL',
        )
        self.staff_client.post(
            f'/api/appointment-change-requests/{change.pk}/reject/', {}, format='json',
        )
        self.appointment.refresh_from_db()
        self.assertEqual(self.appointment.status, AppointmentStatus.BOOKED)

    def test_a_client_cannot_ask_about_someone_elses_booking(self):
        response = self._request(self.bob_client, {
            'appointment': self.appointment.pk, 'kind': 'CANCEL',
        })
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_client_cannot_approve_their_own_request(self):
        change = AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user, kind='CANCEL',
        )
        response = self.alice_client.post(
            f'/api/appointment-change-requests/{change.pk}/approve/', {}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.appointment.refresh_from_db()
        self.assertEqual(self.appointment.status, AppointmentStatus.BOOKED)

    def test_a_client_only_sees_their_own_requests(self):
        AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user, kind='CANCEL',
        )
        self.assertEqual(self.alice_client.get('/api/appointment-change-requests/').data['count'], 1)
        self.assertEqual(self.bob_client.get('/api/appointment-change-requests/').data['count'], 0)

    def test_a_reschedule_must_say_when(self):
        response = self._request(self.alice_client, {
            'appointment': self.appointment.pk, 'kind': 'RESCHEDULE',
        })
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('preferred_start_at', response.data)

    def test_a_move_into_the_past_is_a_mistake_not_a_preference(self):
        response = self._request(self.alice_client, {
            'appointment': self.appointment.pk, 'kind': 'RESCHEDULE',
            'preferred_start_at': (timezone.now() - timedelta(days=2)).isoformat(),
        })
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_cannot_ask_about_a_booking_that_has_already_started(self):
        past = timezone.now() - timedelta(hours=1)
        started = Appointment.objects.create(
            dog=self.alice_dog, start_at=past, end_at=past + timedelta(hours=2),
        )
        response = self._request(self.alice_client, {
            'appointment': started.pk, 'kind': 'CANCEL',
        })
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_request_cannot_be_dealt_with_twice(self):
        change = AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user, kind='CANCEL',
        )
        url = f'/api/appointment-change-requests/{change.pk}/approve/'
        self.assertEqual(self.staff_client.post(url, {}, format='json').status_code,
                         status.HTTP_200_OK)
        self.assertEqual(self.staff_client.post(url, {}, format='json').status_code,
                         status.HTTP_409_CONFLICT)

    def test_it_shows_up_in_what_is_waiting_for_jess(self):
        AppointmentChangeRequest.objects.create(
            appointment=self.appointment, requested_by=self.alice_user, kind='CANCEL',
        )
        pending = self.staff_client.get('/api/pending/')
        self.assertEqual(pending.data['appointment_change_requests'], 1)
        self.assertGreaterEqual(pending.data['total'], 1)


class DogsDueTests(BaseAPITestCase):
    """Who needs booking in.

    The whole value of this list is what it *leaves out* — a dog already in the
    diary is not a dog to phone about. Most of these guard that.
    """

    def _complete_groom(self, dog, weeks_ago):
        start = timezone.now() - timedelta(weeks=weeks_ago)
        return Appointment.objects.create(
            dog=dog, start_at=start, end_at=start + timedelta(hours=2),
            status=AppointmentStatus.COMPLETED,
        )

    def _names(self, response):
        return [row['dog_name'] for row in response.data['results']]

    def test_an_overdue_dog_is_listed_with_how_late_it_is(self):
        # Biscuit's breed interval is 6 weeks; last groom was 10 weeks ago.
        self._complete_groom(self.alice_dog, weeks_ago=10)
        response = self.staff_client.get('/api/dogs/due/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        row = next(r for r in response.data['results'] if r['dog_name'] == self.alice_dog.name)
        self.assertEqual(row['days_overdue'], 28)  # 10 weeks - 6 weeks
        self.assertEqual(row['schedule_weeks'], 6)
        self.assertEqual(row['client_name'], self.alice.full_name)
        # The phone number is the point of the screen — it is a call list.
        self.assertEqual(row['client_phone'], self.alice.phone)

    def test_a_dog_already_booked_in_is_left_out(self):
        """The property that makes this a to-do list rather than a report."""
        self._complete_groom(self.alice_dog, weeks_ago=10)
        soon = timezone.now() + timedelta(days=3)
        Appointment.objects.create(
            dog=self.alice_dog, start_at=soon, end_at=soon + timedelta(hours=2),
        )
        self.assertNotIn(self.alice_dog.name, self._names(self.staff_client.get('/api/dogs/due/')))

        # ...but still reachable when the question really is "who is due".
        with_booked = self.staff_client.get('/api/dogs/due/?include_booked=1')
        self.assertIn(self.alice_dog.name, self._names(with_booked))

    def test_a_cancelled_booking_does_not_count_as_booked_in(self):
        """Otherwise a cancellation quietly removes the dog from the call list —
        which is the exact moment it most needs to be on it."""
        self._complete_groom(self.alice_dog, weeks_ago=10)
        soon = timezone.now() + timedelta(days=3)
        Appointment.objects.create(
            dog=self.alice_dog, start_at=soon, end_at=soon + timedelta(hours=2),
            status=AppointmentStatus.CANCELLED,
        )
        self.assertIn(self.alice_dog.name, self._names(self.staff_client.get('/api/dogs/due/')))

    def test_a_dog_groomed_last_week_is_not_due(self):
        self._complete_groom(self.alice_dog, weeks_ago=1)
        self.assertNotIn(self.alice_dog.name, self._names(self.staff_client.get('/api/dogs/due/')))

    def test_within_days_looks_ahead(self):
        """Due in 10 days: absent from the default fortnight's overdue view only
        once the window is tightened below it."""
        self._complete_groom(self.alice_dog, weeks_ago=6)  # due in ~0 days
        self._complete_groom(self.bob_dog, weeks_ago=5)    # 6-week interval, due in ~7 days

        default = self._names(self.staff_client.get('/api/dogs/due/'))
        self.assertIn(self.bob_dog.name, default)

        tight = self._names(self.staff_client.get('/api/dogs/due/?within_days=0'))
        self.assertNotIn(self.bob_dog.name, tight)
        self.assertIn(self.alice_dog.name, tight)

    def test_a_never_groomed_dog_is_flagged_not_guessed(self):
        """Its due date is unknown, not far away. None on both, so the UI can
        say so rather than rendering a date nobody worked out."""
        response = self.staff_client.get('/api/dogs/due/')
        row = next(r for r in response.data['results'] if r['dog_name'] == self.alice_dog.name)
        self.assertIsNone(row['due_date'])
        self.assertIsNone(row['days_overdue'])
        self.assertIsNone(row['last_groom_date'])
        self.assertEqual(row['basis'], 'no completed grooms yet')

    def test_most_overdue_first_and_never_groomed_last(self):
        self._complete_groom(self.alice_dog, weeks_ago=20)  # very overdue
        self._complete_groom(self.bob_dog, weeks_ago=8)     # mildly overdue
        never = Dog.objects.create(client=self.alice, name='Newbie', breed=self.breed)

        names = self._names(self.staff_client.get('/api/dogs/due/'))
        self.assertEqual(names[0], self.alice_dog.name)
        self.assertEqual(names[1], self.bob_dog.name)
        self.assertEqual(names[-1], never.name)

    def test_an_inactive_dog_is_not_chased(self):
        self._complete_groom(self.alice_dog, weeks_ago=20)
        self.alice_dog.is_active = False
        self.alice_dog.save(update_fields=['is_active'])
        self.assertNotIn(self.alice_dog.name, self._names(self.staff_client.get('/api/dogs/due/')))

    def test_overdue_count_counts_only_the_late_ones(self):
        self._complete_groom(self.alice_dog, weeks_ago=10)  # overdue
        self._complete_groom(self.bob_dog, weeks_ago=5)     # due soon, not late
        response = self.staff_client.get('/api/dogs/due/')
        self.assertEqual(response.data['overdue_count'], 1)
        self.assertGreaterEqual(response.data['count'], 2)

    def test_a_client_cannot_read_the_whole_books_worklist(self):
        self.assertEqual(
            self.alice_client.get('/api/dogs/due/').status_code, status.HTTP_403_FORBIDDEN,
        )


class NextAvailableTests(BaseAPITestCase):
    """"Next available appointment" — Jess's words.

    Her opening hours, minus closures, minus what is booked, minus a gap
    either side. That gap is `booking_slot_buffer_minutes`, which had existed
    since the first version and was read by nothing at all; this is what
    finally uses it, and Settings is where she sets it.
    """

    def setUp(self):
        super().setUp()
        for weekday in range(5):
            OpeningHours.objects.create(
                weekday=weekday, open_time=time(9, 0), close_time=time(17, 0),
            )
        OpeningHours.objects.create(weekday=5, is_closed=True)
        OpeningHours.objects.create(weekday=6, is_closed=True)
        # Fixed length, so the arithmetic in these tests is about the walk and
        # not about the breed grid.
        self.alice_dog.groom_minutes = 60
        self.alice_dog.save()
        self.monday = self._next_weekday(0)

    @staticmethod
    def _next_weekday(weekday):
        day = timezone.localdate() + timedelta(days=1)
        while day.weekday() != weekday:
            day += timedelta(days=1)
        return day

    def _ask(self, **params):
        query = '&'.join(f'{key}={value}' for key, value in params.items())
        return self.staff_client.get(
            f'/api/appointments/next_available/?dog={self.alice_dog.pk}&{query}'
        )

    def test_the_first_slot_is_when_she_opens(self):
        response = self._ask(**{'from': self.monday.isoformat()})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        first = response.data['slots'][0]
        self.assertEqual(first['date'], self.monday.isoformat())
        self.assertEqual(timezone.localtime(first['start_at']).hour, 9)

    def test_a_closed_weekday_is_skipped(self):
        saturday = self._next_weekday(5)
        response = self._ask(**{'from': saturday.isoformat(), 'count': 1})
        self.assertNotEqual(response.data['slots'][0]['date'], saturday.isoformat())

    def test_a_closure_day_is_skipped(self):
        ClosureDay.objects.create(date=self.monday, reason='Bank holiday')
        response = self._ask(**{'from': self.monday.isoformat(), 'count': 1})
        self.assertNotEqual(response.data['slots'][0]['date'], self.monday.isoformat())

    def test_a_booking_blocks_its_own_slot(self):
        start = timezone.make_aware(
            timezone.datetime.combine(self.monday, time(9, 0)),
            timezone.get_current_timezone(),
        )
        Appointment.objects.create(
            dog=self.alice_dog, start_at=start, status=AppointmentStatus.BOOKED,
        )
        response = self._ask(**{'from': self.monday.isoformat(), 'count': 1})
        first = response.data['slots'][0]
        self.assertGreaterEqual(timezone.localtime(first['start_at']).hour, 10)

    def test_the_buffer_is_applied_after_a_booking(self):
        settings_row = AppSettings.get()
        settings_row.booking_slot_buffer_minutes = 30
        settings_row.save()

        start = timezone.make_aware(
            timezone.datetime.combine(self.monday, time(9, 0)),
            timezone.get_current_timezone(),
        )
        Appointment.objects.create(
            dog=self.alice_dog, start_at=start, status=AppointmentStatus.BOOKED,
        )
        response = self._ask(**{'from': self.monday.isoformat(), 'count': 1})
        first = timezone.localtime(response.data['slots'][0]['start_at'])
        self.assertEqual(
            (first.hour, first.minute), (10, 30),
            'the booking ends at 10:00, plus a 30-minute gap',
        )
        self.assertEqual(response.data['buffer_minutes'], 30)

    def test_slots_land_on_the_quarter_hour(self):
        response = self._ask(**{'from': self.monday.isoformat(), 'count': 5})
        for slot in response.data['slots']:
            self.assertEqual(timezone.localtime(slot['start_at']).minute % 15, 0)

    def test_it_says_so_when_no_hours_are_set(self):
        OpeningHours.objects.all().delete()
        response = self._ask(**{'from': self.monday.isoformat()})
        self.assertEqual(
            response.data['reason'], 'no_opening_hours',
            'an empty list here would read as "fully booked" when the real '
            'answer is "set your hours up"',
        )
        self.assertEqual(response.data['slots'], [])

    def test_it_reports_running_out_of_horizon(self):
        response = self._ask(
            **{'from': self.monday.isoformat(), 'count': 10, 'horizon_days': 1},
        )
        self.assertTrue(response.data['exhausted'])

    def test_a_client_cannot_ask(self):
        response = self.alice_client.get(
            f'/api/appointments/next_available/?dog={self.alice_dog.pk}'
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_it_needs_a_dog(self):
        response = self.staff_client.get('/api/appointments/next_available/')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class ClientChangeRequestTests(BaseAPITestCase):
    """A client asking to correct their details is a request, not an edit.

    And ``changes`` is an arbitrary-field-write primitive unless it is fenced:
    approval applies it with ``setattr``, so an unwhitelisted key writes
    straight onto the client record — including Jess's private notes, the UID
    her paper filing runs on, and the FK to the login.
    """

    def _request(self, changes, client=None):
        return (client or self.alice_client).post(
            '/api/client-change-requests/', {'changes': changes}, format='json',
        )

    def test_a_request_lands_pending_and_changes_nothing_yet(self):
        response = self._request({'phone': '07700 900123'})
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data['status'], ReviewStatus.PENDING)

        self.alice.refresh_from_db()
        self.assertNotEqual(self.alice.phone, '07700 900123')

    def test_the_target_client_comes_from_the_session_not_the_body(self):
        response = self.alice_client.post(
            '/api/client-change-requests/',
            {'client': self.bob.pk, 'changes': {'phone': '07700 900999'}},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            ClientChangeRequest.objects.get(pk=response.data['id']).client_id,
            self.alice.pk,
            'otherwise any signed-in user could lodge a request against any '
            'client and put their data in front of Jess',
        )

    def test_a_staff_only_field_is_refused_outright(self):
        for field in ('notes', 'chatty', 'leaflet_received'):
            response = self._request({field: 'anything'})
            self.assertEqual(
                response.status_code, status.HTTP_400_BAD_REQUEST, field,
            )
            self.assertFalse(ClientChangeRequest.objects.exists())

    def test_the_uid_and_the_login_are_refused(self):
        for field, value in (('uid', 'MOJO-001'), ('user', 3), ('id', 99)):
            response = self._request({field: value})
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST, field)

    def test_an_empty_request_is_refused(self):
        self.assertEqual(self._request({}).status_code, status.HTTP_400_BAD_REQUEST)

    def test_approval_applies_only_whitelisted_keys(self):
        change = ClientChangeRequest.objects.create(
            client=self.alice,
            requested_by=self.alice_user,
            # Straight onto the model, bypassing the serializer — this is what
            # a request written before the whitelist shrank would look like.
            changes={'phone': '07700 900123', 'notes': 'sneaky'},
        )
        response = self.staff_client.post(
            f'/api/client-change-requests/{change.pk}/approve/', {}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        self.alice.refresh_from_db()
        self.assertEqual(self.alice.phone, '07700 900123')
        self.assertNotEqual(
            self.alice.notes, 'sneaky',
            'the model re-checks the whitelist on the way out, not just the '
            'serializer on the way in',
        )

    def test_rejection_leaves_the_record_alone(self):
        before = self.alice.phone
        change = ClientChangeRequest.objects.create(
            client=self.alice, requested_by=self.alice_user,
            changes={'phone': '07700 900123'},
        )
        self.staff_client.post(f'/api/client-change-requests/{change.pk}/reject/')

        self.alice.refresh_from_db()
        self.assertEqual(self.alice.phone, before)

    def test_a_client_sees_only_their_own_requests(self):
        self._request({'phone': '07700 900001'})
        ClientChangeRequest.objects.create(
            client=self.bob, requested_by=self.bob_user, changes={'phone': '1'},
        )
        response = self.alice_client.get('/api/client-change-requests/')
        self.assertEqual(response.data['count'], 1)

    def test_a_client_cannot_approve_their_own(self):
        change = ClientChangeRequest.objects.create(
            client=self.alice, requested_by=self.alice_user,
            changes={'phone': '07700 900123'},
        )
        response = self.alice_client.post(
            f'/api/client-change-requests/{change.pk}/approve/', {}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.alice.refresh_from_db()
        self.assertNotEqual(self.alice.phone, '07700 900123')

    def test_approving_twice_is_refused(self):
        change = ClientChangeRequest.objects.create(
            client=self.alice, requested_by=self.alice_user,
            changes={'phone': '07700 900123'},
        )
        self.staff_client.post(f'/api/client-change-requests/{change.pk}/approve/')
        again = self.staff_client.post(f'/api/client-change-requests/{change.pk}/approve/')
        self.assertEqual(again.status_code, status.HTTP_409_CONFLICT)


class PendingSummaryTests(BaseAPITestCase):
    """Jess has no notifications at all — this count is the only thing that
    tells her something is waiting.

    Worth being plain with her about the limit: it only shows when she opens
    the app. Push needs device tokens, FCM and APNs credentials, and either a
    synchronous send that makes a client's booking request depend on Google's
    uptime, or Redis and a worker container on a host already running eleven
    projects in under 4 GB. Email is closed too — there is no SMTP on the box.
    """

    def test_it_counts_each_kind_of_thing_waiting(self):
        Appointment.objects.create(
            dog=self.alice_dog,
            start_at=timezone.now() + timedelta(days=1),
            status=AppointmentStatus.REQUESTED,
        )
        ClientChangeRequest.objects.create(
            client=self.alice, requested_by=self.alice_user, changes={'phone': '1'},
        )

        response = self.staff_client.get('/api/pending/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['appointment_requests'], 1)
        self.assertEqual(response.data['change_requests'], 1)
        self.assertEqual(response.data['total'], 2)

    def test_a_booked_appointment_is_not_waiting_for_anything(self):
        Appointment.objects.create(
            dog=self.alice_dog,
            start_at=timezone.now() + timedelta(days=1),
            status=AppointmentStatus.BOOKED,
        )
        self.assertEqual(self.staff_client.get('/api/pending/').data['total'], 0)

    def test_dealing_with_something_decrements_it(self):
        change = ClientChangeRequest.objects.create(
            client=self.alice, requested_by=self.alice_user, changes={'phone': '1'},
        )
        self.assertEqual(self.staff_client.get('/api/pending/').data['total'], 1)

        self.staff_client.post(f'/api/client-change-requests/{change.pk}/reject/')
        self.assertEqual(self.staff_client.get('/api/pending/').data['total'], 0)

    def test_a_client_cannot_see_the_queue(self):
        self.assertEqual(
            self.alice_client.get('/api/pending/').status_code,
            status.HTTP_403_FORBIDDEN,
        )

    def test_ordinary_staff_are_not_told_who_is_locked_out(self):
        # `PasswordResetRequestViewSet` is IsSuperUser, so a count here would
        # leak exactly what the list endpoint refuses them. The base fixture's
        # staff login is a superuser, hence a second one.
        PasswordResetRequest.objects.create(identifier='someone@example.com')
        helper = User.objects.create_user('helper', password='pw', is_staff=True)
        helper_client = APIClient()
        helper_client.force_authenticate(helper)

        response = helper_client.get('/api/pending/')
        self.assertNotIn('password_reset_requests', response.data)
        self.assertEqual(response.data['total'], 0)

    def test_a_superuser_is(self):
        PasswordResetRequest.objects.create(identifier='someone@example.com')

        response = self.staff_client.get('/api/pending/')
        self.assertEqual(response.data['password_reset_requests'], 1)
        self.assertEqual(response.data['total'], 1)


class DogDocumentTests(BaseAPITestCase):
    """A scanned intake form is the client's name, address and signature.

    `/media/` is served by Caddy with `file_server` and no authentication at
    all, so these cannot be media URLs. They live outside `MEDIA_ROOT` and are
    only reachable through a gated view that goes down the same scoped
    queryset as everything else.
    """

    #: A one-pixel PNG, and the smallest thing that survives a real header check.
    PNG = (
        b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01'
        b'\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01'
        b'\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82'
    )
    PDF = b'%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n'

    def _upload(self, content=None, name='form.pdf', **extra):
        upload = SimpleUploadedFile(
            name, content if content is not None else self.PDF,
            content_type='application/pdf',
        )
        return self.staff_client.post(
            '/api/dog-documents/',
            {
                'dog': self.alice_dog.pk,
                'file': upload,
                'title': 'Signed intake form',
                'kind': 'INTAKE_FORM',
                **extra,
            },
            format='multipart',
        )

    def test_staff_can_file_a_document(self):
        response = self._upload()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data['original_filename'], 'form.pdf')
        self.assertGreater(response.data['size_bytes'], 0)

    def test_the_serializer_never_emits_a_media_path(self):
        response = self._upload()
        self.assertNotIn('file', response.data)
        self.assertIn('/api/dog-documents/', response.data['download_url'])
        self.assertNotIn('/media/', str(response.data))

    def test_the_stored_path_does_not_contain_the_uploaded_filename(self):
        self._upload(name='alice-adams-intake.pdf')
        document = DogDocument.objects.get()
        self.assertNotIn('alice-adams', document.file.name)
        self.assertTrue(document.file.name.startswith('dog_documents/'))

    def test_a_client_can_download_their_own_dogs_document(self):
        self._upload()
        document = DogDocument.objects.get()
        response = self.alice_client.get(f'/api/dog-documents/{document.pk}/download/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response['X-Content-Type-Options'], 'nosniff')

    def test_another_client_gets_nothing(self):
        self._upload()
        document = DogDocument.objects.get()
        self.assertEqual(
            self.bob_client.get(f'/api/dog-documents/{document.pk}/download/').status_code,
            status.HTTP_404_NOT_FOUND,
            'the queryset layer, not just the field layer',
        )

    def test_the_default_is_visible_even_on_a_multipart_upload(self):
        # DRF turns a *missing* boolean into False for form data, which made
        # every uploaded document invisible to the client. See
        # AbsentMeansDefaultBooleanField.
        self._upload()
        self.assertTrue(DogDocument.objects.get().visible_to_client)

    def test_a_private_document_is_invisible_to_the_client(self):
        self._upload(visible_to_client=False)
        document = DogDocument.objects.get()

        self.assertEqual(self.alice_client.get('/api/dog-documents/').data['count'], 0)
        self.assertEqual(
            self.alice_client.get(f'/api/dog-documents/{document.pk}/download/').status_code,
            status.HTTP_404_NOT_FOUND,
            'filtered in the queryset — hiding a field is not hiding a row',
        )
        self.assertEqual(self.staff_client.get('/api/dog-documents/').data['count'], 1)

    def test_a_client_cannot_upload(self):
        upload = SimpleUploadedFile('sneaky.pdf', self.PDF, content_type='application/pdf')
        response = self.alice_client.post(
            '/api/dog-documents/',
            {'dog': self.alice_dog.pk, 'file': upload, 'title': 'Mine'},
            format='multipart',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_an_executable_renamed_as_a_pdf_is_rejected(self):
        response = self._upload(content=b'MZ\x90\x00\x03\x00\x00\x00' + b'\x00' * 40)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(DogDocument.objects.exists())

    def test_an_svg_is_rejected(self):
        # Scriptable, and a browser rendering it inline off the download view
        # would be stored XSS on the API's own origin.
        response = self._upload(
            content=b'<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>',
            name='form.svg',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_an_svg_renamed_as_a_png_is_rejected_too(self):
        response = self._upload(
            content=b'<svg xmlns="http://www.w3.org/2000/svg"></svg>', name='form.png',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_real_photo_is_accepted(self):
        response = self._upload(content=self.PNG, name='form.png')
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_an_unlisted_extension_is_rejected(self):
        response = self._upload(content=self.PDF, name='form.exe')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_an_oversized_file_is_rejected(self):
        big = self.PDF + b'\x00' * (settings.MAX_DOCUMENT_BYTES + 1)
        response = self._upload(content=big)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class ServiceCatalogueTests(BaseAPITestCase):
    """A nail trim must not inherit a full groom's three hours and £80.

    The catalogue drives how long a booking runs and what it costs. The coarse
    ``ServiceType`` still decides which of Jess's two record cards she fills in
    afterwards and whether the time writes back to the dog — those are
    different questions and collapsing them is how a Tidy Up ends up as a
    dog's default groom time.
    """

    def setUp(self):
        super().setUp()
        # Built here rather than seeded: `seed_breeds` also inserts 224
        # breeds, which is a lot of rows to write for three services. The seed
        # itself is covered by ServiceSeedTests.
        self.full_groom = Service.objects.create(
            code='full_groom', name='Full Groom',
            category=ServiceType.GROOM, takes_dog_defaults=True, sort_order=10,
        )
        self.nail_clipping = Service.objects.create(
            code='nail_clipping', name='Nail Clipping',
            category=ServiceType.NAILS_FLEAS_TICKS, sort_order=120,
        )
        self.tidy_up = Service.objects.create(
            code='tidy_up', name='Tidy Up', category=ServiceType.GROOM, sort_order=60,
        )
        self.start = (timezone.now() + timedelta(days=2)).replace(
            hour=10, minute=0, second=0, microsecond=0,
        )

    def _book(self, services=None, **extra):
        body = {'dog': self.alice_dog.pk, 'start_at': self.start.isoformat(), **extra}
        if services is not None:
            body['services'] = [service.pk for service in services]
        response = self.staff_client.post('/api/appointments/', body, format='json')
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return Appointment.objects.get(pk=response.data['id'])

    def test_no_services_behaves_exactly_as_before(self):
        """The compatibility guarantee this whole design rests on."""
        appointment = self._book()
        self.assertEqual(
            appointment.duration_minutes, self.alice_dog.effective_groom_minutes,
        )
        self.assertEqual(appointment.price_quoted, self.alice_dog.effective_price)

    def test_a_nail_trim_does_not_inherit_the_groom_slot(self):
        self.nail_clipping.default_minutes = 20
        self.nail_clipping.default_price = Decimal('8.00')
        self.nail_clipping.save()

        appointment = self._book([self.nail_clipping])
        self.assertEqual(appointment.duration_minutes, 20)
        self.assertEqual(appointment.price_quoted, Decimal('8.00'))

    def test_a_full_groom_takes_the_dogs_own_figures(self):
        appointment = self._book([self.full_groom])
        self.assertEqual(
            appointment.duration_minutes, self.alice_dog.effective_groom_minutes,
        )
        self.assertEqual(appointment.price_quoted, self.alice_dog.effective_price)

    def test_two_services_add_up(self):
        self.nail_clipping.default_minutes = 20
        self.nail_clipping.default_price = Decimal('8.00')
        self.nail_clipping.save()
        self.tidy_up.default_minutes = 25
        self.tidy_up.default_price = Decimal('15.00')
        self.tidy_up.save()

        appointment = self._book([self.nail_clipping, self.tidy_up])
        self.assertEqual(appointment.duration_minutes, 45)
        self.assertEqual(appointment.price_quoted, Decimal('23.00'))

    def test_an_unpriced_service_leaves_the_quote_blank_and_still_books(self):
        self.tidy_up.default_minutes = 25
        self.tidy_up.save()

        appointment = self._book([self.tidy_up])
        self.assertEqual(appointment.duration_minutes, 25)
        self.assertIsNone(
            appointment.price_quoted,
            'a partial sum is a wrong number on an invoice — same rule as '
            'nail_visit_price',
        )

    def test_a_price_typed_in_is_never_overwritten(self):
        self.tidy_up.default_minutes = 25
        self.tidy_up.default_price = Decimal('15.00')
        self.tidy_up.save()

        appointment = self._book([self.tidy_up], price_quoted='40.00')
        self.assertEqual(
            appointment.price_quoted, Decimal('40.00'),
            'the force_* guard: Jess overrode it, so the resolver must not '
            'quietly replace it',
        )

    def test_an_end_time_typed_in_is_never_overwritten(self):
        self.tidy_up.default_minutes = 25
        self.tidy_up.save()

        end = self.start + timedelta(minutes=90)
        appointment = self._book([self.tidy_up], end_at=end.isoformat())
        self.assertEqual(appointment.duration_minutes, 90)

    def test_every_service_blank_still_gives_a_visible_block(self):
        # A zero-minute booking would be invisible in the diary.
        appointment = self._book([self.tidy_up])
        self.assertGreater(appointment.duration_minutes, 0)

    def test_the_check_endpoint_uses_the_same_resolver(self):
        self.nail_clipping.default_minutes = 20
        self.nail_clipping.default_price = Decimal('8.00')
        self.nail_clipping.save()

        response = self.staff_client.post(
            '/api/appointments/check/',
            {
                'dog': self.alice_dog.pk,
                'start_at': self.start.isoformat(),
                'services': [self.nail_clipping.pk],
            },
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(Decimal(response.data['suggested_price']), Decimal('8.00'))
        self.assertEqual(
            response.data['suggested_end_at'], self.start + timedelta(minutes=20),
        )

    def test_the_check_names_what_has_no_price(self):
        response = self.staff_client.post(
            '/api/appointments/check/',
            {
                'dog': self.alice_dog.pk,
                'start_at': self.start.isoformat(),
                'services': [self.tidy_up.pk],
            },
            format='json',
        )
        warning = next(
            w for w in response.data['warnings'] if w['code'] == 'service_not_priced'
        )
        self.assertIn('Tidy Up', warning['message'])
        self.assertEqual(response.data['unpriced_services'], ['Tidy Up'])

    def test_a_groom_booked_with_only_nails_services_warns(self):
        response = self.staff_client.post(
            '/api/appointments/check/',
            {
                'dog': self.alice_dog.pk,
                'start_at': self.start.isoformat(),
                'service_type': ServiceType.GROOM,
                'services': [self.nail_clipping.pk],
            },
            format='json',
        )
        codes = [w['code'] for w in response.data['warnings']]
        self.assertIn('service_category_mismatch', codes)

    def test_a_standing_series_uses_the_dogs_usual_services(self):
        """`_materialise` hard-coded the groom time.

        A standing nail-trim series would have blocked out three hours a
        fortnight, forever, and nobody would notice until the diary was full.
        """
        self.nail_clipping.default_minutes = 20
        self.nail_clipping.save()
        self.alice_dog.default_services.set([self.nail_clipping])

        response = self.staff_client.post(
            '/api/booking-series/',
            {
                'dog': self.alice_dog.pk,
                'interval_weeks': 2,
                'start_date': (timezone.localdate() + timedelta(days=7)).isoformat(),
                'preferred_time': '10:00',
            },
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

        made = Appointment.objects.filter(series_id=response.data['id']).first()
        self.assertIsNotNone(made)
        self.assertEqual(made.duration_minutes, 20)

    def test_a_part_groom_does_not_become_the_dogs_default_time(self):
        """`apply_to_dog` guarded on the coarse type only.

        Before the catalogue a GROOM visit was always a whole groom. A
        25-minute Tidy Up is one now too, and letting that overwrite a
        105-minute default is the same bug in a new coat.
        """
        appointment = self._book([self.tidy_up])
        session = GroomSession.objects.create(
            dog=self.alice_dog, appointment=appointment, recorded_minutes=25,
        )
        before = self.alice_dog.groom_minutes

        self.assertFalse(session.apply_to_dog())
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.groom_minutes, before)

    def test_a_full_groom_still_writes_back(self):
        appointment = self._book([self.full_groom])
        session = GroomSession.objects.create(
            dog=self.alice_dog, appointment=appointment, recorded_minutes=115,
        )
        self.assertTrue(session.apply_to_dog())
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.groom_minutes, 115)

    def test_a_session_with_no_appointment_still_writes_back(self):
        # Every timing recorded before the catalogue existed.
        session = GroomSession.objects.create(dog=self.alice_dog, recorded_minutes=120)
        self.assertTrue(session.apply_to_dog())

    def test_a_client_can_read_the_catalogue(self):
        # They need it to request a nail trim rather than a full groom.
        response = self.alice_client.get('/api/services/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertGreater(response.data['count'], 0)

    def test_a_client_cannot_edit_the_catalogue(self):
        response = self.alice_client.patch(
            f'/api/services/{self.tidy_up.pk}/', {'default_price': '5.00'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_retired_service_is_not_offered(self):
        self.tidy_up.is_active = False
        self.tidy_up.save()

        codes = [row['code'] for row in self.staff_client.get('/api/services/').data['results']]
        self.assertNotIn('tidy_up', codes)

    def test_a_dogs_usual_services_are_visible_to_its_owner(self):
        # Not staff-only: it is what the owner asked for, and they need it to
        # request the right kind of booking.
        self.alice_dog.default_services.set([self.nail_clipping])
        response = self.alice_client.get(f'/api/dogs/{self.alice_dog.pk}/')
        self.assertEqual(response.data['default_services'], [self.nail_clipping.pk])


class ServiceSeedTests(TestCase):
    """Jess's prices must survive a redeploy — entrypoint.sh reseeds on boot."""

    def test_every_service_is_created_once(self):
        call_command('seed_breeds', verbosity=0)
        call_command('seed_breeds', verbosity=0)
        self.assertEqual(Service.objects.count(), 13)
        self.assertEqual(Service.objects.filter(name='Health Check').count(), 1)

    def test_prices_and_lengths_seed_blank(self):
        call_command('seed_breeds', verbosity=0)
        for service in Service.objects.all():
            self.assertIsNone(service.default_price, service.code)
            self.assertIsNone(service.default_minutes, service.code)

    def test_a_price_jess_sets_survives_a_reseed_and_an_overwrite(self):
        call_command('seed_breeds', verbosity=0)
        Service.objects.filter(code='tidy_up').update(
            default_price=Decimal('18.00'), default_minutes=30,
        )

        call_command('seed_breeds', verbosity=0)
        call_command('seed_breeds', '--overwrite', verbosity=0)

        tidy = Service.objects.get(code='tidy_up')
        self.assertEqual(
            tidy.default_price, Decimal('18.00'),
            'unlike breeds, Jess is the source of truth for a service price — '
            '--overwrite must not touch it',
        )
        self.assertEqual(tidy.default_minutes, 30)

    def test_renaming_a_service_does_not_resurrect_the_old_one(self):
        # Breed is keyed by name and has exactly this bug; Service is keyed by
        # code so it does not.
        call_command('seed_breeds', verbosity=0)
        Service.objects.filter(code='tidy_up').update(name='Quick tidy')

        call_command('seed_breeds', verbosity=0)

        self.assertEqual(Service.objects.filter(code='tidy_up').count(), 1)
        self.assertEqual(Service.objects.get(code='tidy_up').name, 'Quick tidy')
        self.assertFalse(Service.objects.filter(name='Tidy Up').exists())

    def test_only_the_full_groom_takes_the_dogs_figures(self):
        call_command('seed_breeds', verbosity=0)
        takers = list(
            Service.objects.filter(takes_dog_defaults=True).values_list('code', flat=True)
        )
        self.assertEqual(takers, ['full_groom'])


class InvoiceFromAppointmentTests(BaseAPITestCase):
    """An invoice raised from what was actually done.

    An unpriced service gets no line rather than a £0.00 one — `unit_price`
    cannot be null, so the alternatives are inventing a figure or claiming the
    service was free.
    """

    def setUp(self):
        super().setUp()
        self.nail_clipping = Service.objects.create(
            code='nail_clipping', name='Nail Clipping',
            category=ServiceType.NAILS_FLEAS_TICKS, sort_order=120,
        )
        self.tidy_up = Service.objects.create(
            code='tidy_up', name='Tidy Up', category=ServiceType.GROOM, sort_order=60,
        )
        self.appointment = Appointment.objects.create(
            dog=self.alice_dog,
            start_at=timezone.now() + timedelta(days=1),
        )

    def test_one_line_per_priced_service(self):
        self.nail_clipping.default_price = Decimal('8.00')
        self.nail_clipping.save()
        self.appointment.services.set([self.nail_clipping])

        response = self.staff_client.post(
            '/api/invoices/from_appointment/',
            {'appointment': self.appointment.pk, 'number': 'INV-900'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        invoice = Invoice.objects.get(number='INV-900')
        self.assertEqual(invoice.lines.count(), 1)
        self.assertEqual(invoice.total, Decimal('8.00'))
        self.assertEqual(response.data['unpriced'], [])

    def test_an_unpriced_service_is_reported_rather_than_written_as_free(self):
        self.nail_clipping.default_price = Decimal('8.00')
        self.nail_clipping.save()
        self.appointment.services.set([self.nail_clipping, self.tidy_up])

        response = self.staff_client.post(
            '/api/invoices/from_appointment/',
            {'appointment': self.appointment.pk, 'number': 'INV-901'},
            format='json',
        )
        self.assertEqual(response.data['unpriced'], ['Tidy Up'])
        invoice = Invoice.objects.get(number='INV-901')
        self.assertEqual(invoice.lines.count(), 1, 'no £0.00 line for the unpriced one')

    def test_a_booking_with_no_services_uses_its_quote(self):
        response = self.staff_client.post(
            '/api/invoices/from_appointment/',
            {'appointment': self.appointment.pk, 'number': 'INV-902'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            Invoice.objects.get(number='INV-902').total,
            self.alice_dog.effective_price,
        )

    def test_a_duplicate_number_is_refused(self):
        Invoice.objects.create(client=self.alice, number='INV-903')
        response = self.staff_client.post(
            '/api/invoices/from_appointment/',
            {'appointment': self.appointment.pk, 'number': 'INV-903'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)

    def test_a_client_cannot_raise_one(self):
        response = self.alice_client.post(
            '/api/invoices/from_appointment/',
            {'appointment': self.appointment.pk, 'number': 'INV-904'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class ClientUidVisibilityTests(BaseAPITestCase):
    """The UID is Jess's filing reference, and she asked to hide it from clients.

    Not the same kind of rule as the staff-only notes beside it — the UID is
    printed on the client's own paper booking card, so this is a presentation
    preference rather than a confidentiality fix, and conflating the two would
    weaken the rule that matters.

    It reaches a client by four separate routes, so gating one is cosmetic.
    """

    def setUp(self):
        super().setUp()
        settings_row = AppSettings.get()
        settings_row.invoicing_visible_to_clients = True
        settings_row.save()
        self.invoice = Invoice.objects.create(client=self.alice, number='INV-001')

    def test_hidden_on_their_own_client_record(self):
        response = self.alice_client.get(f'/api/clients/{self.alice.pk}/')
        self.assertNotIn('uid', response.data)

    def test_hidden_on_the_owner_block_of_a_dog(self):
        response = self.alice_client.get(f'/api/dogs/{self.alice_dog.pk}/')
        self.assertNotIn('uid', response.data['client_detail'])

    def test_hidden_on_the_dog_list(self):
        # A separate declared field, so it needs its own entry — gating only
        # ClientSerializer would leave this one open.
        response = self.alice_client.get('/api/dogs/')
        self.assertNotIn('client_uid', response.data['results'][0])

    def test_hidden_on_an_invoice(self):
        response = self.alice_client.get('/api/invoices/')
        self.assertNotIn('client_uid', response.data['results'][0])

    def test_staff_still_see_it_everywhere(self):
        self.assertIn('uid', self.staff_client.get(f'/api/clients/{self.alice.pk}/').data)
        self.assertIn(
            'client_uid', self.staff_client.get('/api/dogs/').data['results'][0],
        )
        self.assertIn(
            'client_uid', self.staff_client.get('/api/invoices/').data['results'][0],
        )
        self.assertIn(
            'uid',
            self.staff_client.get(f'/api/dogs/{self.alice_dog.pk}/').data['client_detail'],
        )

    def test_staff_can_still_search_by_uid(self):
        response = self.staff_client.get('/api/dogs/?search=MOJO-001')
        self.assertEqual(response.data['count'], 1)


class InvoiceLifecycleTests(BaseAPITestCase):
    """Paid is the end of the road.

    Jess's complaint: "PAID should always be the final? As if recorded as paid
    then sent it just shows as sent." Marking an invoice sent after it has been
    paid would quietly un-pay it, and she would chase money she already has.

    The rule is enforced on the actions *and* in the serializer, because
    ``status`` is a plain writable field the app has always PATCHed directly —
    governing only the actions would leave the front door open.
    """

    def setUp(self):
        super().setUp()
        self.invoice = Invoice.objects.create(client=self.alice, number='INV-001')
        InvoiceLine.objects.create(
            invoice=self.invoice, description='Full groom',
            quantity=Decimal('1.00'), unit_price=Decimal('50.00'),
        )

    def test_mark_sent_records_the_date(self):
        response = self.staff_client.post(f'/api/invoices/{self.invoice.pk}/mark_sent/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, Invoice.Status.SENT)
        self.assertEqual(self.invoice.sent_at, date.today())

    def test_mark_paid_records_the_payment_and_how_it_was_paid(self):
        response = self.staff_client.post(
            f'/api/invoices/{self.invoice.pk}/mark_paid/',
            {'method': 'CASH'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, Invoice.Status.PAID)
        self.assertEqual(self.invoice.paid_at, date.today())

        payment = Payment.objects.get(invoice=self.invoice)
        self.assertEqual(payment.amount, Decimal('50.00'), 'defaults to the balance')
        self.assertEqual(
            payment.method, 'CASH',
            'the column always existed and nothing ever filled it in, so every '
            'invoice in the books said CARD',
        )
        self.assertEqual(payment.recorded_by, self.staff)

    def test_mark_paid_rejects_a_method_that_is_not_one(self):
        response = self.staff_client.post(
            f'/api/invoices/{self.invoice.pk}/mark_paid/',
            {'method': 'CRYPTO'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Payment.objects.filter(invoice=self.invoice).exists())

    def test_marking_a_paid_invoice_sent_is_refused(self):
        self.staff_client.post(f'/api/invoices/{self.invoice.pk}/mark_paid/', {}, format='json')

        response = self.staff_client.post(f'/api/invoices/{self.invoice.pk}/mark_sent/')
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)

        self.invoice.refresh_from_db()
        self.assertEqual(
            self.invoice.status, Invoice.Status.PAID,
            'this is the whole complaint — it must not slip back to sent',
        )

    def test_patching_a_paid_invoice_back_to_sent_is_refused_too(self):
        # The actions are not the only door: the app PATCHes status directly.
        self.invoice.status = Invoice.Status.PAID
        self.invoice.save()

        response = self.staff_client.patch(
            f'/api/invoices/{self.invoice.pk}/', {'status': 'SENT'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, Invoice.Status.PAID)

    def test_a_paid_invoice_can_still_be_voided(self):
        # The one escape. A one-groomer business needs a way to cancel a
        # mistake, and a credit-note model is more machinery than this earns.
        self.invoice.status = Invoice.Status.PAID
        self.invoice.save()

        response = self.staff_client.patch(
            f'/api/invoices/{self.invoice.pk}/', {'status': 'VOID'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_a_sent_invoice_can_go_back_to_draft(self):
        # An invoice sent with the wrong figure on it has to be editable again.
        self.invoice.status = Invoice.Status.SENT
        self.invoice.save()

        response = self.staff_client.patch(
            f'/api/invoices/{self.invoice.pk}/', {'status': 'DRAFT'}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_a_void_invoice_goes_nowhere(self):
        self.invoice.status = Invoice.Status.VOID
        self.invoice.save()

        for target in ('DRAFT', 'SENT', 'PAID'):
            response = self.staff_client.patch(
                f'/api/invoices/{self.invoice.pk}/', {'status': target}, format='json',
            )
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST, target)

    def test_saving_an_invoice_without_touching_the_status_still_works(self):
        # Guards the obvious way to break this: treating "same status" as an
        # illegal transition would make every ordinary edit fail.
        self.invoice.status = Invoice.Status.PAID
        self.invoice.save()

        response = self.staff_client.patch(
            f'/api/invoices/{self.invoice.pk}/',
            {'status': 'PAID', 'notes': 'Paid at the door'},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_a_client_cannot_mark_their_own_invoice_paid(self):
        settings_row = AppSettings.get()
        settings_row.invoicing_visible_to_clients = True
        settings_row.save()

        response = self.alice_client.post(
            f'/api/invoices/{self.invoice.pk}/mark_paid/', {}, format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(Payment.objects.filter(invoice=self.invoice).exists())


class InvoiceDeletionTests(BaseAPITestCase):
    """Deleting an invoice is staff-only, and only ever a draft.

    ``InvoiceViewSet`` gated create and update but not destroy, so the moment
    ``invoicing_visible_to_clients`` was switched on a client could DELETE
    their own invoice — the scoped queryset put it within reach, and
    ``Payment.invoice`` cascades, so the payment record went with it.

    Past draft, a number has been quoted to somebody and ``Invoice.number`` is
    unique, so deleting frees it for a later invoice with a different total.
    Those get voided instead.
    """

    def setUp(self):
        super().setUp()
        self.invoice = Invoice.objects.create(client=self.alice, number='INV-001')
        settings_row = AppSettings.get()
        settings_row.invoicing_visible_to_clients = True
        settings_row.save()

    def test_client_cannot_delete_their_own_invoice(self):
        response = self.alice_client.delete(f'/api/invoices/{self.invoice.pk}/')
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertTrue(Invoice.objects.filter(pk=self.invoice.pk).exists())

    def test_staff_can_delete_a_draft(self):
        response = self.staff_client.delete(f'/api/invoices/{self.invoice.pk}/')
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(Invoice.objects.filter(pk=self.invoice.pk).exists())

    def test_a_sent_invoice_cannot_be_deleted(self):
        self.invoice.status = Invoice.Status.SENT
        self.invoice.save()

        response = self.staff_client.delete(f'/api/invoices/{self.invoice.pk}/')
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertTrue(Invoice.objects.filter(pk=self.invoice.pk).exists())

    def test_a_draft_with_a_payment_cannot_be_deleted(self):
        Payment.objects.create(
            invoice=self.invoice, amount=Decimal('20.00'), paid_at=date.today(),
        )

        response = self.staff_client.delete(f'/api/invoices/{self.invoice.pk}/')
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertTrue(Payment.objects.filter(invoice=self.invoice).exists())


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


class RegistrationTests(BaseAPITestCase):
    """Registration is the one endpoint a stranger writes to the User table
    through, and the one place a bad account can be created that nobody can
    later sign in to."""

    def setUp(self):
        super().setUp()
        self.alice_user.email = 'alice@example.com'
        self.alice_user.save()
        self.public = APIClient()

    def register(self, **overrides):
        body = {
            'username': 'carol',
            'email': 'carol@example.com',
            'password': 'Grooming-2026!',
        }
        body.update(overrides)
        return self.public.post('/api/auth/users/', body)

    def test_a_new_client_can_sign_up(self):
        response = self.register()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(User.objects.filter(username='carol').exists())

    def test_email_is_required(self):
        """An account with no email cannot be sent a reset link, and gives
        Jess nothing to recognise the person by."""
        response = self.register(email='')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('email', response.data)

    def test_an_email_already_in_use_is_refused(self):
        response = self.register(email='ALICE@example.com')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('email', response.data)

    def test_an_email_on_an_unclaimed_client_record_is_fine(self):
        """A client Jess entered by hand signing up for the first time is the
        normal path, not a duplicate — they claim the record afterwards."""
        Client.objects.create(
            uid='MOJO-060', first_name='Carol', last_name='Clark', email='carol@example.com',
        )
        self.assertEqual(self.register().status_code, status.HTTP_201_CREATED)

    def test_a_username_differing_only_by_case_is_refused(self):
        """Django's uniqueness is exact, so "Alice" and "alice" would both
        exist — and then neither can sign in, because the backend refuses an
        ambiguous identifier."""
        response = self.register(username='Alice')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('username', response.data)
        self.assertFalse(User.objects.filter(username='Alice').exists())

    def test_a_very_short_username_is_refused(self):
        self.assertEqual(self.register(username='cj').status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_username_with_spaces_is_refused(self):
        self.assertEqual(
            self.register(username='carol jones').status_code, status.HTTP_400_BAD_REQUEST,
        )

    def test_a_weak_password_is_refused(self):
        response = self.register(password='password')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('password', response.data)

    def test_a_password_built_from_the_email_is_refused(self):
        """djoser validates against a User carrying only the username, so a
        password made of the email address used to sail through."""
        response = self.register(email='sunflower@example.com', password='sunflower@example')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('password', response.data)

    def test_registration_cannot_grant_staff(self):
        self.register(is_staff=True, is_superuser=True)
        carol = User.objects.get(username='carol')
        self.assertFalse(carol.is_staff)
        self.assertFalse(carol.is_superuser)


class SignInTests(BaseAPITestCase):
    """Clients type whatever they remember weeks later, on a keyboard that
    capitalises the first letter."""

    def setUp(self):
        super().setUp()
        # The fixtures hold the address on the client record, which is where
        # it lived before registration required one on the login too.
        self.alice_user.email = 'alice@example.com'
        self.alice_user.save()
        self.public = APIClient()

    def sign_in(self, username, password='pw'):
        return self.public.post(
            '/api/auth/token/login/', {'username': username, 'password': password},
        )

    def test_the_username_signs_in(self):
        self.assertEqual(self.sign_in('alice').status_code, status.HTTP_200_OK)

    def test_the_email_signs_in_too(self):
        self.assertEqual(self.sign_in('alice@example.com').status_code, status.HTTP_200_OK)

    def test_case_does_not_matter(self):
        self.assertEqual(self.sign_in('Alice').status_code, status.HTTP_200_OK)
        self.assertEqual(self.sign_in('ALICE@EXAMPLE.COM').status_code, status.HTTP_200_OK)

    def test_surrounding_space_is_ignored(self):
        self.assertEqual(self.sign_in('  alice  ').status_code, status.HTTP_200_OK)

    def test_a_wrong_password_still_fails(self):
        self.assertEqual(
            self.sign_in('alice', password='wrong').status_code, status.HTTP_400_BAD_REQUEST,
        )

    def test_a_username_beats_someone_elses_email(self):
        """Nobody should be able to intercept another account's sign-in by
        registering their email address as a username."""
        impostor = User.objects.create_user('alice@example.com', password='impostor-pw')
        response = self.sign_in('alice@example.com', password='impostor-pw')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        token = response.data['auth_token']
        me = APIClient()
        me.credentials(HTTP_AUTHORIZATION=f'Token {token}')
        self.assertEqual(me.get('/api/auth/users/me/').data['id'], impostor.pk)

    def test_an_ambiguous_identifier_signs_nobody_in(self):
        """Two accounts sharing an email — possible on rows predating the
        uniqueness check — must fail closed rather than pick one."""
        User.objects.create_user('alice2', password='pw', email='alice@example.com')
        self.assertEqual(self.sign_in('alice@example.com').status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_disabled_account_cannot_sign_in(self):
        self.alice_user.is_active = False
        self.alice_user.save()
        self.assertEqual(self.sign_in('alice').status_code, status.HTTP_400_BAD_REQUEST)


class PasswordResetIssuingTests(BaseAPITestCase):
    """Only a superuser may hand out a link, and the link itself is returned
    exactly once."""

    def setUp(self):
        super().setUp()
        self.manager = User.objects.create_user('manager', password='pw', is_staff=True)
        self.manager_client = APIClient()
        self.manager_client.force_authenticate(self.manager)

    def issue(self, client=None, **body):
        return (client or self.staff_client).post('/api/password-resets/', body or {'username': 'alice'})

    def test_a_superuser_can_issue_a_link(self):
        response = self.issue()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertIn('/reset/', response.data['link'])
        self.assertTrue(response.data['token'])

    def test_staff_who_are_not_superusers_cannot(self):
        """is_staff opens the management surface; taking over an account is a
        step past that."""
        self.assertEqual(self.issue(self.manager_client).status_code, status.HTTP_403_FORBIDDEN)

    def test_a_client_cannot_issue_a_link_for_anyone(self):
        response = self.issue(self.alice_client, username='bob')
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(PasswordResetToken.objects.exists())

    def test_the_link_can_be_asked_for_by_client_record(self):
        """Jess picks people out of her client list, not out of a list of
        usernames."""
        response = self.issue(client_id=self.alice.pk)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(PasswordResetToken.objects.get().user, self.alice_user)

    def test_a_client_record_with_no_login_says_so(self):
        orphan = Client.objects.create(uid='MOJO-050', first_name='Nobody', last_name='Yet')
        response = self.issue(client_id=orphan.pk)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('no login', response.data['detail'])

    def test_naming_no_account_at_all_is_a_clear_error(self):
        response = self.staff_client.post('/api/password-resets/', {})
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_issuing_a_second_link_voids_the_first(self):
        first = self.issue().data['token']
        self.issue()
        self.assertEqual(
            self.public_get(first).status_code, status.HTTP_410_GONE,
        )

    def public_get(self, token):
        return APIClient().get(f'/api/password-reset/{token}/')

    def test_the_history_never_carries_the_token(self):
        """A link readable out of the API is a link a stolen staff session
        can read out too."""
        token = self.issue().data['token']
        listing = self.staff_client.get('/api/password-resets/')
        self.assertEqual(listing.status_code, status.HTTP_200_OK)
        self.assertNotIn(token, listing.content.decode())
        self.assertEqual(listing.data['results'][0]['username'], 'alice')

    def test_it_reports_that_email_is_not_configured(self):
        """The app has to say "copy this and send it" rather than claim an
        email is on its way that nobody will receive."""
        response = self.issue()
        self.assertFalse(response.data['emailed'])
        self.assertFalse(response.data['email_configured'])


class PasswordResetUseTests(BaseAPITestCase):
    def setUp(self):
        super().setUp()
        self.alice_user.email = 'alice@example.com'
        self.alice_user.save()
        self.reset = PasswordResetToken.issue(self.alice_user, created_by=self.staff)
        self.public = APIClient()

    def use(self, password='Brand-New-2026!', token=None):
        return self.public.post(
            f'/api/password-reset/{token or self.reset.token}/', {'password': password},
        )

    def test_it_sets_the_password(self):
        self.assertEqual(self.use().status_code, status.HTTP_200_OK)
        self.alice_user.refresh_from_db()
        self.assertTrue(self.alice_user.check_password('Brand-New-2026!'))

    def test_a_get_shows_who_the_link_is_for(self):
        response = self.public.get(f'/api/password-reset/{self.reset.token}/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['username'], 'alice')

    def test_the_link_works_only_once(self):
        self.use()
        self.assertEqual(self.use(password='Second-Try-2026!').status_code, status.HTTP_410_GONE)

    def test_an_expired_link_is_refused(self):
        self.reset.expires_at = timezone.now() - timedelta(hours=1)
        self.reset.save()
        self.assertEqual(self.use().status_code, status.HTTP_410_GONE)

    def test_an_unknown_token_is_404(self):
        self.assertEqual(self.use(token='not-a-real-token').status_code, status.HTTP_404_NOT_FOUND)

    def test_a_weak_password_is_refused_and_the_link_survives(self):
        response = self.use(password='12345678')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.reset.refresh_from_db()
        self.assertTrue(self.reset.is_usable, 'a rejected attempt must not burn the link')

    def test_the_password_is_checked_against_the_right_account(self):
        """The user comes from the token, not the request body, so the
        similarity validator sees the details of the account being reset —
        including its email, which is not in the request at all."""
        self.assertEqual(
            self.use(password='alice@example.com').status_code, status.HTTP_400_BAD_REQUEST,
        )

    def test_using_a_link_signs_the_account_out_everywhere(self):
        """A reset is often "someone else has my password" — changing it alone
        would leave their session working."""
        from rest_framework.authtoken.models import Token

        Token.objects.create(user=self.alice_user)
        self.use()
        self.assertFalse(Token.objects.filter(user=self.alice_user).exists())

    def test_nothing_else_is_signed_out(self):
        from rest_framework.authtoken.models import Token

        bobs = Token.objects.create(user=self.bob_user)
        self.use()
        self.assertTrue(Token.objects.filter(pk=bobs.pk).exists())


class PasswordResetPageTests(BaseAPITestCase):
    """The reset page is a web page for the same reason the intake form is:
    whoever opens it cannot get into the app — that is the problem."""

    def setUp(self):
        super().setUp()
        self.reset = PasswordResetToken.issue(self.alice_user)
        self.public = APIClient()

    def test_the_link_resolves(self):
        response = self.public.get(f'/reset/{self.reset.token}/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn('text/html', response['Content-Type'])

    def test_it_works_without_a_trailing_slash(self):
        self.assertEqual(
            self.public.get(f'/reset/{self.reset.token}').status_code, status.HTTP_200_OK,
        )

    def test_the_page_says_whose_account_it_is(self):
        html = self.public.get(f'/reset/{self.reset.token}/').content.decode()
        self.assertIn('alice', html)
        # The token reaches the script through json_script, and the page posts
        # it back to the tested API rather than reimplementing any of it.
        self.assertIn(self.reset.token, html)
        self.assertIn('/api/password-reset/', html)

    def test_the_page_is_not_indexable(self):
        html = self.public.get(f'/reset/{self.reset.token}/').content.decode()
        self.assertIn('noindex', html)

    def test_a_used_link_explains_itself_rather_than_erroring(self):
        self.reset.used_at = timezone.now()
        self.reset.save()
        response = self.public.get(f'/reset/{self.reset.token}/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn('already been used', response.content.decode())

    def test_an_expired_link_explains_itself(self):
        self.reset.expires_at = timezone.now() - timedelta(hours=1)
        self.reset.save()
        self.assertIn('expired', self.public.get(f'/reset/{self.reset.token}/').content.decode())

    def test_an_unknown_token_is_404_not_a_crash(self):
        self.assertEqual(
            self.public.get('/reset/not-a-real-token/').status_code, status.HTTP_404_NOT_FOUND,
        )

    def test_loading_the_page_does_not_spend_the_submission_budget(self):
        """Separate throttle scopes, exactly as for intake: reloading must not
        lock someone out of actually setting a password."""
        for _ in range(25):
            self.public.get(f'/reset/{self.reset.token}/')
        response = self.public.post(
            f'/api/password-reset/{self.reset.token}/', {'password': 'Brand-New-2026!'},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)


class PasswordResetRequestTests(BaseAPITestCase):
    """"I've forgotten my password", from someone who cannot sign in."""

    def setUp(self):
        super().setUp()
        self.public = APIClient()

    def ask(self, identifier, note=''):
        return self.public.post(
            '/api/password-reset-requests/', {'identifier': identifier, 'note': note},
        )

    def test_anyone_can_ask(self):
        response = self.ask('alice')
        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(PasswordResetRequest.objects.get().user, self.alice_user)

    def test_the_email_on_the_client_record_resolves_too(self):
        """Anyone who signed up before an email was required has one only on
        their client record — and that is the address they will type."""
        self.ask('ALICE@example.com')
        self.assertEqual(PasswordResetRequest.objects.get().user, self.alice_user)

    def test_an_unknown_name_answers_identically(self):
        """Otherwise this is a way to find out who has an account."""
        known = self.ask('alice')
        cache.clear()
        unknown = self.ask('nobody-at-all')
        self.assertEqual(known.status_code, unknown.status_code)
        self.assertEqual(known.data, unknown.data)

    def test_an_unmatched_request_is_still_recorded(self):
        """Someone typing the wrong thing is exactly who needs help; Jess sees
        what they typed and can work out who they are."""
        self.ask('alicce')
        request = PasswordResetRequest.objects.get()
        self.assertIsNone(request.user)
        self.assertEqual(request.identifier, 'alicce')

    def test_the_reply_never_says_whether_it_matched(self):
        body = str(self.ask('alice').data)
        self.assertNotIn('alice', body)

    def test_a_client_cannot_read_the_queue(self):
        self.ask('alice')
        self.assertEqual(
            self.alice_client.get('/api/password-reset-requests/').status_code,
            status.HTTP_403_FORBIDDEN,
        )

    def test_a_superuser_sees_who_it_resolved_to(self):
        self.ask('alice')
        response = self.staff_client.get('/api/password-reset-requests/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['results'][0]['username'], 'alice')
        self.assertEqual(response.data['results'][0]['client_name'], 'Alice Adams')

    def test_issuing_a_link_closes_the_request(self):
        self.ask('alice')
        request = PasswordResetRequest.objects.get()
        response = self.staff_client.post('/api/password-resets/', {'request_id': request.pk})
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        request.refresh_from_db()
        self.assertEqual(request.status, PasswordResetRequest.Status.SENT)
        self.assertIsNotNone(request.issued_token)

    def test_an_unmatched_request_cannot_be_turned_into_a_link(self):
        self.ask('nobody-at-all')
        request = PasswordResetRequest.objects.get()
        response = self.staff_client.post('/api/password-resets/', {'request_id': request.pk})
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_it_can_be_dismissed(self):
        self.ask('alice')
        request = PasswordResetRequest.objects.get()
        response = self.staff_client.post(f'/api/password-reset-requests/{request.pk}/dismiss/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        request.refresh_from_db()
        self.assertEqual(request.status, PasswordResetRequest.Status.DISMISSED)

    def test_asking_repeatedly_is_throttled(self):
        """Each one puts a row in front of Jess, so this is a nuisance vector
        as much as a security one."""
        codes = [self.ask('alice').status_code for _ in range(8)]
        self.assertIn(status.HTTP_429_TOO_MANY_REQUESTS, codes)


class AccountListTests(BaseAPITestCase):
    def test_a_superuser_can_look_up_who_has_a_login(self):
        response = self.staff_client.get('/api/accounts/', {'search': 'MOJO-001'})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['results'][0]['username'], 'alice')
        self.assertEqual(response.data['results'][0]['client_name'], 'Alice Adams')

    def test_a_client_cannot(self):
        self.assertEqual(
            self.alice_client.get('/api/accounts/').status_code, status.HTTP_403_FORBIDDEN,
        )

    def test_the_list_carries_no_credentials(self):
        body = self.staff_client.get('/api/accounts/').content.decode()
        self.assertNotIn('password', body)

    def test_me_reports_superuser_so_the_app_can_gate_the_screen(self):
        self.assertTrue(self.staff_client.get('/api/auth/users/me/').data['is_superuser'])
        self.assertFalse(self.alice_client.get('/api/auth/users/me/').data['is_superuser'])


class HealthTests(APITestCase):
    def test_health_needs_no_login(self):
        response = APIClient().get('/api/health/')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['status'], 'ok')


class SeedBreedsTests(TestCase):
    """The price list is Jess's, so the grid is worth a guard.

    The count check is the one that earns its keep: ``get_or_create`` keys on
    the name, so a breed listed twice in ``BREEDS`` silently collapses into one
    row rather than failing, and 250-odd hand-entered names is exactly where a
    duplicate hides.
    """

    def test_every_breed_in_the_table_becomes_a_row(self):
        call_command('seed_breeds', verbosity=0)
        self.assertEqual(Breed.objects.count(), len(BREEDS))

    def test_a_breed_takes_its_price_from_its_size_and_coat(self):
        call_command('seed_breeds', verbosity=0)
        westie = Breed.objects.get(name='West Highland White Terrier')
        self.assertEqual(westie.coat_type, 'wire')
        self.assertEqual(westie.avg_groom_minutes, 120)
        self.assertEqual(westie.avg_price, Decimal('60.00'))
        self.assertEqual(westie.notes, 'Small (5-10kg)')

    def test_reseeding_leaves_jess_s_own_edits_alone_until_overwrite(self):
        Breed.objects.create(
            name='West Highland White Terrier', coat_type='wire',
            avg_groom_minutes=45, avg_price=Decimal('38.00'), avg_schedule_weeks=10,
        )
        call_command('seed_breeds', verbosity=0)
        self.assertEqual(
            Breed.objects.get(name='West Highland White Terrier').avg_price,
            Decimal('38.00'),
        )
        call_command('seed_breeds', '--overwrite', verbosity=0)
        self.assertEqual(
            Breed.objects.get(name='West Highland White Terrier').avg_price,
            Decimal('60.00'),
        )


class VisitRecordTests(BaseAPITestCase):
    """Jess's two ongoing record cards, both landing on GroomSession.

    One model rather than two: the cards are the same shape, and hers are filed
    per dog — splitting them would split a dog's history in half.
    """

    def setUp(self):
        super().setUp()
        self.clippers = Equipment.objects.create(name='Clippers', uid='CLIP-01')
        self.blade = Equipment.objects.create(name='Blade 7F', uid='BLADE-07')

    def test_a_groom_record_holds_the_whole_card(self):
        response = self.staff_client.post('/api/groom-sessions/', {
            'dog': self.alice_dog.id,
            'visit_type': 'GROOM',
            'health_check_notes': 'Slight tartar on the back teeth.',
            'matting_paws': True,
            'matting_ears': True,
            'matting_notes': 'Behind both ears, worked out by hand.',
            'bathed_well_behaved': True,
            'high_velocity_dryer': False,
            'shampoo_used': 'Oatmeal',
            'equipment_used': [self.clippers.id, self.blade.id],
            'final_body': 'Half inch all over',
            'final_feet': 'Round',
            'final_tail': 'Left natural',
            'sensitive_notes': 'Fidgety about the back feet.',
            'temperament_observed': Temperament.FIDGETY,
            'notes': 'Settled after the first ten minutes.',
        }, format='json')
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        session = GroomSession.objects.get(pk=response.data['id'])
        self.assertEqual(session.shampoo_used, 'Oatmeal')
        self.assertTrue(session.matting_found)
        self.assertEqual(session.equipment_used.count(), 2)
        self.assertEqual(response.data['equipment_used_detail'][0]['uid'], 'BLADE-07')

    def test_bathing_not_recorded_is_not_the_same_as_badly_behaved(self):
        session = GroomSession.objects.create(dog=self.alice_dog)
        self.assertIsNone(session.bathed_well_behaved)

    def test_a_nails_visit_must_say_which_of_the_three(self):
        response = self.staff_client.post('/api/groom-sessions/', {
            'dog': self.alice_dog.id,
            'visit_type': 'NAILS',
            'recorded_minutes': 15,
        }, format='json')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

        response = self.staff_client.post('/api/groom-sessions/', {
            'dog': self.alice_dog.id,
            'visit_type': 'NAILS',
            'recorded_minutes': 15,
            'nails_done': True,
        }, format='json')
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data['total_minutes'], 15)

    def test_recorded_minutes_stand_in_for_an_unused_timer(self):
        session = GroomSession.objects.create(dog=self.alice_dog, recorded_minutes=25)
        self.assertEqual(session.total_minutes, 25)
        self.assertEqual(session.total_seconds, 1500)

    def test_a_nails_visit_never_becomes_the_dogs_groom_time(self):
        """Twenty minutes is how long a nail trim takes. Writing it to the dog
        would book the next full groom into a twenty-minute slot."""
        before = self.alice_dog.groom_minutes
        session = GroomSession.objects.create(
            dog=self.alice_dog, visit_type=ServiceType.NAILS_FLEAS_TICKS,
            nails_done=True, recorded_minutes=20,
        )
        self.assertFalse(session.apply_to_dog())
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.groom_minutes, before)

        response = self.staff_client.post(f'/api/groom-sessions/{session.id}/apply_to_dog/')
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_groom_record_still_applies(self):
        session = GroomSession.objects.create(dog=self.alice_dog, recorded_minutes=95)
        self.assertTrue(session.apply_to_dog())
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.groom_minutes, 95)

    def test_an_observed_temperament_does_not_rewrite_the_dogs(self):
        """One rough afternoon should not silently change how many dogs Jess
        can take in a day — the booking limits run off Dog.temperament."""
        self.alice_dog.temperament = Temperament.EASY
        self.alice_dog.save()
        GroomSession.objects.create(
            dog=self.alice_dog, temperament_observed=Temperament.FEISTY, recorded_minutes=90,
        ).apply_to_dog()
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.temperament, Temperament.EASY)

    def test_the_list_can_be_narrowed_to_one_kind_of_visit(self):
        GroomSession.objects.create(dog=self.alice_dog, recorded_minutes=90)
        GroomSession.objects.create(
            dog=self.alice_dog, visit_type=ServiceType.NAILS_FLEAS_TICKS,
            nails_done=True, recorded_minutes=15,
        )
        response = self.staff_client.get('/api/groom-sessions/', {'visit_type': 'NAILS'})
        self.assertEqual(len(response.data['results']), 1)
        self.assertEqual(response.data['results'][0]['visit_type'], 'NAILS')

    def test_a_client_cannot_read_the_record_cards(self):
        GroomSession.objects.create(dog=self.alice_dog, recorded_minutes=90)
        self.assertEqual(
            self.alice_client.get('/api/groom-sessions/').status_code,
            status.HTTP_403_FORBIDDEN,
        )


class NailVisitBookingTests(BaseAPITestCase):
    """A nails visit is minutes, not hours, and is not priced off the breed grid."""

    def setUp(self):
        super().setUp()
        self.start = (timezone.now() + timedelta(days=1)).replace(
            hour=10, minute=0, second=0, microsecond=0,
        )

    def test_nothing_is_set_until_jess_sets_it(self):
        """No invented price. Once a made-up figure is in the database it is
        indistinguishable from a real one, and a wrong price on an invoice is
        worse than a blank to fill in."""
        settings_row = AppSettings.get()
        self.assertIsNone(settings_row.nail_visit_price)
        self.assertIsNone(settings_row.nail_visit_minutes)

    def test_booking_before_she_has_set_it_warns_but_goes_through(self):
        response = self.staff_client.post('/api/appointments/check/', {
            'dog': self.bob_dog.id,
            'start_at': self.start.isoformat(),
            'service_type': 'NAILS',
        }, format='json')
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertIn('service_not_priced', codes)
        self.assertIsNone(response.data['suggested_price'])

        # Warned, never blocked — the booking is still accepted.
        created = self.staff_client.post('/api/appointments/', {
            'dog': self.bob_dog.id,
            'start_at': self.start.isoformat(),
            'service_type': 'NAILS',
        }, format='json')
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        self.assertIsNone(Appointment.objects.get(pk=created.data['id']).price_quoted)

    def test_a_groom_booking_is_never_warned_about_the_nails_price(self):
        response = self.staff_client.post('/api/appointments/check/', {
            'dog': self.bob_dog.id,
            'start_at': self.start.isoformat(),
        }, format='json')
        codes = [warning['code'] for warning in response.data['warnings']]
        self.assertNotIn('service_not_priced', codes)

    def test_a_nails_booking_takes_its_slot_and_price_from_settings(self):
        settings_row = AppSettings.get()
        settings_row.nail_visit_minutes = 20
        settings_row.nail_visit_price = Decimal('12.00')
        settings_row.save()

        response = self.staff_client.post('/api/appointments/', {
            'dog': self.bob_dog.id,
            'start_at': self.start.isoformat(),
            'service_type': 'NAILS',
        }, format='json')
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        appointment = Appointment.objects.get(pk=response.data['id'])
        self.assertEqual(appointment.duration_minutes, 20)
        self.assertEqual(appointment.price_quoted, Decimal('12.00'))
        # Not the dog's groom figures, which are far bigger.
        self.assertNotEqual(appointment.price_quoted, self.bob_dog.effective_price)

    def test_a_groom_booking_is_unchanged(self):
        response = self.staff_client.post('/api/appointments/', {
            'dog': self.bob_dog.id,
            'start_at': self.start.isoformat(),
        }, format='json')
        appointment = Appointment.objects.get(pk=response.data['id'])
        self.assertEqual(appointment.service_type, ServiceType.GROOM)
        self.assertEqual(appointment.duration_minutes, self.bob_dog.effective_groom_minutes)
        self.assertEqual(appointment.price_quoted, self.bob_dog.effective_price)

    def test_the_pre_booking_check_suggests_the_shorter_slot(self):
        settings_row = AppSettings.get()
        settings_row.nail_visit_minutes = 20
        settings_row.nail_visit_price = Decimal('12.00')
        settings_row.save()

        response = self.staff_client.post('/api/appointments/check/', {
            'dog': self.bob_dog.id,
            'start_at': self.start.isoformat(),
            'service_type': 'NAILS',
        }, format='json')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        suggested = response.data['suggested_end_at']
        self.assertEqual(
            round((suggested - self.start).total_seconds() / 60),
            settings_row.nail_visit_minutes,
        )
        self.assertEqual(response.data['suggested_price'], settings_row.nail_visit_price)


class AdminSkinTests(BaseAPITestCase):
    """The admin skin hangs on templates/admin/base_site.html, which *shadows*
    a file inside django.contrib.admin. Nothing fails loudly if that shadow
    goes stale — a Django upgrade that restructures the branding or extrastyle
    blocks would just quietly drop the branding and leave the default blue,
    which nobody would notice until Jess opened it."""

    def setUp(self):
        super().setUp()
        self.web = APIClient()
        self.web.login(username='jess', password='pw')

    def test_the_index_names_the_records_not_the_app_label(self):
        html = self.web.get('/admin/').content.decode()
        # ApiConfig.verbose_name. Without it the admin groups every model Jess
        # uses under a heading reading "API".
        self.assertIn('Grooming records', html)
        self.assertNotIn('>API<', html)

    def test_the_skin_reaches_every_kind_of_admin_page(self):
        # change_form and friends override extrastyle themselves and pull ours
        # in through {{ block.super }}. If that chain breaks, the stylesheet
        # silently stops loading on exactly the pages Jess spends time on.
        for url in [
            '/admin/',
            '/admin/api/client/',
            f'/admin/api/client/{self.alice.pk}/change/',
            '/admin/api/client/add/',
            '/admin/api/dog/',
        ]:
            with self.subTest(url=url):
                response = self.web.get(url)
                self.assertEqual(response.status_code, status.HTTP_200_OK)
                self.assertIn('mojo/admin.css', response.content.decode())

    def test_the_branding_is_on_the_page_an_anonymous_visitor_gets(self):
        html = APIClient().get('/admin/login/').content.decode()
        self.assertIn('branding-inner', html)
        self.assertIn('DOG GROOMING', html)
        self.assertIn('mojo/admin.css', html)

    def test_no_template_comment_leaks_onto_the_page(self):
        # Django's {# #} comment form is single-line only: a newline between
        # the delimiters and the engine renders the lot as visible text. This
        # shipped once, putting a note to the next developer across the top of
        # the admin, and nothing failed — every other assertion here checks
        # that something is *present*.
        # The login page needs the anonymous client: signed in, /admin/login/
        # just 302s and the body is empty, so the check would pass vacuously.
        pages = [
            (self.web, '/admin/'),
            (self.web, f'/admin/api/client/{self.alice.pk}/change/'),
            (APIClient(), '/admin/login/'),
        ]
        for client, url in pages:
            with self.subTest(url=url):
                response = client.get(url)
                self.assertEqual(response.status_code, status.HTTP_200_OK)
                html = response.content.decode()
                self.assertNotIn('{#', html)
                self.assertNotIn('#}', html)

    def test_the_stylesheet_is_where_collectstatic_will_look(self):
        # The template links it through {% static %}; if the file is not on a
        # staticfiles path the link still renders and 404s in production, where
        # manifest storage is on and there is no runserver fallback.
        self.assertIsNotNone(finders.find('mojo/admin.css'))


class TemplateCommentSyntaxTests(TestCase):
    """Django's {# #} comment form is single-line only. Put a newline between
    the delimiters and the engine stops treating it as a comment and renders
    the whole thing as page text — no error, no warning, just a note to the
    next developer sitting across the top of the page.

    This is a source scan rather than a rendered-page check on purpose: a
    render test only covers the pages somebody remembered to render, and the
    two that shipped this defect were the admin header and the password reset
    form, which are reached from opposite ends of the app."""

    MULTILINE_HASH_COMMENT = re.compile(r'\{#(?:(?!#\}).)*?\n(?:(?!#\}).)*?#\}', re.S)

    def test_no_template_uses_a_multiline_hash_comment(self):
        offenders = []
        for path in sorted(Path(settings.BASE_DIR, 'templates').rglob('*.html')):
            text = path.read_text(encoding='utf-8')
            for match in self.MULTILINE_HASH_COMMENT.finditer(text):
                line = text[:match.start()].count('\n') + 1
                offenders.append(f'{path.name}:{line}')
        self.assertEqual(
            offenders, [],
            'Multi-line {# #} renders as visible text; use {% comment %} instead. '
            f'Found at: {", ".join(offenders)}',
        )
