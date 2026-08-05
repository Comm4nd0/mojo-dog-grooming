"""Six things Jess asked for on 4 August 2026, in one pass.

**The dryer becomes a tri-state.** *"High velocity dryer, can we change to well
behaved like the bathed"* — ``bathed_well_behaved`` is nullable, so it can say
"nobody wrote it down" as well as yes and no, and the dryer could not. On a dog
that will not tolerate one, "not used" is the fact worth having and a switch
that starts in the off position cannot state it.

Existing ``False`` values are cleared to null, exactly as 0007 did for
``Dog.is_neutered`` and for the same reason: the app rendered this as a switch
defaulting to off, so not one stored ``False`` can be told apart from a groom
where Jess never touched it. Recording "no" again on the handful of sessions in
the database is cheaper than carrying invented answers forward for good. On a
larger database the right call would be to leave them.

**Head shape becomes tail shape.** Her wording — *"can we change head shape to
tail shape"*. ``head_type`` was covering the head twice over, and the tail had
nowhere to go.

It is a ``RenameField`` followed by a data step, rather than either half alone,
because the two obvious migrations are both wrong. A drop-and-add throws away
whatever she has typed. A bare rename keeps it and files it under the wrong
heading — a breed sheet reading "Tail shape: broad, blocky skull" is worse than
an empty one, because the empty one is honest and that one is a confident
answer to a question nobody asked. Same rule as ``nail_visit_price``: text that
looks like a real entry is indistinguishable from one once it is in the table.

So the rename carries the column across, and ``rehome_head_shape`` then moves
each value to the field that does mean the head — ``head_type`` when it is
free, ``notes`` when it is not, so nothing she wrote is lost either way — and
leaves ``tail_shape`` **blank** for her to fill in.

This half does not reverse. The text has been merged into a field that may
already have had content, and there is no way back to which part was which.
Nothing here reverses migrations anyway: ``deploy.sh`` rolls back by resetting
the checkout, and the database comes from the ``pg_dump`` taken before it.

**Typical temperament** joins the breed record, *"copied from the uk kennel
club website"*. Free text and **seeded with nothing**, same rule as
``MedicalNote``: it is somebody else's description of a breed, and a blank is
honest where invented text is not.

**Ad hoc dogs.** *"bunny is in my overdue ... shes ad hock and was in today,
don't know what I've done wrong."* Nothing — ``dogs_due`` is "last groom +
interval", and every dog has an interval whether or not one was ever agreed, so
a dog that comes when the owner rings is permanently about to be late.
``Dog.is_ad_hoc`` takes them off that list. It does not touch
``effective_schedule_weeks``: asking about one dog directly is still a fair
question, what changes is that nothing volunteers the answer.

**Daycare.** *"can there be a daycare dog tickbox and be able to put what days
they're in?"* A flag and a list of weekday numbers. The flag is separate from
the list on purpose — a dog can be signed up before the days are settled, and a
tickbox that unticks itself when you clear the days is a tickbox that argues.

**Particular about groom standard.** *"please can there be a new tick box for
each client"*. Staff-only with ``chatty`` and ``notes``, and it has to be: it is
Jess's reading of an owner, not a fact about them, and the serializer gate is
the only thing between it and their own profile screen.
"""

from django.db import migrations, models

import api.models


def clear_defaulted_dryer(apps, schema_editor):
    """False was the switch's resting position, not an answer. See the header."""
    apps.get_model('api', 'GroomSession').objects.filter(
        high_velocity_dryer=False,
    ).update(high_velocity_dryer=None)


def dryer_null_to_false(apps, schema_editor):
    """Reverse: null cannot survive a non-nullable column, so it goes back to False."""
    apps.get_model('api', 'GroomSession').objects.filter(
        high_velocity_dryer=None,
    ).update(high_velocity_dryer=False)


def rehome_head_shape(apps, schema_editor):
    """Move what was typed about a head out of the field that now says tail.

    Runs straight after the rename, so ``tail_shape`` at this point still holds
    the old ``head_shape`` text and nothing else can have written to it.

    ``head_type`` first, because that is the field that means the same thing —
    it being blank is the usual case and the reason the rename was possible at
    all. Where it is already filled in, the text goes to ``notes`` under its
    own heading rather than being crammed in beside something else or dropped.
    """
    Breed = apps.get_model('api', 'Breed')
    for breed in Breed.objects.exclude(tail_shape='').iterator():
        text = breed.tail_shape.strip()
        overflow = text
        if not breed.head_type:
            # 120 is the column, and the old field was the same width, so this
            # only ever truncates when both were full.
            breed.head_type = text[:120]
            overflow = text[120:].strip()
        if overflow:
            line = f'Head shape: {overflow}'
            breed.notes = f'{breed.notes}\n{line}'.strip() if breed.notes else line
        breed.tail_shape = ''
        breed.save(update_fields=['head_type', 'notes', 'tail_shape'])


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0016_backfill_breed_size_band'),
    ]

    operations = [
        # ── The dryer ──────────────────────────────────────────────────
        migrations.AlterField(
            model_name='groomsession',
            name='high_velocity_dryer',
            field=models.BooleanField(blank=True, null=True),
        ),
        migrations.RunPython(clear_defaulted_dryer, dryer_null_to_false),

        # ── The breed record ───────────────────────────────────────────
        migrations.RenameField(
            model_name='breed',
            old_name='head_shape',
            new_name='tail_shape',
        ),
        # Must follow the rename, and nothing may write to tail_shape in
        # between: this reads the column expecting the old field's contents.
        migrations.RunPython(rehome_head_shape, migrations.RunPython.noop),
        migrations.AddField(
            model_name='breed',
            name='typical_temperament',
            field=models.TextField(
                blank=True,
                help_text='What the breed is generally like. Not this dog — see the dog record for that.',
            ),
        ),

        # ── The dog ────────────────────────────────────────────────────
        migrations.AddField(
            model_name='dog',
            name='is_ad_hoc',
            field=models.BooleanField(
                default=False,
                help_text='Comes when the owner asks. Kept off the "who is due" list.',
                verbose_name='Ad hoc — no regular interval',
            ),
        ),
        migrations.AddField(
            model_name='dog',
            name='is_daycare',
            field=models.BooleanField(
                default=False,
                help_text='Comes in for daycare as well as grooming.',
                verbose_name='Daycare dog',
            ),
        ),
        migrations.AddField(
            model_name='dog',
            name='daycare_days',
            field=models.JSONField(
                blank=True,
                default=list,
                help_text='Which days, 0 = Monday. Kept sorted, no repeats.',
                validators=[api.models.validate_weekdays],
                verbose_name='Daycare days',
            ),
        ),

        # ── The client ─────────────────────────────────────────────────
        migrations.AddField(
            model_name='client',
            name='particular_about_standard',
            field=models.BooleanField(
                default=False,
                help_text='This owner is particular about the finish. Hidden from clients.',
                verbose_name='Particular about groom standard',
            ),
        ),
    ]
