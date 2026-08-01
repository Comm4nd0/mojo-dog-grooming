"""Clear the nail-visit figures that 0004 wrote into an existing settings row.

0004 added ``nail_visit_minutes`` and ``nail_visit_price`` with defaults of 20
and 10.00 — figures nobody chose, invented before it was decided that Jess
should enter her own. 0005 made both nullable, but altering a column to allow
null does not reset the values already in it, so any database that had a
settings row before 0004 is still carrying them, and a made-up price is
indistinguishable from a real one once it is sitting in the table.

Only the exact old defaults are cleared. Anything else is a figure somebody
chose deliberately between 0004 and here, and this must not throw it away.
"""

from decimal import Decimal

from django.db import migrations

OLD_DEFAULT_MINUTES = 20
OLD_DEFAULT_PRICE = Decimal('10.00')


def clear_invented_defaults(apps, schema_editor):
    AppSettings = apps.get_model('api', 'AppSettings')
    for row in AppSettings.objects.all():
        changed = []
        if row.nail_visit_minutes == OLD_DEFAULT_MINUTES:
            row.nail_visit_minutes = None
            changed.append('nail_visit_minutes')
        if row.nail_visit_price == OLD_DEFAULT_PRICE:
            row.nail_visit_price = None
            changed.append('nail_visit_price')
        if changed:
            row.save(update_fields=changed)


def restore_defaults(apps, schema_editor):
    """Reverse is a no-op.

    Putting 20 and 10.00 back would reintroduce the invented figures this
    migration exists to remove, and cannot tell a cleared field from one Jess
    deliberately left blank.
    """


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0005_alter_appsettings_nail_visit_minutes_and_more'),
    ]

    operations = [
        migrations.RunPython(clear_invented_defaults, restore_defaults),
    ]
