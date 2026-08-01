"""Jess's list of what she actually does, as a table.

Thirteen services, from her feedback of 1 August. `ServiceType` stays as the
coarse category alongside it — it is what tells the two paper record cards
apart, and what stops a 25-minute Tidy Up overwriting a dog's full-groom time.

Purely additive: an appointment with no services attached resolves exactly as
it did before this existed, which is the property that makes it safe to deploy
ahead of the app build that uses it.

The rows are seeded by `seed_breeds`, not here, so `entrypoint.sh` refreshes
them on every boot without a migration per change — and so a price Jess has
set is never trampled.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0008_invoice_sent_and_paid_dates'),
    ]

    operations = [
        migrations.CreateModel(
            name='Service',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('code', models.SlugField(max_length=40, unique=True)),
                ('name', models.CharField(max_length=120)),
                ('category', models.CharField(choices=[('GROOM', 'Groom'), ('NAILS', 'Nails, fleas or ticks')], default='GROOM', help_text='Which record card this belongs to, and how it is priced.', max_length=10)),
                ('default_minutes', models.PositiveIntegerField(blank=True, help_text='Blank until Jess sets one.', null=True)),
                ('default_price', models.DecimalField(blank=True, decimal_places=2, help_text='Blank until Jess sets one. Never invent a figure here.', max_digits=7, null=True)),
                ('takes_dog_defaults', models.BooleanField(default=False, help_text='Take both the length and the price from the dog — i.e. from the breed grid. Set on Full Groom only.')),
                ('is_active', models.BooleanField(default=True)),
                ('sort_order', models.IntegerField(default=0)),
            ],
            options={
                'ordering': ['sort_order', 'name'],
            },
        ),
        migrations.AddField(
            model_name='appointment',
            name='services',
            field=models.ManyToManyField(blank=True, help_text='What is being done. Drives the length and the quote.', related_name='appointments', to='api.service'),
        ),
        migrations.AddField(
            model_name='dog',
            name='default_services',
            field=models.ManyToManyField(blank=True, help_text='What this dog normally has. Pre-fills a new booking.', related_name='dogs', to='api.service'),
        ),
    ]
