"""The distance between a timed groom and a bookable slot.

Jess: the groom time coming off the timer is *"nowhere near the appointment
time (which would be how long to book them in for)"*. It isn't, and it never
could be — the timer counts five phases and a booking also covers the nails,
the ears, the hygiene area, the health check and handing the dog over at both
ends. ``GroomSession.bookable_minutes`` is the timed total plus this.

**Null, not zero, and nothing is guessed.** Same call as ``nail_visit_minutes``
in ``0005``/``0006`` and for the same reason: a buffer this codebase invented
would be indistinguishable from one Jess measured, and every booking in the
diary would be the wrong length on the strength of it. Until she sets it the
behaviour is byte-identical to before.
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0018_groom_card_checklist'),
    ]

    operations = [
        migrations.AddField(
            model_name='appsettings',
            name='groom_time_buffer_minutes',
            field=models.PositiveIntegerField(
                blank=True, null=True,
                help_text=(
                    'Minutes to add to a timed groom to get how long to book. Covers '
                    "what the timer never sees — nails, ears, the health check, "
                    'drop-off and collection. Blank until set, and nothing is guessed.'
                ),
            ),
        ),
    ]
