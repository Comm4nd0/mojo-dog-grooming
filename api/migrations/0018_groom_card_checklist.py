"""Jess's finishing checklist on the groom card.

*"can we add a little 'check list' "Nails Clipped, Hygiene Area, Health Check,
Ears Cleaned" with a little box under to fill in why something not done"*.

Three new tri-state flags, one reason box, and ``nails_done`` — which already
existed on the nails/fleas/ticks card and is the same fact — widened to carry
the third state as well.

The data step is the interesting half. ``nails_done`` has been
``default=False`` since ``0001``, so **every groom session already recorded
claims the dog's nails were not clipped**, which is a claim nobody made: that
card never asked. Those Falses are cleared to null, exactly as ``0007`` did for
``Dog.is_neutered`` and ``0017`` for ``high_velocity_dryer``, and for the same
reason — a value nobody entered is indistinguishable from one they did.

It is cleared **only on GROOM rows**. On a nails/fleas/ticks visit a False is a
real answer — that card asks which of the three the visit was for, and the
serializer refuses one that names none — so wiping those would destroy
information rather than stop inventing it. That half does not reverse, and says
so below.
"""
from django.db import migrations, models


def clear_unasked_nails_on_grooms(apps, schema_editor):
    GroomSession = apps.get_model('api', 'GroomSession')
    GroomSession.objects.filter(visit_type='GROOM', nails_done=False).update(nails_done=None)


def noop_reverse(apps, schema_editor):
    """Deliberately does nothing.

    Putting the Falses back would re-assert the very claim this removed. The
    column is nullable in both directions, so nothing breaks by leaving them.
    """


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0017_daycare_ad_hoc_and_breed_tail_shape'),
    ]

    operations = [
        migrations.AlterField(
            model_name='groomsession',
            name='nails_done',
            field=models.BooleanField(blank=True, null=True, verbose_name='Nails clipped'),
        ),
        migrations.AddField(
            model_name='groomsession',
            name='hygiene_area_done',
            field=models.BooleanField(blank=True, null=True, verbose_name='Hygiene area'),
        ),
        migrations.AddField(
            model_name='groomsession',
            name='health_check_done',
            field=models.BooleanField(
                blank=True, null=True,
                help_text=(
                    'Whether the check was carried out. What it found goes in '
                    'health_check_notes.'
                ),
                verbose_name='Health check done',
            ),
        ),
        migrations.AddField(
            model_name='groomsession',
            name='ears_cleaned',
            field=models.BooleanField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='groomsession',
            name='checklist_notes',
            field=models.TextField(
                blank=True, help_text='Why anything on the checklist was not done.',
            ),
        ),
        migrations.RunPython(clear_unasked_nails_on_grooms, noop_reverse),
    ]
