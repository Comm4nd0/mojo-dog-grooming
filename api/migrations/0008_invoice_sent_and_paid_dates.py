"""When an invoice went out, and when it was paid.

A status column can say an invoice is sent; it cannot say when. Jess's "record
sent" wants a date against it, and `paid_at` is not redundant with
`Payment.paid_at` either — she can mark cash-in-hand paid without recording an
amount.

Both nullable and both left null for existing rows. The dates are not
recoverable: `created_at` is when the invoice was raised, not when it went out,
and inferring one from the other would put a made-up date on a financial
record.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0007_temperament_grades_and_neuter_tristate'),
    ]

    operations = [
        migrations.AddField(
            model_name='invoice',
            name='paid_at',
            field=models.DateField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='invoice',
            name='sent_at',
            field=models.DateField(blank=True, null=True),
        ),
    ]
