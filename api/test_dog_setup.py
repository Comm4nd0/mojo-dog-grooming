"""Adding an unknown dog must not record an assessment nobody made."""
from datetime import timedelta

from django.test import override_settings
from django.utils import timezone

from .models import Appointment, Dog, GroomSession, Temperament, TemperamentGrade
from .scheduling import temperament_warning
from .tests import BaseAPITestCase


@override_settings(PASSWORD_HASHERS=['django.contrib.auth.hashers.MD5PasswordHasher'])
class DogSetupTests(BaseAPITestCase):
    def test_new_dogs_are_unassessed_in_json_and_multipart(self):
        for format in ('json', 'multipart'):
            with self.subTest(format=format):
                response = self.staff_client.post('/api/dogs/', {
                    'client': self.alice.pk, 'name': 'First visit',
                }, format=format)
                self.assertEqual(response.status_code, 201, response.data)
                self.assertEqual(response.data['temperament'], '')
                self.assertEqual(response.data['temperament_display'], 'Not assessed')
                self.assertIsNone(response.data['requires_restraint'])
                dog = Dog.objects.get(pk=response.data['id'])
                self.assertEqual(dog.temperament, '')
                self.assertIsNone(dog.requires_restraint)

    def test_model_default_also_covers_admin_and_intake_creation(self):
        dog = Dog.objects.create(client=self.alice, name='New arrival')
        self.assertEqual(dog.temperament, '')
        self.assertIsNone(dog.requires_restraint)

    def test_restraint_can_be_assessed_or_reset_without_changing_grade(self):
        for value in (True, False, None):
            response = self.staff_client.patch(f'/api/dogs/{self.alice_dog.pk}/', {
                'requires_restraint': value,
            }, format='json')
            self.assertEqual(response.status_code, 200, response.data)
            self.assertIs(response.data['requires_restraint'], value)
            self.assertEqual(response.data['temperament'], Temperament.FEISTY)

    def test_omitted_assessment_and_existing_preferences_survive_an_edit(self):
        self.alice_dog.requires_restraint = False
        self.alice_dog.temperament = Temperament.EASY
        self.alice_dog.pref_body = 'Previous groomer used a long comb'
        self.alice_dog.save()
        for format in ('json', 'multipart'):
            response = self.staff_client.patch(f'/api/dogs/{self.alice_dog.pk}/', {
                'name': 'Biscuit renamed',
            }, format=format)
            self.assertEqual(response.status_code, 200, response.data)
            self.assertEqual(response.data['temperament'], Temperament.EASY)
            self.assertIs(response.data['requires_restraint'], False)
            self.assertEqual(response.data['pref_body'], 'Previous groomer used a long comb')

    def test_grade_can_be_explicitly_cleared_but_invalid_codes_are_rejected(self):
        url = f'/api/dogs/{self.alice_dog.pk}/'
        response = self.staff_client.patch(url, {'temperament': ''}, format='json')
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['temperament_display'], 'Not assessed')
        self.assertEqual(self.staff_client.patch(url, {'temperament': 'MADE_UP'},
                                               format='json').status_code, 400)

    def test_unassessed_is_visible_to_staff_across_diary_list_and_offline_snapshot(self):
        dog = self.bob_dog
        appointment = Appointment.objects.create(dog=dog, start_at=timezone.now())
        listings = self.staff_client.get('/api/dogs/').data['results']
        row = next(row for row in listings if row['id'] == dog.pk)
        self.assertEqual(row['temperament'], '')
        self.assertEqual(row['temperament_display'], 'Not assessed')
        diary = self.staff_client.get(f'/api/appointments/{appointment.pk}/').data
        self.assertEqual(diary['dog_temperament'], '')
        self.assertEqual(diary['dog_temperament_display'], 'Not assessed')
        snapshot = self.staff_client.get('/api/dogs/offline/').data
        saved = next(row for row in snapshot['profiles'] if row['id'] == dog.pk)
        self.assertEqual(saved['temperament'], '')
        self.assertIsNone(saved['requires_restraint'])

    def test_unknown_assessment_remains_hidden_and_unwritable_to_owner(self):
        dog = self.bob_dog
        appointment = Appointment.objects.create(dog=dog, start_at=timezone.now())
        for row in (
            self.bob_client.get(f'/api/dogs/{dog.pk}/').data,
            self.bob_client.get('/api/dogs/').data['results'][0],
        ):
            for key in ('temperament', 'temperament_display', 'requires_restraint', 'temperament_notes'):
                self.assertNotIn(key, row)
        diary = self.bob_client.get(f'/api/appointments/{appointment.pk}/').data
        self.assertNotIn('dog_temperament_display', diary)
        self.assertEqual(self.bob_client.patch(f'/api/dogs/{dog.pk}/', {
            'temperament': Temperament.EASY, 'requires_restraint': False,
        }, format='json').status_code, 403)

    def test_unknown_is_not_counted_as_easy_and_does_not_block_booking(self):
        TemperamentGrade.objects.filter(temperament=Temperament.EASY).update(max_per_day=0)
        start = timezone.now() + timedelta(days=1)
        self.assertIsNone(temperament_warning(self.bob_dog, start))
        response = self.staff_client.post('/api/appointments/', {
            'dog': self.bob_dog.pk, 'start_at': start.isoformat(),
        }, format='json')
        self.assertEqual(response.status_code, 201, response.data)

    def test_first_groom_observation_does_not_silently_assess_the_profile(self):
        GroomSession.objects.create(dog=self.bob_dog, temperament_observed=Temperament.BITEY)
        self.bob_dog.refresh_from_db()
        self.assertEqual(self.bob_dog.temperament, '')
        response = self.staff_client.patch(f'/api/dogs/{self.bob_dog.pk}/', {
            'temperament': Temperament.BITEY, 'requires_restraint': True,
            'temperament_notes': 'Use a muzzle for nails',
        }, format='json')
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['temperament'], Temperament.BITEY)
        self.assertIs(response.data['requires_restraint'], True)
