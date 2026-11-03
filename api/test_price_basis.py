"""A dog's own price can be per groom or per hour.

Jess: "can we add a drop down of 'Per Groom' or 'Per Hour' please?"
"""
from datetime import timedelta
from decimal import Decimal
from uuid import uuid4

from django.test import override_settings
from django.utils import timezone

from .models import Appointment, Dog, Invoice, PriceBasis, Service
from .tests import BaseAPITestCase


@override_settings(PASSWORD_HASHERS=['django.contrib.auth.hashers.MD5PasswordHasher'])
class PriceBasisTests(BaseAPITestCase):
    def make_hourly(self, rate='30.00', minutes=240):
        self.alice_dog.price = Decimal(rate)
        self.alice_dog.price_basis = PriceBasis.PER_HOUR
        self.alice_dog.groom_minutes = minutes
        self.alice_dog.save()
        return self.alice_dog

    def test_existing_prices_stay_per_groom(self):
        # Every price stored before the dropdown was a whole-groom price.
        dog = Dog.objects.create(client=self.alice, name='Pip', price=Decimal('55'))
        self.assertEqual(dog.price_basis, PriceBasis.PER_GROOM)
        self.assertEqual(dog.groom_price, Decimal('55'))

    def test_hourly_rate_is_charged_pro_rata_for_the_groom(self):
        dog = self.make_hourly('30.00', minutes=90)
        self.assertTrue(dog.is_priced_per_hour)
        self.assertEqual(dog.effective_price, Decimal('30.00'))
        self.assertEqual(dog.groom_price, Decimal('45.00'))

    def test_basis_is_ignored_without_a_price_of_its_own(self):
        # The breed grid is per groom; "per hour" on a blank price must not
        # turn the breed's groom price into an hourly rate.
        self.alice_dog.price = None
        self.alice_dog.price_basis = PriceBasis.PER_HOUR
        self.alice_dog.save()
        self.assertFalse(self.alice_dog.is_priced_per_hour)
        self.assertEqual(self.alice_dog.groom_price, self.breed.avg_price)

    def test_booking_quotes_the_whole_groom_not_the_rate(self):
        self.make_hourly('30.00', minutes=240)
        response = self.staff_client.post('/api/appointments/', {
            'dog': self.alice_dog.pk,
            'start_at': (timezone.now() + timedelta(days=2)).isoformat(),
        }, format='json')
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(Decimal(response.data['price_quoted']), Decimal('120.00'))

    def test_full_groom_service_quotes_the_whole_groom(self):
        self.make_hourly('30.00', minutes=240)
        service = Service.objects.create(code='FULL-T', name='Full Groom', takes_dog_defaults=True)
        response = self.staff_client.post('/api/appointments/', {
            'dog': self.alice_dog.pk, 'services': [service.pk],
            'start_at': (timezone.now() + timedelta(days=2)).isoformat(),
        }, format='json')
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(Decimal(response.data['price_quoted']), Decimal('120.00'))
        invoice = self.staff_client.post(
            '/api/invoices/from_appointment/', {'appointment': response.data['id']}, format='json',
        )
        self.assertIn(invoice.status_code, (200, 201), invoice.data)
        self.assertEqual(Invoice.objects.get().total, Decimal('120.00'))

    def test_unbooked_groom_is_invoiced_on_the_time_it_took(self):
        self.make_hourly('30.00', minutes=240)
        response = self.staff_client.post('/api/groom-sessions/', {
            'dog': self.alice_dog.pk,
            'started_at': (timezone.now() - timedelta(hours=3)).isoformat(),
            'finished_at': timezone.now().isoformat(),
            'client_reference': str(uuid4()), 'complete_card': True,
            'recorded_minutes': 150, 'usual_groom_done': True,
        }, format='json')
        self.assertEqual(response.status_code, 201, response.data)
        self.assertFalse(Appointment.objects.exists())
        invoice = Invoice.objects.get()
        self.assertEqual(invoice.total, Decimal('75.00'))
        self.assertIn('150 min at £30.00/hour', invoice.lines.get().description)

    def test_api_round_trips_the_basis(self):
        url = f'/api/dogs/{self.alice_dog.pk}/'
        response = self.staff_client.patch(
            url, {'price': '30.00', 'price_basis': 'HOUR', 'groom_minutes': 120}, format='json',
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['price_basis'], 'HOUR')
        self.assertEqual(Decimal(response.data['price_effective']), Decimal('30.00'))
        self.assertEqual(Decimal(response.data['groom_price']), Decimal('60.00'))
        self.assertTrue(response.data['price_per_hour'])
        row = next(d for d in self.staff_client.get('/api/dogs/').data['results']
                   if d['id'] == self.alice_dog.pk)
        self.assertTrue(row['price_per_hour'])
        bad = self.staff_client.patch(url, {'price_basis': 'DAY'}, format='json')
        self.assertEqual(bad.status_code, 400)

    def test_client_cannot_change_the_basis(self):
        response = self.alice_client.patch(
            f'/api/dogs/{self.alice_dog.pk}/', {'price_basis': 'HOUR'}, format='json',
        )
        self.assertEqual(response.status_code, 403)
