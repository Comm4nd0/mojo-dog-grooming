"""Prepare one reviewable invoice after a timed groom card is finished."""
from decimal import Decimal

from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from .models import Appointment, GroomSession, Invoice, InvoiceLine, ServiceType


def invoice_for_appointment(appointment):
    """Include manually raised invoices, even those predating the source link."""
    return Invoice.objects.filter(
        Q(source_appointment=appointment) | Q(lines__appointment=appointment),
    ).exclude(status=Invoice.Status.VOID).distinct().order_by('id').first()


@transaction.atomic
def prepare_groom_invoice(session, *, complete_card=False):
    # Lock only the session: nullable joins cannot be locked on PostgreSQL.
    current = GroomSession.objects.select_for_update().get(pk=session.pk)
    if complete_card and current.invoice_state == GroomSession.InvoiceState.AWAITING_CARD:
        current.invoice_state = GroomSession.InvoiceState.READY
        GroomSession.objects.filter(pk=current.pk).update(invoice_state=current.invoice_state)
    if (current.invoice_state == GroomSession.InvoiceState.READY
            and current.dog_id is not None and current.finished_at is not None
            and current.visit_type == ServiceType.GROOM
            and (current.total_seconds > 0 or (current.recorded_minutes or 0) > 0)):
        dog = current.dog
        appointment = None
        invoice = None
        if current.appointment_id:
            # Also serializes two cards for the same booking and manual
            # from_appointment creation. A retry must not create another bill.
            appointment = Appointment.objects.select_for_update().get(pk=current.appointment_id)
            invoice = invoice_for_appointment(appointment)
        if invoice is None:
            if appointment is not None:
                # The quote is a historical agreement, possibly adjusted by
                # Jess. Today's service or breed price must not replace it.
                price = appointment.price_quoted
            elif dog.price is not None or dog.breed_id:
                price = dog.effective_price
            else:
                price = None
            date = timezone.localtime(current.started_at).date()
            description = f'Full groom — {dog.name}, {date:%d %b %Y}'
            invoice = Invoice.objects.create(
                client=dog.client, source_appointment=appointment, auto_generated=True,
                created_by=current.created_by, issue_date=timezone.localdate(),
                notes=f'Price needed: {description}.' if price is None else '',
            )
            if price is not None:
                InvoiceLine.objects.create(
                    invoice=invoice, appointment=appointment, description=description[:200],
                    quantity=Decimal('1.00'), unit_price=price,
                )
        current.invoice = invoice
        current.invoice_state = GroomSession.InvoiceState.DONE
        # DONE survives deleting a draft, so an intentional deletion is not
        # undone by the next card edit or an offline replay.
        GroomSession.objects.filter(pk=current.pk).update(
            invoice=invoice, invoice_state=current.invoice_state,
        )
    session.invoice_id = current.invoice_id
    session.invoice_state = current.invoice_state
    session._state.fields_cache.pop('invoice', None)
    return session
