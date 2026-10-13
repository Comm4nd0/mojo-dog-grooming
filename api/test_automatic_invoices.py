"""Finishing a timed card prepares one draft, including delayed offline uploads."""
from datetime import timedelta
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from threading import Barrier
from uuid import uuid4

from django.contrib.auth.models import User
from django.db import connections
from django.test import TransactionTestCase, override_settings, skipUnlessDBFeature
from django.utils import timezone

from .models import AppSettings, Appointment, Client, Dog, GroomSession, Invoice
from .tests import BaseAPITestCase


@override_settings(PASSWORD_HASHERS=['django.contrib.auth.hashers.MD5PasswordHasher'])
class AutomaticGroomInvoiceTests(BaseAPITestCase):
    def finish(self, **overrides):
        payload = {
            'dog': self.alice_dog.pk,
            'started_at': (timezone.now() - timedelta(hours=1)).isoformat(),
            'finished_at': timezone.now().isoformat(),
            'client_reference': str(uuid4()), 'complete_card': True,
            'timings': [{'phase': 'WASH', 'duration_seconds': 600}],
            'health_check_notes': 'Private handling detail', 'usual_groom_done': True,
        }
        payload.update(overrides)
        return self.staff_client.post('/api/groom-sessions/', payload, format='json')

    def test_quote_is_preserved_and_card_creates_private_draft(self):
        start = timezone.now() - timedelta(hours=1)
        appointment = Appointment.objects.create(dog=self.alice_dog, start_at=start, price_quoted=Decimal('37.50'))
        response = self.finish(appointment=appointment.pk, started_at=start.isoformat())
        self.assertEqual(response.status_code, 201, response.data)
        invoice = Invoice.objects.get()
        self.assertEqual(invoice.total, Decimal('37.50'))
        self.assertEqual(invoice.status, Invoice.Status.DRAFT)
        self.assertEqual(invoice.client, self.alice)
        self.assertEqual(invoice.source_appointment, appointment)
        self.assertEqual(response.data['invoice'], invoice.pk)
        self.assertEqual(response.data['invoice_number'], invoice.number)
        self.assertIsNone(invoice.sent_at)
        self.assertFalse(invoice.payments.exists())
        self.assertNotIn('Private', invoice.notes + invoice.lines.get().description)
        settings = AppSettings.get(); settings.invoicing_visible_to_clients = True; settings.save()
        self.assertEqual(self.alice_client.get('/api/invoices/').data['count'], 0)
        self.assertEqual(self.alice_client.get(f'/api/invoices/{invoice.pk}/').status_code, 404)
        invoice.status = Invoice.Status.VOID; invoice.save()
        self.assertEqual(self.alice_client.get('/api/invoices/').data['count'], 0)
        invoice.status = Invoice.Status.DRAFT; invoice.save()
        self.assertEqual(self.staff_client.post(f'/api/invoices/{invoice.pk}/mark_sent/').status_code, 200)
        self.assertEqual(self.alice_client.get('/api/invoices/').data['count'], 1)
        self.assertEqual(self.bob_client.get('/api/invoices/').data['count'], 0)
        report = self.alice_client.get(f"/api/groom-reports/{response.data['id']}/").data
        self.assertNotIn('invoice', report)
        self.assertNotIn('invoice_state', report)

    def test_waits_for_card_and_never_reprices_on_edits_or_retries(self):
        reference = str(uuid4())
        visit = self.finish(client_reference=reference, complete_card=False).data
        self.assertEqual(visit['invoice_state'], 'AWAITING_CARD')
        self.assertFalse(Invoice.objects.exists())
        url = f"/api/groom-sessions/{visit['id']}/"
        completed = self.staff_client.patch(url, {'complete_card': True}, format='json')
        self.assertEqual(completed.status_code, 200, completed.data)
        invoice = Invoice.objects.get()
        old_price = invoice.total
        self.alice_dog.price = Decimal('999'); self.alice_dog.save()
        self.staff_client.patch(url, {'complete_card': True, 'notes': 'Correction'}, format='json')
        retry = self.finish(client_reference=reference)
        self.assertEqual(retry.status_code, 200)
        self.assertEqual(retry.data['invoice'], invoice.pk)
        self.assertEqual(Invoice.objects.count(), 1)
        self.assertEqual(Invoice.objects.get().total, old_price)

    def test_walk_in_waits_for_assignment_then_uses_dog_price(self):
        visit = self.finish(dog=None, walk_in_name='New spaniel').data
        self.assertFalse(Invoice.objects.exists())
        self.alice_dog.price = Decimal('61'); self.alice_dog.save()
        url = f"/api/groom-sessions/{visit['id']}/assign/"
        response = self.staff_client.post(url, {'dog': self.alice_dog.pk})
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(Invoice.objects.get().total, Decimal('61'))
        self.staff_client.post(url, {'dog': self.alice_dog.pk})
        self.assertEqual(Invoice.objects.count(), 1)

    def test_missing_price_stays_blank_and_cannot_be_marked_sent_or_paid(self):
        self.alice_dog.breed = None; self.alice_dog.price = None; self.alice_dog.save()
        response = self.finish()
        self.assertEqual(response.status_code, 201, response.data)
        invoice = Invoice.objects.get()
        self.assertFalse(invoice.lines.exists())
        self.assertIn('Price needed', invoice.notes)
        for action in ('mark_sent', 'mark_paid'):
            self.assertEqual(self.staff_client.post(f'/api/invoices/{invoice.pk}/{action}/').status_code, 400)
        self.assertEqual(self.staff_client.patch(f'/api/invoices/{invoice.pk}/', {'status': 'SENT'}).status_code, 400)
        fixed = self.staff_client.patch(f'/api/invoices/{invoice.pk}/', {
            'lines': [{'description': 'Full groom', 'unit_price': '45.00', 'quantity': '1.00'}],
            'notes': '',
        }, format='json')
        self.assertEqual(fixed.status_code, 200, fixed.data)
        self.assertEqual(self.staff_client.post(f'/api/invoices/{invoice.pk}/mark_sent/').status_code, 200)

    def test_explicit_zero_quote_remains_zero(self):
        appointment = Appointment.objects.create(dog=self.alice_dog, start_at=timezone.now(), price_quoted=0)
        self.finish(appointment=appointment.pk)
        self.assertEqual(Invoice.objects.get().lines.get().unit_price, Decimal('0'))

    def test_unpriced_booking_does_not_fall_back_to_breed_price(self):
        appointment = Appointment.objects.create(dog=self.alice_dog, start_at=timezone.now())
        Appointment.objects.filter(pk=appointment.pk).update(price_quoted=None)
        self.finish(appointment=appointment.pk)
        self.assertFalse(Invoice.objects.get().lines.exists())

    def test_existing_manual_invoice_and_multiple_cards_do_not_double_bill(self):
        appointment = Appointment.objects.create(dog=self.alice_dog, start_at=timezone.now())
        manual = self.staff_client.post('/api/invoices/from_appointment/', {'appointment': appointment.pk})
        invoice_id = manual.data['invoice']['id']
        one = self.finish(appointment=appointment.pk)
        two = self.finish(appointment=appointment.pk)
        self.assertEqual(one.data['invoice'], invoice_id)
        self.assertEqual(two.data['invoice'], invoice_id)
        repeated = self.staff_client.post('/api/invoices/from_appointment/', {'appointment': appointment.pk})
        self.assertEqual(repeated.data['invoice']['id'], invoice_id)
        self.assertEqual(Invoice.objects.count(), 1)

    def test_deleting_or_voiding_draft_does_not_regenerate_it(self):
        visit = self.finish().data
        invoice = Invoice.objects.get()
        self.assertEqual(self.staff_client.delete(f'/api/invoices/{invoice.pk}/').status_code, 204)
        self.staff_client.patch(f"/api/groom-sessions/{visit['id']}/", {'complete_card': True}, format='json')
        self.assertFalse(Invoice.objects.exists())

        another = self.finish().data
        invoice = Invoice.objects.get(); invoice.status = Invoice.Status.VOID; invoice.save()
        self.staff_client.patch(f"/api/groom-sessions/{another['id']}/", {'complete_card': True}, format='json')
        self.assertEqual(Invoice.objects.count(), 1)

    def test_historical_untimed_and_unfinished_cards_are_not_invoiced(self):
        old = GroomSession.objects.create(dog=self.alice_dog, recorded_minutes=30, finished_at=timezone.now())
        self.staff_client.patch(f'/api/groom-sessions/{old.pk}/', {'complete_card': True}, format='json')
        self.assertEqual(self.finish(timings=[]).status_code, 201)
        self.assertEqual(self.finish(finished_at=None).status_code, 201)
        self.assertEqual(self.finish(visit_type='NAILS', nails_done=True).status_code, 201)
        self.assertFalse(Invoice.objects.exists())

    def test_client_cannot_trigger_completion_or_spoof_invoice_fields(self):
        visit = self.finish(complete_card=False).data
        url = f"/api/groom-sessions/{visit['id']}/"
        self.assertEqual(self.alice_client.patch(url, {'complete_card': True}).status_code, 403)
        self.staff_client.patch(url, {'invoice_state': 'DONE', 'invoice': 1234}, format='json')
        self.assertEqual(GroomSession.objects.get().invoice_state, 'AWAITING_CARD')
        self.assertFalse(Invoice.objects.exists())


@override_settings(PASSWORD_HASHERS=['django.contrib.auth.hashers.MD5PasswordHasher'])
class ConcurrentGroomInvoiceTests(TransactionTestCase):
    @skipUnlessDBFeature('has_select_for_update')
    def test_two_finished_cards_for_one_booking_prepare_one_invoice(self):
        from .invoicing import prepare_groom_invoice
        staff = User.objects.create_user('jess', is_staff=True)
        client = Client.objects.create(uid='AUTO-001', first_name='Alice')
        dog = Dog.objects.create(client=client, name='Bunny', price=Decimal('50'))
        appointment = Appointment.objects.create(dog=dog, start_at=timezone.now())
        visits = [GroomSession.objects.create(
            dog=dog, appointment=appointment, created_by=staff, recorded_minutes=20,
            finished_at=timezone.now(), invoice_state=GroomSession.InvoiceState.READY,
        ) for _ in range(2)]
        barrier = Barrier(2)

        def prepare(pk):
            try:
                visit = GroomSession.objects.get(pk=pk)
                barrier.wait(timeout=10)
                return prepare_groom_invoice(visit).invoice_id
            finally:
                connections.close_all()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(prepare, [visit.pk for visit in visits]))
        self.assertEqual(results[0], results[1])
        self.assertEqual(Invoice.objects.count(), 1)
        self.assertEqual(GroomSession.objects.filter(invoice_state='DONE').count(), 2)
