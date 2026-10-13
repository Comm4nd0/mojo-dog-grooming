"""Jess's 13 October requests: walk-ins, offline uploads and profile additions."""
from datetime import timedelta
from decimal import Decimal
from uuid import uuid4

from django.test import override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from .models import Appointment, AppointmentStatus, BlockedTime, Dog, Equipment, GroomSession, Invoice, PhaseTiming
from .tests import BaseAPITestCase


@override_settings(PASSWORD_HASHERS=['django.contrib.auth.hashers.MD5PasswordHasher'])
class OctoberRequestsTests(BaseAPITestCase):
    def walk_in(self, **changes):
        payload = {
            'dog': None, 'walk_in_name': 'Little brown spaniel',
            'started_at': (timezone.now() - timedelta(hours=2)).isoformat(),
            'finished_at': timezone.now().isoformat(),
            'client_reference': str(uuid4()),
            'timings': [{'phase': 'PREP', 'duration_seconds': 900}],
            'health_check_notes': 'Keep this private', 'nails_done': True,
        }
        payload.update(changes)
        return self.staff_client.post('/api/groom-sessions/', payload, format='json')

    def test_walk_in_is_saved_without_fake_dog_then_assigned_with_whole_card(self):
        equipment = Equipment.objects.create(name='Comb')
        dog_count = Dog.objects.count()
        result = self.walk_in(equipment_used=[equipment.pk])
        self.assertEqual(result.status_code, 201, result.data)
        session = GroomSession.objects.get(pk=result.data['id'])
        self.assertIsNone(session.dog_id)
        self.assertEqual(Dog.objects.count(), dog_count)
        self.assertIn('Little brown spaniel', str(session))
        self.assertFalse(session.apply_to_dog())
        appt = Appointment.objects.create(dog=self.alice_dog, start_at=session.started_at,
                                          status=AppointmentStatus.CONFIRMED)
        assigned = self.staff_client.post(f'/api/groom-sessions/{session.pk}/assign/',
                                         {'dog': self.alice_dog.pk}, format='json')
        self.assertEqual(assigned.status_code, 200, assigned.data)
        session.refresh_from_db(); appt.refresh_from_db(); self.alice_dog.refresh_from_db()
        self.assertEqual(session.dog_id, self.alice_dog.pk)
        self.assertEqual(session.health_check_notes, 'Keep this private')
        self.assertTrue(session.nails_done)
        self.assertEqual(session.timings.get().duration_seconds, 900)
        self.assertEqual(list(session.equipment_used.all()), [equipment])
        self.assertEqual(session.appointment_id, appt.pk)
        self.assertEqual(appt.status, AppointmentStatus.COMPLETED)
        self.assertEqual(assigned.data['appointment_status_before'], AppointmentStatus.CONFIRMED)
        self.assertIsNone(self.alice_dog.average_groom_minutes)  # Two visits needed.
        second = self.walk_in().data['id']
        self.staff_client.post(f'/api/groom-sessions/{second}/assign/', {'dog': self.alice_dog.pk})
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.average_groom_minutes, 15)
        # Repeating the assignment succeeds; repointing an assigned visit refuses.
        self.assertEqual(self.staff_client.post(f'/api/groom-sessions/{session.pk}/assign/',
                         {'dog': self.alice_dog.pk}).status_code, 200)
        self.assertEqual(self.staff_client.post(f'/api/groom-sessions/{session.pk}/assign/',
                         {'dog': self.bob_dog.pk}).status_code, 409)
        self.assertEqual(self.staff_client.patch(f'/api/groom-sessions/{session.pk}/',
                         {'dog': self.bob_dog.pk}).status_code, 400)

    def test_unassigned_list_and_client_report_boundary(self):
        visit = self.walk_in().data
        self.assertEqual(self.staff_client.get('/api/groom-sessions/?unassigned=1').data['count'], 1)
        for client in [self.alice_client, self.bob_client, APIClient()]:
            for url in ['/api/dogs/offline/', '/api/groom-sessions/?unassigned=1']:
                self.assertIn(client.get(url).status_code, (401, 403))
            self.assertIn(client.post(f"/api/groom-sessions/{visit['id']}/assign/",
                          {'dog': self.alice_dog.pk}).status_code, (401, 403))
        self.assertEqual(self.staff_client.get('/api/groom-reports/').data['count'], 0)
        self.staff_client.post(f"/api/groom-sessions/{visit['id']}/assign/", {'dog': self.alice_dog.pk})
        reports = self.alice_client.get('/api/groom-reports/').data['results']
        self.assertEqual(len(reports), 1)
        self.assertNotIn('health_check_notes', reports[0])
        self.assertEqual(self.bob_client.get('/api/groom-reports/').data['count'], 0)

    def test_blank_walk_in_and_wrong_appointment_refused(self):
        self.assertEqual(self.walk_in(walk_in_name=' ').status_code, 400)
        appt = Appointment.objects.create(dog=self.bob_dog, start_at=timezone.now())
        self.assertEqual(self.walk_in(appointment=appt.pk).status_code, 400)
        self.assertEqual(self.walk_in(dog=self.alice_dog.pk, appointment=appt.pk).status_code, 400)
        self.assertFalse(GroomSession.objects.exists())

    def test_upload_retry_returns_same_visit_and_does_not_reapply_defaults(self):
        reference = str(uuid4())
        result = self.walk_in(dog=self.alice_dog.pk, apply_to_dog=True, client_reference=reference)
        self.assertEqual(result.status_code, 201, result.data)
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.groom_minutes, 15)
        self.alice_dog.groom_minutes = 120
        self.alice_dog.save()
        replay = self.walk_in(dog=self.alice_dog.pk, client_reference=reference, apply_to_dog=True)
        self.assertEqual(replay.status_code, 200, replay.data)
        self.assertEqual(replay.data['id'], result.data['id'])
        self.assertEqual(GroomSession.objects.count(), 1)
        self.assertEqual(PhaseTiming.objects.count(), 1)
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.groom_minutes, 120)
        self.assertEqual(self.staff_client.patch(f"/api/groom-sessions/{result.data['id']}/",
                         {'client_reference': str(uuid4())}).status_code, 400)

    def test_failed_apply_rolls_back_entire_visit(self):
        response = self.walk_in(apply_to_dog=True)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(GroomSession.objects.count(), 0)
        self.assertEqual(PhaseTiming.objects.count(), 0)

    def test_offline_snapshot_is_complete_and_contains_private_notes_only_for_staff(self):
        self.alice_dog.is_active = False
        self.alice_dog.save()
        response = self.staff_client.get('/api/dogs/offline/?page_size=1&search=nothing')
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(len(response.data['dogs']), 2)
        self.assertEqual(len(response.data['profiles']), 2)
        profile = next(d for d in response.data['profiles'] if d['id'] == self.alice_dog.pk)
        self.assertEqual(profile['temperament_notes'], 'Muzzle for nails.')
        self.assertEqual(profile['client_detail']['notes'], 'Always late.')
        self.assertIn('private', response['Cache-Control'])

    def test_owner_fields_are_independent_and_existing_text_survives(self):
        self.alice_dog.owner_grooming = 'Brush twice weekly; owner discussed a round head'
        self.alice_dog.save()
        result = self.staff_client.patch(f'/api/dogs/{self.alice_dog.pk}/',
                                        {'groom_expectations': 'Round head, short feet'}, format='json')
        self.assertEqual(result.status_code, 200)
        self.alice_dog.refresh_from_db()
        self.assertEqual(self.alice_dog.owner_grooming, 'Brush twice weekly; owner discussed a round head')
        self.assertEqual(self.alice_dog.groom_expectations, 'Round head, short feet')
        own = self.alice_client.get(f'/api/dogs/{self.alice_dog.pk}/').data
        self.assertEqual(own['groom_expectations'], 'Round head, short feet')
        self.assertEqual(self.bob_client.get(f'/api/dogs/{self.alice_dog.pk}/').status_code, 404)

    def test_categories_validate_and_stay_private(self):
        for category, _ in BlockedTime.Category.choices:
            result = self.staff_client.post('/api/blocked-times/', {
                'start_at': timezone.now().isoformat(),
                'end_at': (timezone.now() + timedelta(hours=1)).isoformat(),
                'category': category, 'notes': 'Private reason',
            }, format='json')
            self.assertEqual(result.status_code, 201, result.data)
            client_row = self.alice_client.get(f"/api/blocked-times/{result.data['id']}/").data
            self.assertNotIn('category', client_row)
            self.assertNotIn('notes', client_row)
        invalid = self.staff_client.patch(f"/api/blocked-times/{result.data['id']}/",
                                          {'category': 'INVENTED'}, format='json')
        self.assertEqual(invalid.status_code, 400)

    def test_invoice_filter_is_scoped_to_owner_and_respects_visibility(self):
        alice = Invoice.objects.create(client=self.alice)
        Invoice.objects.create(client=self.bob)
        result = self.staff_client.get(f'/api/invoices/?client={self.alice.pk}')
        self.assertEqual([i['id'] for i in result.data['results']], [alice.pk])
        self.assertEqual(self.alice_client.get(f'/api/invoices/?client={self.alice.pk}').data['count'], 0)
