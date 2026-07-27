"""Seed the breed reference table, opening hours and temperament limits.

IMPORTANT — the groom times, prices and intervals below are general industry
estimates, not Mojo and Co's actual figures. They exist so the app is usable on
day one; Jess should review them against her own pricing and adjust. Editing a
breed in the app or admin overrides the value here, and re-running this command
never overwrites a breed that already exists (use --overwrite to force).

Times are a full groom in minutes, prices in GBP, intervals in weeks.
"""

from decimal import Decimal

from django.core.management.base import BaseCommand
from django.db import transaction

from api.models import AppSettings, OpeningHours, TemperamentLimit, Temperament

# name, coat type, minutes, price, weeks
BREEDS = [
    # ── Small companion / toy ──────────────────────────────────────────
    ('Affenpinscher', 'wire', 80, '42.00', 8),
    ('Bichon Frise', 'curly', 105, '50.00', 6),
    ('Bolognese', 'curly', 90, '46.00', 6),
    ('Cavalier King Charles Spaniel', 'silky', 75, '38.00', 8),
    ('Chihuahua (long coat)', 'silky', 55, '30.00', 10),
    ('Chihuahua (smooth coat)', 'smooth', 40, '22.00', 12),
    ('Chinese Crested', 'hairless', 60, '35.00', 6),
    ('Coton de Tulear', 'cotton', 90, '46.00', 6),
    ('Havanese', 'silky', 90, '46.00', 6),
    ('Italian Greyhound', 'smooth', 40, '22.00', 12),
    ('Japanese Chin', 'silky', 75, '40.00', 8),
    ('Lhasa Apso', 'double', 90, '45.00', 6),
    ('Maltese', 'silky', 75, '40.00', 6),
    ('Papillon', 'silky', 75, '38.00', 8),
    ('Pekingese', 'double', 90, '45.00', 6),
    ('Pomeranian', 'double', 90, '45.00', 8),
    ('Pug', 'smooth', 45, '25.00', 12),
    ('Shih Tzu', 'double', 90, '45.00', 6),
    ('Yorkshire Terrier', 'silky', 75, '38.00', 6),

    # ── Terriers ───────────────────────────────────────────────────────
    ('Airedale Terrier', 'wire', 120, '58.00', 8),
    ('Bedlington Terrier', 'curly', 105, '52.00', 6),
    ('Border Terrier', 'wire', 75, '40.00', 12),
    ('Cairn Terrier', 'wire', 80, '42.00', 10),
    ('Fox Terrier (wire)', 'wire', 100, '48.00', 8),
    ('Jack Russell Terrier', 'smooth', 45, '25.00', 12),
    ('Kerry Blue Terrier', 'curly', 120, '58.00', 6),
    ('Lakeland Terrier', 'wire', 100, '48.00', 8),
    ('Norfolk Terrier', 'wire', 80, '42.00', 10),
    ('Norwich Terrier', 'wire', 80, '42.00', 10),
    ('Scottish Terrier', 'wire', 90, '45.00', 8),
    ('Sealyham Terrier', 'wire', 100, '48.00', 8),
    ('Soft Coated Wheaten Terrier', 'silky', 120, '55.00', 6),
    ('Staffordshire Bull Terrier', 'smooth', 45, '25.00', 12),
    ('Welsh Terrier', 'wire', 105, '50.00', 8),
    ('West Highland White Terrier', 'wire', 90, '45.00', 8),

    # ── Poodles, doodles and crosses ───────────────────────────────────
    ('Cavapoo', 'curly', 105, '48.00', 6),
    ('Cockapoo (small)', 'curly', 105, '50.00', 6),
    ('Cockapoo (large)', 'curly', 120, '60.00', 8),
    ('Goldendoodle', 'curly', 150, '72.00', 8),
    ('Labradoodle', 'curly', 135, '65.00', 8),
    ('Maltipoo', 'curly', 95, '46.00', 6),
    ('Poodle (toy)', 'curly', 95, '46.00', 6),
    ('Poodle (miniature)', 'curly', 105, '50.00', 6),
    ('Poodle (standard)', 'curly', 150, '75.00', 6),
    ('Schnoodle', 'curly', 110, '52.00', 6),
    ('Shihpoo', 'curly', 95, '46.00', 6),
    ('Zuchon (Shih Tzu x Bichon)', 'curly', 100, '48.00', 6),

    # ── Schnauzers ─────────────────────────────────────────────────────
    ('Miniature Schnauzer', 'wire', 90, '45.00', 6),
    ('Standard Schnauzer', 'wire', 105, '52.00', 6),
    ('Giant Schnauzer', 'wire', 150, '75.00', 6),

    # ── Spaniels and gundogs ───────────────────────────────────────────
    ('Cocker Spaniel', 'silky', 90, '45.00', 8),
    ('English Springer Spaniel', 'silky', 90, '48.00', 8),
    ('English Setter', 'silky', 105, '52.00', 8),
    ('Irish Setter', 'silky', 105, '52.00', 8),
    ('Golden Retriever', 'double', 120, '60.00', 8),
    ('Labrador Retriever', 'double', 60, '35.00', 12),
    ('Portuguese Water Dog', 'curly', 135, '65.00', 6),
    ('Vizsla', 'smooth', 45, '25.00', 12),
    ('Weimaraner', 'smooth', 45, '25.00', 12),

    # ── Herding ────────────────────────────────────────────────────────
    ('Australian Shepherd', 'double', 105, '52.00', 8),
    ('Bearded Collie', 'double', 150, '72.00', 6),
    ('Border Collie', 'double', 90, '45.00', 10),
    ('German Shepherd', 'double', 105, '55.00', 8),
    ('Old English Sheepdog', 'double', 180, '85.00', 6),
    ('Rough Collie', 'double', 135, '68.00', 8),
    ('Shetland Sheepdog', 'double', 105, '52.00', 8),

    # ── Spitz and northern ─────────────────────────────────────────────
    ('Akita', 'double', 120, '60.00', 10),
    ('Chow Chow', 'double', 150, '75.00', 8),
    ('Japanese Spitz', 'double', 105, '52.00', 8),
    ('Keeshond', 'double', 135, '65.00', 8),
    ('Samoyed', 'double', 150, '75.00', 8),
    ('Siberian Husky', 'double', 120, '60.00', 10),

    # ── Hounds ─────────────────────────────────────────────────────────
    ('Basset Hound', 'smooth', 60, '32.00', 10),
    ('Beagle', 'smooth', 55, '30.00', 12),
    ('Dachshund (long haired)', 'silky', 60, '32.00', 10),
    ('Dachshund (smooth haired)', 'smooth', 45, '25.00', 12),
    ('Dachshund (wire haired)', 'wire', 70, '38.00', 10),
    ('Greyhound', 'smooth', 45, '25.00', 12),
    ('Afghan Hound', 'silky', 165, '80.00', 6),
    ('Whippet', 'smooth', 40, '22.00', 12),

    # ── Working and large ──────────────────────────────────────────────
    ('Bernese Mountain Dog', 'double', 150, '75.00', 8),
    ('Boxer', 'smooth', 50, '28.00', 12),
    ('Doberman', 'smooth', 55, '30.00', 12),
    ('French Bulldog', 'smooth', 45, '25.00', 12),
    ('Great Dane', 'smooth', 75, '45.00', 12),
    ('Leonberger', 'double', 165, '85.00', 8),
    ('Newfoundland', 'double', 180, '90.00', 8),
    ('Rottweiler', 'smooth', 60, '35.00', 12),
    ('Saint Bernard', 'double', 165, '85.00', 8),
    ('Shar Pei', 'smooth', 60, '35.00', 10),

    # ── Generic fallbacks for crosses and unknowns ─────────────────────
    ('Crossbreed (small)', '', 75, '38.00', 8),
    ('Crossbreed (medium)', '', 100, '48.00', 8),
    ('Crossbreed (large)', '', 130, '62.00', 8),
]

# Jess's starting limits. Easy dogs are unlimited; the harder the dog, the
# fewer she'll take in a day. All three are editable in the app.
TEMPERAMENT_LIMITS = {
    Temperament.EASY: None,
    Temperament.FIDGETY: 2,
    Temperament.FEISTY: 1,
}

# Monday–Friday 09:00–17:00, Saturday 09:00–13:00, closed Sunday.
OPENING_HOURS = {
    0: ('09:00', '17:00', False),
    1: ('09:00', '17:00', False),
    2: ('09:00', '17:00', False),
    3: ('09:00', '17:00', False),
    4: ('09:00', '17:00', False),
    5: ('09:00', '13:00', False),
    6: (None, None, True),
}


class Command(BaseCommand):
    help = 'Seed breeds, temperament limits, opening hours and app settings.'

    def add_arguments(self, parser):
        parser.add_argument(
            '--overwrite',
            action='store_true',
            help='Replace the times, prices and intervals of breeds that already exist.',
        )

    @transaction.atomic
    def handle(self, *args, **options):
        from datetime import time

        overwrite = options['overwrite']
        created = updated = skipped = 0

        for name, coat, minutes, price, weeks in BREEDS:
            defaults = {
                'coat_type': coat,
                'avg_groom_minutes': minutes,
                'avg_price': Decimal(price),
                'avg_schedule_weeks': weeks,
            }
            from api.models import Breed

            breed, was_created = Breed.objects.get_or_create(name=name, defaults=defaults)
            if was_created:
                created += 1
            elif overwrite:
                for field, value in defaults.items():
                    setattr(breed, field, value)
                breed.save()
                updated += 1
            else:
                skipped += 1

        for temperament, cap in TEMPERAMENT_LIMITS.items():
            TemperamentLimit.objects.get_or_create(
                temperament=temperament, defaults={'max_per_day': cap},
            )

        for weekday, (opens, closes, closed) in OPENING_HOURS.items():
            OpeningHours.objects.get_or_create(
                weekday=weekday,
                defaults={
                    'open_time': time.fromisoformat(opens) if opens else None,
                    'close_time': time.fromisoformat(closes) if closes else None,
                    'is_closed': closed,
                },
            )

        AppSettings.get()

        self.stdout.write(self.style.SUCCESS(
            f'Breeds: {created} created, {updated} updated, {skipped} left alone.'
        ))
        self.stdout.write(
            'Temperament limits, opening hours and app settings are in place.'
        )
        self.stdout.write(self.style.WARNING(
            'Breed times and prices are general estimates — have Jess review them '
            'against her own pricing before going live.'
        ))
