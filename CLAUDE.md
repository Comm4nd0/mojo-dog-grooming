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
  auth_backends.py    sign in with a username or an email, either case
  passwords.py        issuing, addressing and delivering reset links
mojo_backend/         settings, urls, wsgi
templates/
  base.html           shared shell for every server-rendered page
  intake/             the new-client form
  account/            the password reset page
mobile/lib/
  constants/          app_colors.dart — brand palette and theme
  models/             models.dart — API payload types
  services/           api_client, auth_service, biometric_service, data_service, service_locator
  screens/            login_screen, lock_screen, account_switcher
  screens/staff/      doguments, dog/client profiles, calendar, timers, invoices, equipment, logins
  screens/client/     my dogs, my bookings, my profile, claim profile
  widgets/            common.dart, dog_silhouette.dart, biometric_toggle.dart
```

## Commands

Backend:
```bash
python manage.py migrate && python manage.py seed_breeds
python manage.py test api        # 150 tests
python manage.py runserver 0.0.0.0:8000
python manage.py accounts        # who can sign in — usernames live only in the DB
python manage.py reset_link jess # a way back in when the superuser is locked out
```

Mobile:
```bash
cd mobile && flutter pub get
flutter analyze && flutter test  # 62 tests
flutter run --dart-define=MOJO_API_BASE=http://192.168.1.20:8000/api
```

Deploy:
```bash
./deploy.sh                      # backend, to the Hetzner host
./tools/release.sh 1.11.0        # the app, to the App Store — see RELEASING.md
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

## Getting back in is a separate problem from getting in

There is no SMTP configured on the box and there never has been — intake links
have always been pasted into a message by hand. Password recovery follows the same
shape rather than inventing a second one:

- A **superuser** issues a single-use link (More → Logins). The response carries the
  link so it can be sent however suits, and emails it as well when `EMAIL_HOST` is
  set. `EMAIL_ENABLED` is reported to the app so it can say "copy this and send it"
  instead of claiming an email is on its way that nobody will receive.
- The link is returned **exactly once**, in the response that creates it.
  `PasswordResetTokenSerializer` has no field for the token and the admin excludes
  it. A link readable back out of the API is a link a stolen staff session can read.
- A locked-out client asks from the login screen. That creates a
  `PasswordResetRequest` for Jess — **not** an automatic email — and the public
  endpoint answers identically whether or not the identifier matched. Confirming
  "no such account" would make it a way to find out who Jess's clients are.
- Issuing voids the account's outstanding links; using one deletes the account's
  DRF tokens, because a reset is usually "someone else has my password" and changing
  it alone leaves their session working.
- `IsSuperUser`, not `IsAdminUser`. `is_staff` opens the management surface; handing
  out a reset link takes over an account, so it sits with the `UserProfile`
  capability flags on the superuser side.

Two traps met on the way:

- **`ScopedRateThrottle` reads its scope off the view on every request**, so a scope
  assigned to a throttle instance in `get_throttles()` is silently discarded and the
  limit never applies. `ForgottenPasswordThrottle` is a subclass with a fixed scope
  instead — putting `throttle_scope` on the viewset would have applied 5/hour to the
  superuser reading the queue as well.
- **Loading the reset page and submitting it use separate throttle scopes**, exactly
  as intake does, and for the same reason.

Usernames exist only in the database — from `createsuperuser` or
`DJANGO_SUPERUSER_USERNAME`. `manage.py accounts` lists them; `manage.py reset_link`
covers the one case the in-app flow cannot, the superuser being the one locked out.

## Biometric unlock is a local gate, not authentication

`local_auth` guards the app, not the API. The token is already in the Keychain /
EncryptedSharedPreferences and is what actually authenticates; a fingerprint prompt
does not re-authenticate against Mojo and Co and cannot revoke anything. What it
buys is that an unlocked phone handed across the salon counter does not show a
client list. Say that plainly rather than implying more.

The preference is **per account**, on `SavedAccount`, so Jess can lock her staff
login while the test client login she flips into all day stays open.

Four things that have to stay true:

- `AuthService.restore()` sets the lock **before** the `/users/me` call and returns a
  placeholder identity built from stored data. Fetching records and then hiding them
  is not a lock.
- `_rememberActive()` carries `biometricsEnabled` across. It runs after every
  successful `/users/me`, including the one right after unlocking, so rebuilding the
  entry without the flag makes the lock work exactly once and then stop silently.
  There is a test for this.
- `switchTo()` prompts for an account that asked for it — otherwise the account
  switcher walks straight past the lock.
- `LockScreen` always offers "Use a password instead". An account behind a check
  that cannot pass, with no escape, is an account nobody can reach again. Turning
  biometrics *on* prompts first for the same reason.

Android needs `FlutterFragmentActivity` (the plugin's prompt is a fragment; on a
plain `FlutterActivity` it builds fine and fails at the first unlock) and iOS needs
`NSFaceIDUsageDescription`.

## The intake form is a web page, not an app screen

`/intake/<token>/` is server-rendered HTML (`templates/intake/`), not a Flutter screen. That is
deliberate: the recipient is a brand-new client who has not signed up for anything and has no
app installed, so a link into the app would be useless to them. The page posts JSON to
`/api/intake/<token>/`, so validation, single-use and expiry all stay in the tested API.

The page inlines `mobile/assets/dog_silhouette.svg` read straight off disk, so the web form and
the app can never drift onto different-shaped dogs. `describe()` in `form.html` and
`describeCell()` in `dog_silhouette.dart` label the same grid and must stay in step.

`/reset/<token>/` is a web page for the same reason, and shares `templates/base.html` with it.

Two things that bite on this page specifically:
- The grid `<rect>`s share the artwork's 2605-unit viewBox, so `stroke-width: 1` renders at
  about **0.12 CSS px** — invisible. They need `vector-effect: non-scaling-stroke`.
- Loading the page and submitting it use **separate throttle scopes**. Sharing one would let
  ordinary reloading exhaust the budget and lock a client out of sending their details.

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
still reads as a dog and the grid still lands on the right anatomy. Never run
`--update-goldens` to make a red test go green: a missing asset renders as a bare grid with no
error, and regenerating would bake the dogless version in permanently. The
`the artwork is actually painted` test is a golden-independent backstop against exactly that.

Cells come out around 26 x 25dp on a phone, under the 44-48dp both platforms recommend for a
touch target, so **dragging paints** across cells rather than requiring a separate accurate tap
each. The gesture uses `DragStartBehavior.down`; the default reports the position *after* the
~18dp touch slop, which skips the cell the user actually pressed. Cells accumulate in the
widget's own state during a drag, because several pointer moves can land in one frame and
reading the parent's selection each time would drop all but the last.

## A tag is the release

Pushing to `main` goes to TestFlight. Pushing a `v1.11.0` tag goes to customers —
Xcode Cloud builds it, `.github/workflows/release.yml` waits for the upload to finish
processing, writes "What's New" from `CHANGELOG.md`, and submits for review with
`releaseType: AFTER_APPROVAL`. Cut one with `./tools/release.sh`; the full setup is in
`RELEASING.md`.

Three things about this that are not obvious:

- **The version users see comes from `pubspec.yaml`**, through `$(FLUTTER_BUILD_NAME)`
  in `Info.plist`. `MARKETING_VERSION` in the Xcode project is on the *test* target and
  ships nothing. pubspec said `0.1.0` while `1.9.13` was live, so any release built from
  it would have been rejected — App Store Connect will not take a version string below
  the one already out.
- **Build numbers are minutes since 2026-01-01, not `CI_BUILD_NUMBER`.** That variable
  counts per Xcode Cloud workflow, so the TestFlight and Release workflows each start at
  1 and collide, and Apple rejects a build number it has seen before for a version.
- **Submission runs on a Linux runner, not in Xcode Cloud.** A fresh upload sits in
  PROCESSING for minutes to half an hour and nothing can be attached to a version until
  it finishes. Xcode Cloud bills that wait and times out.

The tag, `pubspec.yaml` and the `CHANGELOG.md` heading must agree — both CI scripts stop
rather than ship a binary whose version contradicts its tag.

Android is not shippable: `build.gradle.kts` signs release builds with the debug key.

## Host constraints

The Hetzner box runs eleven projects in under 4 GB. `docker-compose.prod.yml` sets `mem_limit`
on both containers and gunicorn runs 2 workers for that reason. `deploy.sh` refuses to build
below 500 MB free. Don't raise these without checking `free -m` first.
