"""Booking checks.

Every rule in here produces a *warning*, never a refusal. Jess's notes are
explicit that the app should "warn when exceeding temperament booking limits,
but don't prevent booking", and the same principle applies to opening hours —
she regularly works outside them. The app shows these in a confirm dialog and
the user decides.
"""

from datetime import datetime, time, timedelta

from django.db.models import OuterRef, Subquery
from django.utils import timezone

from .models import (
    Appointment,
    AppointmentStatus,
    AppSettings,
    ClosureDay,
    Dog,
    FALLBACK_NAIL_VISIT_MINUTES,
    OpeningHours,
    ServiceType,
    TemperamentGrade,
    temperament_label,
    resolve_slot,
)


def _local_date(dt):
    return timezone.localtime(dt).date()


def temperament_warning(dog, start_at, exclude_appointment=None):
    """Warn when this booking takes the day over the limit for its temperament."""
    limit = TemperamentGrade.objects.filter(temperament=dog.temperament).first()
    if limit is None or limit.max_per_day is None:
        return None

    day = _local_date(start_at)
    same_day = Appointment.objects.filter(
        dog__temperament=dog.temperament,
        status__in=Appointment.ACTIVE_STATUSES,
        start_at__date=day,
    )
    if exclude_appointment is not None:
        same_day = same_day.exclude(pk=exclude_appointment.pk)

    existing = same_day.count()
    if existing + 1 > limit.max_per_day:
        # Jess's own wording for the grade, not the frozen enum label.
        label = temperament_label(dog.temperament).lower()
        return {
            'code': 'temperament_limit',
            'message': (
                f'This would be {existing + 1} {label} dogs on '
                f'{day:%a %d %b} — your limit is {limit.max_per_day} per day.'
            ),
            'detail': {
                'temperament': dog.temperament,
                'existing': existing,
                'limit': limit.max_per_day,
                'date': day.isoformat(),
            },
        }
    return None


def opening_hours_warning(start_at, end_at):
    """Warn when the slot falls outside normal working hours."""
    local_start = timezone.localtime(start_at)
    local_end = timezone.localtime(end_at)
    day = local_start.date()

    closure = ClosureDay.objects.filter(date=day).first()
    if closure is not None:
        return {
            'code': 'closure_day',
            'message': f'{day:%a %d %b} is marked closed{f" ({closure.reason})" if closure.reason else ""}.',
            'detail': {'date': day.isoformat(), 'reason': closure.reason},
        }

    hours = OpeningHours.objects.filter(weekday=local_start.weekday()).first()
    if hours is None:
        return None
    if hours.is_closed or not hours.open_time or not hours.close_time:
        return {
            'code': 'outside_opening_hours',
            'message': f'You are not normally open on a {local_start:%A}.',
            'detail': {'date': day.isoformat()},
        }
    if local_start.time() < hours.open_time or local_end.time() > hours.close_time:
        return {
            'code': 'outside_opening_hours',
            'message': (
                f'{local_start:%H:%M}–{local_end:%H:%M} falls outside your '
                f'{local_start:%A} hours of {hours.open_time:%H:%M}–{hours.close_time:%H:%M}.'
            ),
            'detail': {
                'date': day.isoformat(),
                'open_time': hours.open_time.isoformat(),
                'close_time': hours.close_time.isoformat(),
            },
        }
    return None


def overlap_warning(start_at, end_at, exclude_appointment=None):
    """Warn when the slot collides with another booking."""
    clashes = Appointment.objects.filter(
        status__in=Appointment.ACTIVE_STATUSES,
        start_at__lt=end_at,
        end_at__gt=start_at,
    ).select_related('dog')
    if exclude_appointment is not None:
        clashes = clashes.exclude(pk=exclude_appointment.pk)

    clash = clashes.first()
    if clash is None:
        return None
    return {
        'code': 'overlap',
        'message': (
            f'This overlaps {clash.dog.name} at '
            f'{timezone.localtime(clash.start_at):%H:%M}.'
        ),
        'detail': {'appointment_id': clash.pk, 'dog_name': clash.dog.name},
    }


def unpriced_service_warning(service_type, services=()):
    """Anything in this booking that has no price set yet.

    A warning rather than a refusal, like everything else here — Jess can take
    the booking and sort the price out after. It exists because the figures are
    null on purpose: her price list covers full grooms only, so the app has
    nothing to fall back on for anything else and says so rather than
    inventing one.

    Named services take precedence when there are any, because they are the
    more specific answer to "what is this booking".
    """
    unpriced = [service.name for service in services if _has_no_price(service)]
    if unpriced:
        return {
            'code': 'service_not_priced',
            'message': (
                f'{_join(unpriced)} {"have" if len(unpriced) > 1 else "has"} no '
                'price set yet, so this booking is unquoted. Add it in '
                'Settings, Services.'
            ),
            'detail': {'services': unpriced},
        }

    if services:
        # Every chosen service is priced; the category default is irrelevant.
        return None

    if service_type != ServiceType.NAILS_FLEAS_TICKS:
        return None
    settings_row = AppSettings.get()
    if settings_row.nail_visit_price is not None and settings_row.nail_visit_minutes:
        return None
    missing = [
        label for label, value in (
            ('a price', settings_row.nail_visit_price),
            ('a length', settings_row.nail_visit_minutes),
        ) if not value
    ]
    return {
        'code': 'service_not_priced',
        'message': (
            f'Nails, fleas and ticks has no {" or ".join(missing)} set yet. '
            'Add it in Settings.'
        ),
        'detail': {'service_type': service_type},
    }


def _has_no_price(service):
    """A full groom is priced off the dog, so it is never "unpriced"."""
    return not service.takes_dog_defaults and service.default_price is None


def _join(names):
    if len(names) == 1:
        return names[0]
    return f'{", ".join(names[:-1])} and {names[-1]}'


def service_category_warning(service_type, services=()):
    """A groom booking carrying only nails-card services, or the reverse.

    Almost always a mis-tap, and it matters: `service_type` decides which of
    Jess's two record cards she is handed afterwards. A warning, never a
    block — she may well have a reason.
    """
    if not services:
        return None
    categories = {service.category for service in services}
    if service_type in categories:
        return None
    other = ', '.join(sorted(categories))
    return {
        'code': 'service_category_mismatch',
        'message': (
            f'This is booked as {ServiceType(service_type).label.lower()}, but '
            f'everything on it is {other.lower()}. You will get the wrong '
            'record card to fill in afterwards.'
        ),
        'detail': {'service_type': service_type, 'categories': sorted(categories)},
    }


#: Slots are offered on the quarter hour — "10:00" and "10:15", never
#: "10:07". Jess reads these off a screen and writes them on a card.
SLOT_GRANULARITY_MINUTES = 15


def _ceil_to(minutes, granularity):
    return ((minutes + granularity - 1) // granularity) * granularity


def next_available_slots(
    dog,
    service_type=ServiceType.GROOM,
    services=(),
    minutes=None,
    from_date=None,
    count=3,
    max_per_day=2,
    horizon_days=60,
):
    """Walk forward and find the first free gaps long enough for this booking.

    Jess asked for an "option for next available appointment". This is the
    answer to it: her opening hours, minus her closure days, minus what is
    already booked, minus a gap either side.

    That gap is ``AppSettings.booking_slot_buffer_minutes``, which has existed
    since the first version and until now was **read by no code at all**. It
    defaults to 0, so nothing changes until she sets one — and it is surfaced
    in Settings at the same time, because a setting no screen can reach is
    exactly how it ended up dead.

    Three queries regardless of how far ahead it looks.

    Returns ``(slots, exhausted, reason)``. ``reason`` is
    ``'no_opening_hours'`` when the table is empty, which matters: with no
    rows every day is skipped and the honest answer is "set your hours up",
    not the "you are fully booked" that an empty list would imply.
    """
    if minutes is None:
        minutes, _, _ = resolve_slot(dog, service_type, services)

    hours = {row.weekday: row for row in OpeningHours.objects.all()}
    if not hours:
        return [], False, 'no_opening_hours'

    today = timezone.localdate()
    start_date = from_date or today
    if start_date < today:
        start_date = today
    end_date = start_date + timedelta(days=horizon_days)

    closures = set(
        ClosureDay.objects.filter(date__gte=start_date, date__lte=end_date)
        .values_list('date', flat=True)
    )

    buffer_minutes = AppSettings.get().booking_slot_buffer_minutes or 0

    booked = {}
    existing = (
        Appointment.objects.filter(
            status__in=Appointment.ACTIVE_STATUSES,
            start_at__date__gte=start_date,
            start_at__date__lte=end_date,
        )
        .order_by('start_at')
    )
    for appointment in existing:
        local_start = timezone.localtime(appointment.start_at)
        local_end = timezone.localtime(appointment.end_at)
        booked.setdefault(local_start.date(), []).append(
            (
                local_start.hour * 60 + local_start.minute,
                local_end.hour * 60 + local_end.minute,
            )
        )

    now = timezone.localtime()
    now_minutes = now.hour * 60 + now.minute

    slots = []
    day = start_date
    while day <= end_date and len(slots) < count:
        row = hours.get(day.weekday())
        if day in closures or row is None or row.is_closed:
            day += timedelta(days=1)
            continue
        if not row.open_time or not row.close_time:
            day += timedelta(days=1)
            continue

        open_minutes = row.open_time.hour * 60 + row.open_time.minute
        close_minutes = row.close_time.hour * 60 + row.close_time.minute

        cursor = open_minutes
        if day == today:
            # Never offer a slot in the past, and give an hour's notice.
            cursor = max(cursor, now_minutes + 60)
        cursor = _ceil_to(cursor, SLOT_GRANULARITY_MINUTES)

        emitted_today = 0
        for busy_from, busy_to in sorted(booked.get(day, [])):
            gap_end = busy_from - buffer_minutes
            while (
                cursor + minutes <= gap_end
                and emitted_today < max_per_day
                and len(slots) < count
            ):
                slots.append(_slot(day, cursor, minutes))
                emitted_today += 1
                cursor = _ceil_to(cursor + SLOT_GRANULARITY_MINUTES, SLOT_GRANULARITY_MINUTES)
            cursor = _ceil_to(
                max(cursor, busy_to + buffer_minutes), SLOT_GRANULARITY_MINUTES
            )

        while (
            cursor + minutes <= close_minutes
            and emitted_today < max_per_day
            and len(slots) < count
        ):
            slots.append(_slot(day, cursor, minutes))
            emitted_today += 1
            cursor = _ceil_to(cursor + SLOT_GRANULARITY_MINUTES, SLOT_GRANULARITY_MINUTES)

        day += timedelta(days=1)

    return slots, len(slots) < count, None


def _slot(day, minutes_past_midnight, length):
    """Build an aware datetime for a local wall-clock time on ``day``.

    Combined and *then* made aware, never a UTC instant plus a timedelta: the
    latter silently shifts every slot by an hour across a British clock
    change, and does it for months at a stretch before anyone notices.
    """
    naive = datetime.combine(
        day,
        time(hour=minutes_past_midnight // 60, minute=minutes_past_midnight % 60),
    )
    start = timezone.make_aware(naive, timezone.get_current_timezone())
    return {
        'start_at': start,
        'end_at': start + timedelta(minutes=length),
        'date': day.isoformat(),
        'weekday': day.strftime('%A'),
    }


def booking_warnings(dog, start_at, end_at=None, exclude_appointment=None,
                     service_type=ServiceType.GROOM, services=()):
    """All warnings for a proposed slot, in the order they matter to Jess."""
    services = list(services)
    if end_at is None:
        minutes, _, _ = resolve_slot(dog, service_type, services)
        end_at = start_at + timedelta(minutes=minutes)

    checks = [
        temperament_warning(dog, start_at, exclude_appointment),
        opening_hours_warning(start_at, end_at),
        overlap_warning(start_at, end_at, exclude_appointment),
        service_category_warning(service_type, services),
        unpriced_service_warning(service_type, services),
    ]
    return [warning for warning in checks if warning is not None]


# ── Who is due ─────────────────────────────────────────────────────────

def dogs_due(within_days=14, include_booked=False, include_never_groomed=True, include_ad_hoc=False):
    """Dogs whose next groom is due, most overdue first.

    ``suggested_next_groom`` answers this for one dog on request, which means
    the answer only exists if Jess already suspected it. Rebooking a lapsed
    client is the cheapest work there is and it was resting entirely on her
    remembering, so this does the same sum across the whole book.

    **A dog already in the diary is not on this list.** That is the property
    that makes it a to-do rather than a report: anything with an upcoming
    appointment is going to be seen anyway, and leaving those in would bury the
    handful that actually need a phone call. ``include_booked`` puts them back
    for the rare "who is due this month regardless" question.

    Never-groomed dogs are included and marked, not silently dropped. A new dog
    with no booking is exactly the one most easily forgotten, and its due date
    is genuinely unknown rather than far away — the UI needs to be able to tell
    those apart, so ``due_date`` is None and ``days_overdue`` is None too. They
    sort to the end, since "overdue by 40 days" is a firmer claim than "never
    been in".

    **Ad hoc dogs are left out** (``Dog.is_ad_hoc``, ``include_ad_hoc`` to put
    them back). They have no agreed interval, so "last groom + interval" is a
    deadline nobody set, and they would sit near the top of the list for good.

    **"In the diary" means anything from midnight this morning**, not from this
    second. It used to be ``start_at >= now``, which quietly dropped a dog the
    moment its own appointment started: Jess groomed a dog at ten and found it
    on her overdue list that evening, because the booking was behind her and
    the visit was not marked off yet. A dog seen today is not one to ring.

    Returns plain dicts, not model instances: the caller needs the derived
    figures more than the ORM object, and the queryset already carries
    everything through annotations.
    """
    today = timezone.localdate()

    # Subqueries rather than a per-dog query — this walks the whole book, and
    # the N+1 would be two extra queries per dog.
    last_groom = (
        Appointment.objects
        .filter(dog=OuterRef('pk'), status=AppointmentStatus.COMPLETED)
        .order_by('-start_at')
        .values('start_at')[:1]
    )
    next_booking = (
        Appointment.objects
        .filter(
            dog=OuterRef('pk'),
            start_at__date__gte=today,
            status__in=Appointment.ACTIVE_STATUSES,
        )
        .order_by('start_at')
        .values('start_at')[:1]
    )

    dogs = (
        Dog.objects.filter(is_active=True)
        .select_related('client', 'breed')
        .annotate(
            last_groom_at=Subquery(last_groom),
            next_booking_at=Subquery(next_booking),
        )
    )

    if not include_ad_hoc:
        dogs = dogs.filter(is_ad_hoc=False)

    rows = []
    for dog in dogs:
        if dog.next_booking_at and not include_booked:
            continue

        if dog.last_groom_at is None:
            if not include_never_groomed:
                continue
            rows.append({
                'dog_id': dog.pk,
                'dog_name': dog.name,
                'breed_label': dog.breed_label,
                'client_id': dog.client_id,
                'client_name': dog.client.full_name,
                'client_phone': dog.client.phone,
                'last_groom_date': None,
                'due_date': None,
                'days_overdue': None,
                'schedule_weeks': dog.effective_schedule_weeks,
                'next_booking_at': dog.next_booking_at,
                'basis': 'no completed grooms yet',
            })
            continue

        last_date = timezone.localtime(dog.last_groom_at).date()
        due = last_date + timedelta(weeks=dog.effective_schedule_weeks)
        days_overdue = (today - due).days
        # Negative means not due yet; within_days is how far ahead to look.
        if days_overdue < -within_days:
            continue

        rows.append({
            'dog_id': dog.pk,
            'dog_name': dog.name,
            'breed_label': dog.breed_label,
            'client_id': dog.client_id,
            'client_name': dog.client.full_name,
            'client_phone': dog.client.phone,
            'last_groom_date': last_date.isoformat(),
            'due_date': due.isoformat(),
            'days_overdue': days_overdue,
            'schedule_weeks': dog.effective_schedule_weeks,
            'next_booking_at': dog.next_booking_at,
            'basis': f'{dog.effective_schedule_weeks} weeks after {last_date:%d %b %Y}',
        })

    # Most overdue first; never-groomed last (see the docstring).
    rows.sort(key=lambda row: (row['days_overdue'] is None, -(row['days_overdue'] or 0)))
    return rows
