"""Booking checks.

Every rule in here produces a *warning*, never a refusal. Jess's notes are
explicit that the app should "warn when exceeding temperament booking limits,
but don't prevent booking", and the same principle applies to opening hours —
she regularly works outside them. The app shows these in a confirm dialog and
the user decides.
"""

from datetime import timedelta

from django.utils import timezone

from .models import Appointment, ClosureDay, OpeningHours, TemperamentLimit


def _local_date(dt):
    return timezone.localtime(dt).date()


def temperament_warning(dog, start_at, exclude_appointment=None):
    """Warn when this booking takes the day over the limit for its temperament."""
    limit = TemperamentLimit.objects.filter(temperament=dog.temperament).first()
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
        label = dog.get_temperament_display().lower()
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


def booking_warnings(dog, start_at, end_at=None, exclude_appointment=None):
    """All warnings for a proposed slot, in the order they matter to Jess."""
    if end_at is None:
        end_at = start_at + timedelta(minutes=dog.effective_groom_minutes)

    checks = [
        temperament_warning(dog, start_at, exclude_appointment),
        opening_hours_warning(start_at, end_at),
        overlap_warning(start_at, end_at, exclude_appointment),
    ]
    return [warning for warning in checks if warning is not None]
