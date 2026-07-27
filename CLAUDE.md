# CLAUDE.md — Mojo and Co

Dog grooming management for **Mojo and Co** (mojoandco.uk), a one-groomer business run by
Jess Croll. Two audiences from one codebase:

- **Staff (Jess)** — clients and dogs, the diary, groom timers, photos, invoicing, equipment.
- **Clients** — their own details, their own bookings (read-only), appointment requests, intake form.

## Stack

| Part | Choice |
|---|---|
| Backend | Django 5.2 + DRF 3.15 + djoser (token auth), Python 3.11 |
| Database | SQLite in dev, PostgreSQL 16 in production |
| Mobile | Flutter (Dart 3.11), iOS + Android |
| Deploy | Docker Compose behind Caddy on the Hetzner host, port 8010 |

This mirrors `/root/p4td` on the same host (Paws 4 Thought Dogs — Django + Flutter for a dog
daycare business). Conventions were taken from there deliberately; if you're unsure how
something should be done here, look at how p4td does it.

## Layout

```
api/                  Django app — models, serializers, views, scheduling, tests
mojo_backend/         settings, urls, wsgi
mobile/lib/
  constants/          app_colors.dart — brand palette and theme
  models/             models.dart — API payload types
  services/           api_client, auth_service, data_service, service_locator
  screens/staff/      doguments, dog/client profiles, calendar, timers, invoices, equipment
  screens/client/     my dogs, my bookings, my profile, claim profile
  widgets/            common.dart, dog_silhouette.dart
```

## Commands

Backend:
```bash
python manage.py migrate && python manage.py seed_breeds
python manage.py test api        # 70 tests
python manage.py runserver 0.0.0.0:8000
```

Mobile:
```bash
cd mobile && flutter pub get
flutter analyze && flutter test  # 19 tests
flutter run --dart-define=MOJO_API_BASE=http://192.168.1.20:8000/api
```

Deploy:
```bash
./deploy.sh
```

## Two rules that matter

**1. Staff-only fields must never reach a client.**
`Dog.temperament`, `Dog.temperament_notes`, `ProblemArea`, `Client.chatty`,
`Client.leaflet_received` and `Client.notes` are Jess's private working notes.

They are removed by `StaffOnlyFieldsMixin` in `api/serializers.py`, which gates in
**`get_fields()`, not `__init__`**. This is not stylistic: a serializer declared as a nested
field (`ClientSerializer(source='client')` inside `DogSerializer`) is constructed at
class-definition time, before it has a request in its context, so gating in `__init__`
silently does nothing for nested serializers and leaks every staff-only field on the owner
block of a dog profile. `get_fields()` is evaluated lazily after binding, when
`self.context` resolves to the root's. There is a test for exactly this
(`test_nested_client_detail_on_dog_also_hides_fields`) — it caught the bug once already.

On the Flutter side these fields are **nullable**, and null means "the server withheld it",
not "unset". Never render one without a null check, and never coerce a missing key to `false`.

**2. Queryset scoping is a separate layer from field gating.**
`ClientScopedMixin` in `api/views.py` narrows every list and detail lookup to the requesting
user's own client record, so a client cannot address another client's row at all. Field gating
alone is not enough. Both layers must stay.

## Warnings never block

Jess's notes are explicit: *"warn when exceeding temperament booking limits, but don't prevent
booking."* The same applies to opening hours and overlaps. `POST /api/appointments/check/`
returns a `warnings` array; the app shows them in a confirm dialog with "BOOK ANYWAY" always
available. `api/scheduling.py` produces warnings and never raises.

## Breed data is estimated, not Jess's

`seed_breeds` loads ~93 breeds with groom times, prices and intervals written from general
grooming knowledge — **not** Mojo and Co's real figures. They exist so the app is usable on day
one. Settings → Breeds lets Jess edit them, and the screen says so. If she supplies a real
price list, replace the `BREEDS` table in
`api/management/commands/seed_breeds.py` and run `seed_breeds --overwrite`.

Dogs inherit from their breed unless overridden — always read `dog.effective_groom_minutes`,
`effective_price`, `effective_schedule_weeks`, never the bare field, which is null in the
common case.

## Brand

Sampled from the live site, not invented:

- `#01821B` deep green (headings, icons), `#02D42C` bright green (CTAs, **black** label only —
  white fails contrast), `#D2FFD4` pale green (chips, selected cells), `#151515` ink.
- **Playfair Display** for display text, **Montserrat** for UI.
- Buttons: uppercase, weight 700, letter-spacing 3.0, **square corners** — the site rounds
  nothing, and softening it reads as a different brand.

## The silhouette grid

Problem areas are stored as cell references over a fixed **12 × 8** grid on a side-profile dog
silhouette (`r{row}c{col}`, zero-indexed from the top-left). The dog is `mobile/assets/
dog_silhouette.svg`, rendered with `flutter_svg` and tinted at render time, so swapping it for
a different outline means replacing the file rather than regenerating code — see
`mobile/assets/ATTRIBUTION.md`.

`kGridColumns`/`kGridRows` in `mobile/lib/widgets/dog_silhouette.dart` **must** stay in step
with `ProblemArea.GRID_COLUMNS` / `GRID_ROWS` in `api/models.py`, which validates incoming
references. Changing either invalidates every problem area already stored.

The frame uses the artwork's own aspect (`kSilhouetteAspect`, 2605:1661.7) rather than 3:2, so
the dog fills the width instead of sitting letterboxed. Cells come out at about 1.05:1.

Unit tests can pass while the artwork fails to load or sits misaligned, so
`test/silhouette_golden_test.dart` renders it and compares pixels, in light and dark. After
deliberately changing the artwork or the grid:

```bash
cd mobile && flutter test --update-goldens
```

Then **look at** `test/goldens/*.png` before committing — that is the only check that the dog
still reads as a dog and the grid still lands on the right anatomy.

## Host constraints

The Hetzner box runs eleven projects in under 4 GB. `docker-compose.prod.yml` sets `mem_limit`
on both containers and gunicorn runs 2 workers for that reason. `deploy.sh` refuses to build
below 500 MB free. Don't raise these without checking `free -m` first.
