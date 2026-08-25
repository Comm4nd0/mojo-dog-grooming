"""The checklist grows to Jess's eight.

*"Can it just have tick boxes. 'Health Checked, Nails Clipped, Ears Cleaned,
Hygiene Area, Feet Clipped Out, Bathed, Blow Dried, Usual Groom Carried Out'"*.

Four new tri-state flags join the four from ``0018``, under the same rule:
nullable, and null means nobody worked down the list.

The data step fills two of them in **by entailment, never by guesswork**. A
non-null ``bathed_well_behaved`` is an answer about how the bath went, which
means a bath went — so ``bathed`` becomes True on those rows. A
``high_velocity_dryer`` recorded as *used* means the dog was blow dried. Only
those two directions hold: a null behaviour answer says nothing about whether
there was a bath, and a dryer *not used* says nothing about drying, so
everything else stays null. ``GroomSession.save()`` keeps the same entailment
live for future rows.

The reverse leaves the filled values in place: the columns are dropped on the
way down anyway, and un-entailing them would only re-lose a fact that is true.
"""
from django.db import migrations, models


def fill_entailed_answers(apps, schema_editor):
    GroomSession = apps.get_model('api', 'GroomSession')
    GroomSession.objects.filter(
        bathed__isnull=True, bathed_well_behaved__isnull=False,
    ).update(bathed=True)
    GroomSession.objects.filter(
        blow_dried__isnull=True, high_velocity_dryer=True,
    ).update(blow_dried=True)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0019_groom_time_buffer'),
    ]

    operations = [
        migrations.AddField(
            model_name='groomsession',
            name='feet_clipped_out',
            field=models.BooleanField(blank=True, null=True, verbose_name='Feet clipped out'),
        ),
        migrations.AddField(
            model_name='groomsession',
            name='bathed',
            field=models.BooleanField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='groomsession',
            name='blow_dried',
            field=models.BooleanField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='groomsession',
            name='usual_groom_done',
            field=models.BooleanField(blank=True, null=True, verbose_name='Usual groom carried out'),
        ),
        migrations.RunPython(fill_entailed_answers, migrations.RunPython.noop),
    ]
