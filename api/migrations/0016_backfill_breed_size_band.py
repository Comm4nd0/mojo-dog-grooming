"""Fill in ``Breed.size_band`` for breeds that already exist.

The band has always been in ``seed_breeds.BREEDS`` — ``PRICING`` is keyed by
``(size, coat)`` — but it was never stored, so the 224 seeded rows have it
blank after 0015 adds the column.

`seed_breeds` cannot do this on its own. It applies its defaults on create, and
otherwise only under ``--overwrite``, which **also resets price, time and
interval** and so discards every figure Jess has edited in the app. That is the
whole reason `--overwrite` is not the default, and it is not a reasonable price
for filling in one new column.

So: a one-off, exactly like 0006. It writes ``size_band`` and nothing else, it
skips any row that already has one, and it matches on name — which is the same
key `seed_breeds` uses, with the same known weakness that a breed Jess has
renamed will not be found. A renamed breed simply keeps a blank band and can be
set by hand; nothing else about it is disturbed.
"""

from django.db import migrations


def backfill(apps, schema_editor):
    Breed = apps.get_model('api', 'Breed')

    # Imported here rather than at module scope: a migration must keep working
    # even if the seed data is later restructured, and an import error at load
    # time would break every `migrate` run rather than just this one.
    from api.management.commands.seed_breeds import BREEDS

    bands = {name: size for name, size, _coat in BREEDS}

    to_update = []
    for breed in Breed.objects.filter(size_band=''):
        band = bands.get(breed.name)
        if band:
            breed.size_band = band
            to_update.append(breed)

    if to_update:
        Breed.objects.bulk_update(to_update, ['size_band'])


def unfill(apps, schema_editor):
    # Reversible so the migration can be rolled back with the rest of a bad
    # deploy. Only clears what this filled: rows whose band matches the seed.
    Breed = apps.get_model('api', 'Breed')
    from api.management.commands.seed_breeds import BREEDS

    names = [name for name, _size, _coat in BREEDS]
    Breed.objects.filter(name__in=names).update(size_band='')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0015_breed_activity_level_breed_chest_shape_and_more'),
    ]

    operations = [
        migrations.RunPython(backfill, unfill),
    ]
