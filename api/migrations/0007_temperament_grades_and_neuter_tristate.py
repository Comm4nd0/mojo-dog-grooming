"""Five handling grades Jess can rename, and a neuter field that can say
"nobody asked".

**Temperaments.** Jess asked for five grades rather than three — "may up bitey
not hard" — because the old middle grade, "Fidgety / bitey", was doing two
jobs. ``WRIGGLY`` and ``BITEY`` are added and ``FIDGETY`` keeps its code while
losing "/ bitey" from its wording.

No existing row is remapped. A dog's grade drives how many of that kind Jess
will take in a day, so silently moving a dog from one grade to another changes
her diary without her asking, and there is no way to tell afterwards which
dogs were moved.

The names we chose are our reading of a one-line note, so the *labels* move
out of the code and into the table: ``TemperamentLimit`` becomes
``TemperamentGrade`` and gains ``label`` and ``sort_order``. A rename, not a
create-and-drop — Django's autodetector wanted the latter, which would have
thrown away any cap Jess had already set. The codes stay frozen; every
``Dog.temperament`` points at one.

The two new grades seed with **no cap**. Interpolating between the old 2 and 1
would invent a rule Jess never set, and an invented limit is indistinguishable
from a real one once it is in the table — the same reasoning behind 0006.

**Neutering.** ``Dog.is_neutered`` was a ``BooleanField(default=False)``, so a
dog nobody had asked about was stored identically to one confirmed entire, and
the new tag on the dog profile would have labelled every one of them "Intact".
It becomes nullable, null meaning "never asked" — the rule already followed by
``photo_consent`` and ``bathed_well_behaved``.

Existing ``False`` values are cleared to null, which is the one destructive
step here and was confirmed before writing it: the database holds a handful of
dogs at this point, none of the answers can be trusted to have been given
rather than defaulted, and re-asking a few owners is cheaper than carrying
invented answers forward for good. On a larger database the right call would
have been to leave them alone.

**This migration does not reverse.** Both ``RunPython`` steps have reverse
functions and the field changes are reversible, but ``RenameModel`` makes
Django inject its own ``RenameContentType``, and unapplying that raises
``no such column: django_content_type.name`` — a Django limitation, not
anything in this file. It is recorded rather than worked around because
nothing here reverses migrations: ``deploy.sh`` rolls back by resetting the
checkout and redeploying, and the database is restored by hand from the
``pg_dump`` taken before every deploy.
"""

from django.db import migrations, models

# Frozen copies. A migration must not import from api.models — that reflects
# today's code, and this file has to keep meaning the same thing in a year.
GRADES = [
    ('EASY', 'Easy', 1),
    ('WRIGGLY', 'Wriggly, but fine', 2),
    ('FIDGETY', 'Fidgety', 3),
    ('BITEY', 'Bitey, not hard', 4),
    ('FEISTY', 'Feisty / hard', 5),
]

TEMPERAMENT_CHOICES = [(code, label) for code, label, _ in GRADES]


def fill_grades(apps, schema_editor):
    """Label and order the three existing rows; add the two new ones."""
    TemperamentGrade = apps.get_model('api', 'TemperamentGrade')
    for code, label, order in GRADES:
        row = TemperamentGrade.objects.filter(temperament=code).first()
        if row is None:
            # max_per_day left null: no limit until Jess sets one.
            TemperamentGrade.objects.create(
                temperament=code, label=label, sort_order=order,
            )
            continue
        # Only fills a blank label — the column is new, so every existing row
        # has one, but a re-run must not overwrite Jess's wording.
        if not row.label:
            row.label = label
        row.sort_order = order
        row.save(update_fields=['label', 'sort_order'])


def unfill_grades(apps, schema_editor):
    """Drop the two grades added here, if nothing is using them.

    A dog carrying WRIGGLY or BITEY has no representable value once the choice
    is gone, so those rows stay and the reverse stops short rather than
    corrupting the dog. Reversing this migration is a last resort anyway.
    """
    TemperamentGrade = apps.get_model('api', 'TemperamentGrade')
    Dog = apps.get_model('api', 'Dog')
    GroomSession = apps.get_model('api', 'GroomSession')
    for code in ('WRIGGLY', 'BITEY'):
        in_use = (
            Dog.objects.filter(temperament=code).exists()
            or GroomSession.objects.filter(temperament_observed=code).exists()
        )
        if not in_use:
            TemperamentGrade.objects.filter(temperament=code).delete()


def clear_defaulted_neuter(apps, schema_editor):
    """Turn every stored ``False`` back into "not asked".

    ``False`` was the column default, so it is what a dog gets when the
    question was never put — and there is no way to tell those from a
    deliberate "no". See the module docstring for why clearing is the right
    call on this database specifically.
    """
    Dog = apps.get_model('api', 'Dog')
    Dog.objects.filter(is_neutered=False).update(is_neutered=None)


def restore_neuter_default(apps, schema_editor):
    """Reverse fills null back to False, because the column stops being
    nullable. It cannot distinguish the two, which is the whole problem."""
    Dog = apps.get_model('api', 'Dog')
    Dog.objects.filter(is_neutered=None).update(is_neutered=False)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0006_clear_seeded_nail_visit_defaults'),
    ]

    operations = [
        migrations.RenameModel(
            old_name='TemperamentLimit',
            new_name='TemperamentGrade',
        ),
        migrations.AddField(
            model_name='temperamentgrade',
            name='label',
            field=models.CharField(
                default='',
                help_text="What this grade is called in the app. Jess's wording wins.",
                max_length=40,
            ),
            preserve_default=False,
        ),
        migrations.AddField(
            model_name='temperamentgrade',
            name='sort_order',
            field=models.PositiveIntegerField(
                default=0, help_text='Easiest first. Seeded from TEMPERAMENT_ORDER.',
            ),
        ),
        migrations.AlterModelOptions(
            name='temperamentgrade',
            options={'ordering': ['sort_order', 'temperament']},
        ),
        migrations.AlterField(
            model_name='temperamentgrade',
            name='temperament',
            field=models.CharField(choices=TEMPERAMENT_CHOICES, max_length=10, unique=True),
        ),
        migrations.AlterField(
            model_name='dog',
            name='temperament',
            field=models.CharField(
                choices=TEMPERAMENT_CHOICES,
                default='EASY',
                help_text=(
                    'Handling difficulty. Drives the per-day booking limit. '
                    'Hidden from clients.'
                ),
                max_length=10,
            ),
        ),
        migrations.AlterField(
            model_name='groomsession',
            name='temperament_observed',
            field=models.CharField(blank=True, choices=TEMPERAMENT_CHOICES, max_length=10),
        ),
        migrations.RunPython(fill_grades, unfill_grades),
        migrations.AlterField(
            model_name='dog',
            name='is_neutered',
            field=models.BooleanField(blank=True, default=None, null=True),
        ),
        migrations.RunPython(clear_defaulted_neuter, restore_neuter_default),
    ]
