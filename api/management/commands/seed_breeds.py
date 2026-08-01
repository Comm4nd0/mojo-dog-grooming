"""Seed the breed reference table, opening hours and temperament limits.

The groom times and prices are **Mojo and Co's own**, from Jess's price list of
28 July 2026. She prices by size band × coat type rather than per breed, so
``PRICING`` below is that grid verbatim and every breed just names its cell.
Change a number in the grid and every breed in that band follows.

Two things in here are *not* from Jess and are estimates she should correct:

- **Which cell a breed sits in.** Her list gives the size band for each breed
  but only implies the coat type by ordering, so the coat is our reading of the
  breed. A breed in the wrong cell is priced wrong — Settings → Breeds fixes it.
- **The interval between grooms.** Her list has none, so ``SCHEDULE_WEEKS``
  derives one from the coat type.

Breeds marked ``# not on Jess's list`` are ones she didn't include — mostly
poodle crosses and other non-KC dogs that walk in anyway. Their band is our
guess; their price still comes from her grid.

Editing a breed in the app or admin overrides everything here, and re-running
this command never overwrites a breed that already exists (use --overwrite to
force — which is what to run after changing a price).

Times are a full groom in minutes, prices in GBP, intervals in weeks.
"""

from decimal import Decimal

from django.core.management.base import BaseCommand
from django.db import transaction

from api.models import AppSettings, OpeningHours, TemperamentLimit, Temperament

# Jess's price list, 28 July 2026: (size band, coat type) -> (minutes, price).
# The blank coat is the fallback for a dog whose coat we don't know; it takes
# the short double column, the middle of the five.
PRICING = {
    ('colossal', 'smooth'):       (75, '57.50'),
    ('colossal', 'short double'): (150, '105.00'),
    ('colossal', 'long double'):  (225, '140.00'),
    ('colossal', 'curly'):        (255, '160.00'),
    ('colossal', 'wire'):         (225, '145.00'),
    ('colossal', ''):             (150, '105.00'),

    ('large', 'smooth'):       (60, '50.00'),
    ('large', 'short double'): (120, '77.50'),
    ('large', 'long double'):  (165, '97.50'),
    ('large', 'curly'):        (195, '110.00'),
    ('large', 'wire'):         (165, '102.50'),
    ('large', ''):             (120, '77.50'),

    ('medium', 'smooth'):       (45, '37.50'),
    ('medium', 'short double'): (90, '57.50'),
    ('medium', 'long double'):  (120, '70.00'),
    ('medium', 'curly'):        (150, '80.00'),
    ('medium', 'wire'):         (120, '72.50'),
    ('medium', ''):             (90, '57.50'),

    ('small', 'smooth'):       (45, '30.00'),
    ('small', 'short double'): (75, '45.00'),
    ('small', 'long double'):  (105, '57.50'),
    ('small', 'curly'):        (120, '65.00'),
    ('small', 'wire'):         (120, '60.00'),
    ('small', ''):             (75, '45.00'),

    ('toy', 'smooth'):       (30, '25.00'),
    ('toy', 'short double'): (60, '37.50'),
    ('toy', 'long double'):  (90, '47.50'),
    ('toy', 'curly'):        (105, '57.50'),
    ('toy', 'wire'):         (105, '52.50'),
    ('toy', ''):             (60, '37.50'),
}

# Shown on the breed so the price has a visible reason.
SIZE_LABELS = {
    'colossal': 'Colossal (45kg and over)',
    'large': 'Large (25-45kg)',
    'medium': 'Medium (10-25kg)',
    'small': 'Small (5-10kg)',
    'toy': 'Toy (under 5kg)',
}

# Ours, not Jess's — her price list carries no intervals.
SCHEDULE_WEEKS = {
    'smooth': 12,
    'short double': 10,
    'long double': 8,
    'curly': 6,
    'wire': 8,
    '': 8,
}

# name, size band, coat type
BREEDS = [
    # ── Colossal (45kg and over) ───────────────────────────────────────
    ('Bullmastiff', 'colossal', 'smooth'),
    ('Dogue De Bordeaux', 'colossal', 'smooth'),
    ('Great Dane', 'colossal', 'smooth'),
    ('Mastiff', 'colossal', 'smooth'),
    ('Neapolitan Mastiff', 'colossal', 'smooth'),
    ('Rhodesian Ridgeback', 'colossal', 'smooth'),
    ('Rottweiler', 'colossal', 'smooth'),

    ('Bernese Mountain Dog', 'colossal', 'long double'),
    ('Briard', 'colossal', 'long double'),
    ('Leonberger', 'colossal', 'long double'),
    ('Newfoundland', 'colossal', 'long double'),
    ('Saint Bernard', 'colossal', 'long double'),

    ('Bouvier Des Flandres', 'colossal', 'wire'),
    ('Giant Schnauzer', 'colossal', 'wire'),
    ('Irish Wolfhound', 'colossal', 'wire'),
    ('Russian Black Terrier', 'colossal', 'wire'),

    # ── Large (25-45kg) ────────────────────────────────────────────────
    ('Azawakh', 'large', 'smooth'),
    ('Basset Hound', 'large', 'smooth'),
    ('Beauceron', 'large', 'smooth'),
    ('Black and Tan Coonhound', 'large', 'smooth'),
    ('Bloodhound', 'large', 'smooth'),
    ('Boxer', 'large', 'smooth'),
    ('Bracco Italiano', 'large', 'smooth'),
    ("Braque D'Auvergne", 'large', 'smooth'),
    ('Dalmatian', 'large', 'smooth'),
    ('Doberman', 'large', 'smooth'),
    ('Foxhound', 'large', 'smooth'),
    ('German Shorthaired Pointer', 'large', 'smooth'),
    ('Grand Bleu De Gascogne', 'large', 'smooth'),
    ('Greyhound', 'large', 'smooth'),
    ('Hamiltonstovare', 'large', 'smooth'),
    ('Harrier', 'large', 'smooth'),
    ('Ibizan Hound', 'large', 'smooth'),
    ('Pharaoh Hound', 'large', 'smooth'),
    ('Pointer (English)', 'large', 'smooth'),
    ('Polish Hunting Dog', 'large', 'smooth'),
    ('Vizsla', 'large', 'smooth'),
    ('Weimaraner', 'large', 'smooth'),

    ('Akita', 'large', 'short double'),
    ('Alaskan Malamute', 'large', 'short double'),
    ('Anatolian Shepherd Dog', 'large', 'short double'),
    ('Belgian Shepherd Dog (Malinois)', 'large', 'short double'),
    ('Canadian Eskimo Dog', 'large', 'short double'),
    ('Collie (Smooth)', 'large', 'short double'),
    ('Estrela Mountain Dog', 'large', 'short double'),
    ('German Shepherd', 'large', 'short double'),
    ('Greater Swiss Mountain Dog', 'large', 'short double'),
    ('Greenland Dog', 'large', 'short double'),
    ('Japanese Akita Inu', 'large', 'short double'),
    ('Labrador Retriever', 'large', 'short double'),
    ('Retriever (Chesapeake Bay)', 'large', 'short double'),
    ('Siberian Husky', 'large', 'short double'),
    ('Turkish Kangal Dog', 'large', 'short double'),
    ('White Swiss Shepherd Dog', 'large', 'short double'),

    ('Afghan Hound', 'large', 'long double'),
    ('Belgian Shepherd Dog (Groenendael)', 'large', 'long double'),
    ('Belgian Shepherd Dog (Tervueren)', 'large', 'long double'),
    ('Borzoi', 'large', 'long double'),
    ('English Setter', 'large', 'long double'),
    ('German Longhaired Pointer', 'large', 'long double'),
    ('Golden Retriever', 'large', 'long double'),  # not on Jess's list
    ('Gordon Setter', 'large', 'long double'),
    ('Hovawart', 'large', 'long double'),
    ('Hungarian Kuvasz', 'large', 'long double'),
    ('Irish Red and White Setter', 'large', 'long double'),
    ('Irish Setter', 'large', 'long double'),
    ('Large Munsterlander', 'large', 'long double'),
    ('Maremma Sheepdog', 'large', 'long double'),
    ('Old English Sheepdog', 'large', 'long double'),
    ('Pyrenean Mountain Dog', 'large', 'long double'),
    ('Retriever (Flat Coated)', 'large', 'long double'),
    ('Rough Collie', 'large', 'long double'),
    ('Saluki', 'large', 'long double'),
    ('Spaniel (Clumber)', 'large', 'long double'),
    ('Tibetan Mastiff', 'large', 'long double'),

    ('Barbet', 'large', 'curly'),
    ('Goldendoodle', 'large', 'curly'),  # not on Jess's list
    ('Labradoodle', 'large', 'curly'),  # not on Jess's list
    ('Poodle (standard)', 'large', 'curly'),  # not on Jess's list
    ('Retriever (Curly Coated)', 'large', 'curly'),
    ('Spaniel (Irish Water)', 'large', 'curly'),

    ('Airedale Terrier', 'large', 'wire'),
    ('Belgian Shepherd Dog (Laekenois)', 'large', 'wire'),
    ('Deerhound', 'large', 'wire'),
    ('German Wirehaired Pointer', 'large', 'wire'),
    ('Hungarian Wirehaired Vizsla', 'large', 'wire'),
    ('Italian Spinone', 'large', 'wire'),
    ('Korthals Griffon', 'large', 'wire'),
    ('Otterhound', 'large', 'wire'),
    ('Slovakian Rough Haired Pointer', 'large', 'wire'),

    # ── Medium (10-25kg) ───────────────────────────────────────────────
    ('Basset Bleu De Gascogne', 'medium', 'smooth'),
    ('Bavarian Mountain Hound', 'medium', 'smooth'),
    ('Bull Terrier', 'medium', 'smooth'),
    ('Bulldog', 'medium', 'smooth'),
    ("Cirneco Dell'Etna", 'medium', 'smooth'),
    ('Entlebucher Mountain Dog', 'medium', 'smooth'),
    ('German Pinscher', 'medium', 'smooth'),
    ('Portuguese Pointer', 'medium', 'smooth'),
    ('Segugio Italiano', 'medium', 'smooth'),
    ('Shar Pei', 'medium', 'smooth'),
    ('Sloughi', 'medium', 'smooth'),

    ('Australian Cattle Dog', 'medium', 'short double'),
    ('Canaan Dog', 'medium', 'short double'),
    ('Finnish Spitz', 'medium', 'short double'),
    ('Korean Jindo', 'medium', 'short double'),
    ('Norwegian Buhund', 'medium', 'short double'),
    ('Norwegian Elkhound', 'medium', 'short double'),

    ('Australian Shepherd', 'medium', 'long double'),
    ('Bearded Collie', 'medium', 'long double'),
    ('Border Collie', 'medium', 'long double'),  # not on Jess's list
    ('Brittany', 'medium', 'long double'),
    ('Chow Chow', 'medium', 'long double'),
    ('English Springer Spaniel', 'medium', 'long double'),
    ('Eurasier', 'medium', 'long double'),
    ('Finnish Lapphund', 'medium', 'long double'),
    # Jess's list had this in Colossal, which prices it at £140. The Klein is
    # 5-8kg and the Mittel 10-11kg, and the giant variety is the Keeshond,
    # which she lists separately two lines up — so Medium, not 45kg-plus.
    ('German Spitz', 'medium', 'long double'),
    ('Icelandic Sheepdog', 'medium', 'long double'),
    ('Keeshond', 'medium', 'long double'),
    ('Polish Lowland Sheepdog', 'medium', 'long double'),
    ('Pyrenean Sheepdog (Smooth Faced)', 'medium', 'long double'),
    ('Retriever (Nova Scotia Duck Tolling)', 'medium', 'long double'),
    ('Samoyed', 'medium', 'long double'),
    ('Small Munsterlander', 'medium', 'long double'),
    ('Spaniel (Welsh Springer)', 'medium', 'long double'),
    ('Swedish Lapphund', 'medium', 'long double'),

    ('American Water Spaniel', 'medium', 'curly'),
    ('Catalan Sheepdog', 'medium', 'curly'),
    ('Cockapoo (large)', 'medium', 'curly'),  # not on Jess's list
    ('Hungarian Mudi', 'medium', 'curly'),
    ('Kerry Blue Terrier', 'medium', 'curly'),
    ('Lagotto Romagnolo', 'medium', 'curly'),
    ('Poodle (miniature)', 'medium', 'curly'),
    ('Portuguese Water Dog', 'medium', 'curly'),
    ('Soft Coated Wheaten Terrier', 'medium', 'curly'),
    ('Spanish Water Dog', 'medium', 'curly'),

    ('Basset Griffon Vendeen (Grand)', 'medium', 'wire'),
    ('Griffon Fauve De Bretagne', 'medium', 'wire'),
    ('Picardy Sheepdog', 'medium', 'wire'),

    # ── Small (5-10kg) ─────────────────────────────────────────────────
    ('Basenji', 'small', 'smooth'),
    ('Beagle', 'small', 'smooth'),
    ('Boston Terrier', 'small', 'smooth'),
    ('Bull Terrier (Miniature)', 'small', 'smooth'),
    ('Dachshund (smooth haired)', 'small', 'smooth'),  # not on Jess's list
    ('Fox Terrier (Smooth)', 'small', 'smooth'),
    ('French Bulldog', 'small', 'smooth'),
    ('Italian Greyhound', 'small', 'smooth'),
    ('Jack Russell Terrier', 'small', 'smooth'),  # not on Jess's list
    ('Lancashire Heeler', 'small', 'smooth'),
    ('Manchester Terrier', 'small', 'smooth'),
    ('Miniature Pinscher', 'small', 'smooth'),
    ('Parson Russell Terrier', 'small', 'smooth'),
    ('Portuguese Podengo', 'small', 'smooth'),
    ('Pug', 'small', 'smooth'),  # not on Jess's list
    ('Staffordshire Bull Terrier', 'small', 'smooth'),
    ('Whippet', 'small', 'smooth'),

    ('Japanese Shiba Inu', 'small', 'short double'),
    ('Swedish Vallhund', 'small', 'short double'),
    ('Welsh Corgi (Cardigan)', 'small', 'short double'),
    ('Welsh Corgi (Pembroke)', 'small', 'short double'),

    ('Cavalier King Charles Spaniel', 'small', 'long double'),
    ('Cocker Spaniel', 'small', 'long double'),
    ('Dachshund (long haired)', 'small', 'long double'),  # not on Jess's list
    ('Japanese Spitz', 'small', 'long double'),
    ('Kooikerhondje', 'small', 'long double'),
    ('Lowchen', 'small', 'long double'),
    ('Shetland Sheepdog', 'small', 'long double'),
    ('Shih Tzu', 'small', 'long double'),
    ('Spaniel (American Cocker)', 'small', 'long double'),
    ('Spaniel (Field)', 'small', 'long double'),
    ('Spaniel (Sussex)', 'small', 'long double'),
    ('Tibetan Spaniel', 'small', 'long double'),

    ('Bedlington Terrier', 'small', 'curly'),
    ('Cavapoo', 'small', 'curly'),  # not on Jess's list
    ('Cockapoo (small)', 'small', 'curly'),  # not on Jess's list
    ('Hungarian Pumi', 'small', 'curly'),
    ('Schnoodle', 'small', 'curly'),  # not on Jess's list

    ('Basset Fauve De Bretagne', 'small', 'wire'),
    ('Basset Griffon Vendeen (Petit)', 'small', 'wire'),
    ('Border Terrier', 'small', 'wire'),
    ('Cairn Terrier', 'small', 'wire'),
    ('Cesky Terrier', 'small', 'wire'),
    ('Dachshund (wire haired)', 'small', 'wire'),  # not on Jess's list
    ('Dandie Dinmont Terrier', 'small', 'wire'),
    ('Fox Terrier (wire)', 'small', 'wire'),
    ('Glen of Imaal Terrier', 'small', 'wire'),
    ('Irish Terrier', 'small', 'wire'),
    ('Lakeland Terrier', 'small', 'wire'),
    ('Miniature Schnauzer', 'small', 'wire'),
    ('Norfolk Terrier', 'small', 'wire'),
    ('Norwich Terrier', 'small', 'wire'),
    ('Scottish Terrier', 'small', 'wire'),
    ('Sealyham Terrier', 'small', 'wire'),
    ('Standard Schnauzer', 'small', 'wire'),
    ('Welsh Terrier', 'small', 'wire'),
    ('West Highland White Terrier', 'small', 'wire'),

    # ── Toy (under 5kg) ────────────────────────────────────────────────
    ('Chihuahua (smooth coat)', 'toy', 'smooth'),
    ('Chinese Crested', 'toy', 'smooth'),
    ('Russian Toy', 'toy', 'smooth'),

    ('Schipperke', 'toy', 'short double'),

    ('Australian Silky Terrier', 'toy', 'long double'),
    ('Bolognese', 'toy', 'long double'),
    ('Chihuahua (long coat)', 'toy', 'long double'),
    ('Chinese Crested (Long Haired)', 'toy', 'long double'),
    ('Coton de Tulear', 'toy', 'long double'),
    ('Havanese', 'toy', 'long double'),
    ('Japanese Chin', 'toy', 'long double'),
    ('King Charles Spaniel', 'toy', 'long double'),
    ('Lhasa Apso', 'toy', 'long double'),
    ('Maltese', 'toy', 'long double'),
    ('Papillon', 'toy', 'long double'),
    ('Pekingese', 'toy', 'long double'),
    ('Pomeranian', 'toy', 'long double'),
    ('Yorkshire Terrier', 'toy', 'long double'),

    ('Bichon Frise', 'toy', 'curly'),
    ('Maltipoo', 'toy', 'curly'),  # not on Jess's list
    ('Poodle (toy)', 'toy', 'curly'),
    ('Shihpoo', 'toy', 'curly'),  # not on Jess's list
    ('Zuchon (Shih Tzu x Bichon)', 'toy', 'curly'),  # not on Jess's list

    ('Affenpinscher', 'toy', 'wire'),
    ('Australian Terrier', 'toy', 'wire'),
    ('Griffon Bruxellois', 'toy', 'wire'),

    # ── Fallbacks for crosses and unknowns ─────────────────────────────
    ('Crossbreed (small)', 'small', ''),
    ('Crossbreed (medium)', 'medium', ''),
    ('Crossbreed (large)', 'large', ''),
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

        for name, size, coat in BREEDS:
            minutes, price = PRICING[(size, coat)]
            defaults = {
                'coat_type': coat,
                'avg_groom_minutes': minutes,
                'avg_price': Decimal(price),
                'avg_schedule_weeks': SCHEDULE_WEEKS[coat],
                'notes': SIZE_LABELS[size],
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
        if skipped and not overwrite:
            self.stdout.write(self.style.WARNING(
                f'{skipped} existing breeds kept their old times and prices. '
                'Run with --overwrite to move them onto the current price list.'
            ))
        self.stdout.write(self.style.WARNING(
            "Prices and times are Jess's own; which size/coat band a breed sits "
            'in, and the interval between grooms, are estimates - have her check '
            'them in Settings, Breeds.'
        ))
