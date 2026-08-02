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
docs/
  paper-cards.md      Jess's three paper forms, transcribed — the spec for the online ones
templates/
  base.html           shared shell for every server-rendered page
  intake/             the new-client form, and the policies sheet it makes you agree to
  account/            the password reset page
mobile/lib/
  constants/          app_colors.dart — brand palette and theme
  models/             models.dart — API payload types
  services/           api_client, auth_service, biometric_service, data_service, service_locator
  screens/            login_screen, lock_screen, account_switcher
  screens/staff/      doguments, dog/client profiles, calendar, timers, visit records,
                      invoices, services, equipment, to-dos, documents, logins
  screens/client/     my dogs, my bookings, my profile, claim profile
  widgets/            common.dart, dog_silhouette.dart, biometric_toggle.dart,
                      searchable_picker.dart, duration_picker.dart,
                      contact_actions.dart, temperament_picker.dart,
                      service_picker.dart
  widgets/calendar/   the time-axis diary — metrics, layout, painter,
                      day and week timelines
```

## Commands

Backend:
```bash
python manage.py migrate && python manage.py seed_breeds
python manage.py test api        # 297 tests
python manage.py runserver 0.0.0.0:8000
python manage.py accounts        # who can sign in — usernames live only in the DB
python manage.py reset_link jess # a way back in when the superuser is locked out
```

Mobile:
```bash
cd mobile && flutter pub get
flutter analyze && flutter test  # 144 tests
flutter run --dart-define=MOJO_API_BASE=http://192.168.1.20:8000/api
```

Deploy:
```bash
git push origin main             # backend — this is the deploy, see below
./deploy.sh --yes                # the same thing by hand, on the host
./tools/backup.sh                # db + private-media + media + .env, on the host
./tools/release.sh 1.0.0        # the app, to the App Store — see RELEASING.md
```

## Three rules that matter

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

**3. Read scoping is not write permission.**
`StaffWriteOnlyMixin` in `api/views.py` refuses `perform_update`/`perform_destroy` to non-staff
on `DogViewSet`, `ClientViewSet` and `DogPhotoViewSet`. This is a *third* layer, not a restating
of rule 2, and the reason is that rule 2 works against it: scoping deliberately puts a client's
**own** rows in their queryset — that is how they read them — so `get_object` finds them and any
unguarded `PATCH`/`DELETE` goes straight through.

Every one of these viewsets guarded `perform_create` and stopped, which is why the gap was
invisible: the surface looked covered. What it cost, until it was closed — a client could
`PATCH` their own dog to set `price` to `0.00`, repoint `client` at somebody else's record, or
`DELETE` the dog and cascade its appointments, photos, documents, problem areas and groom
sessions. On `Client` it bypassed the whole `ClientChangeRequest` review flow, which exists
precisely so those fields are *not* editable unreviewed.

`perform_create` stays per-viewset: what counts as a legitimate create differs by model (a
client may *request* an appointment but not add a dog). DRF routes PUT and PATCH both through
`perform_update`, so the two hooks cover all three verbs.

The tests are in `PrivilegeEscalationTests`, and the shape of the old gap is worth remembering:
it tested dog *creation* and appointment edit/delete, never dog or client edit/delete. A test
class that covers four of six verbs reads exactly like one that covers all six.

Related: `ClientClaimRequestSerializer` gates `matched_client`/`matched_client_name` as
staff-only. Registration is open, so echoing the suggested match back to the claimant would turn
that endpoint into a lookup for whether a given email or surname+postcode belongs to one of
Jess's clients — and hand back their full name. Same rule `PasswordResetRequestViewSet` already
follows by answering identically whether or not the identifier matched.

`UserRateThrottle` (`user: 600/min`) exists for the same family of reasons rather than for
brute-forcing: `claim-requests`, `client-change-requests` and `appointments` each put a row in
front of Jess, and every scoped rate before it was anonymous-only, so a signed-in account was
unlimited. It is an abuse ceiling, not a quota — the diary alone fires several calls a screen.

## Temperament: five grades, frozen codes, wording Jess owns

Jess asked for five handling grades rather than three — *"can all five different
temperament's be shown (may up bitey not hard etc.)"* — because the old middle grade,
"Fidgety / bitey", was doing two jobs. `WRIGGLY` and `BITEY` were added in `0007`;
`FIDGETY` kept its code and lost "/ bitey" from its wording.

**The five names we shipped are our reading of that one line, so they are not in the code.**
`TemperamentGrade` (was `TemperamentLimit`) carries `label`, `max_per_day` and `sort_order`,
and Jess renames grades in Settings → How dogs handle. Two consequences that are easy to get
wrong:

- **Never call `get_temperament_display()`.** It returns the frozen labels on the
  `Temperament` enum, which are seed defaults only, and will silently contradict whatever Jess
  has on screen. Use `temperament_label(code)`, or the serializers' `temperament_display`.
  Same on the Flutter side: `TemperamentGrade.label` or the server's `temperament_display`,
  never a hardcoded string.
- **The codes are permanent.** Every `Dog.temperament` and `GroomSession.temperament_observed`
  stores one, so a label is a word but a code is history. `TemperamentGradeSerializer` makes
  `temperament` read-only and the viewset refuses DELETE for exactly this reason — a deleted
  grade leaves every dog carrying its code with nothing to render.

Labels are cached (`TemperamentGrade.labels()`, 5 minutes) because a list of dogs renders one
per row. `save()`/`delete()` invalidate it; a queryset-level `.update()` would not, which is
what the short TTL is for.

The two new grades seeded with **no cap**. Interpolating between the old 2 and 1 would invent
a rule Jess never set, and an invented limit is indistinguishable from a real one once it is
in the table — the same reasoning as `nail_visit_price` and migration `0006`.

`0007` also makes `Dog.is_neutered` nullable, so the profile's intact/done tag can stay
silent. See the rule below.

## Null is not false

Several fields have three states, and coercing the third to `false` has caused a real bug
every time it has been done. `Dog.is_neutered` was the latest: it defaulted to `False`, so a
dog nobody had asked about was stored identically to one confirmed entire, and Jess's
"intact / done" tag would have labelled every one of them **Intact**.

The complete list, all nullable, all meaning "never asked" when null:
`Client.photo_consent`, `GroomSession.bathed_well_behaved`, `Dog.is_neutered`, and every
staff-only field withheld from a client.

On both sides of the wire:
- Django — nullable, and nothing coerces on the way in. `IntakeSubmissionViewSet.approve`
  reads through `_tristate()`; it used to do `bool(entry.get('is_neutered', False))`, which
  put "didn't say" straight back to "intact".
- `templates/intake/form.html` — a checkbox cannot express three states, so it is three
  radios, **none pre-selected**. A pre-ticked "Not sure" is as invented as a pre-ticked "No".
- Dart — `bool?`, never `json['x'] == true`. The form control is a three-way
  `SegmentedButton`, not a switch.

## Warnings never block

Jess's notes are explicit: *"warn when exceeding temperament booking limits, but don't prevent
booking."* The same applies to opening hours and overlaps. `POST /api/appointments/check/`
returns a `warnings` array; the app shows them in a confirm dialog with "BOOK ANYWAY" always
available. `api/scheduling.py` produces warnings and never raises.

## Breeds price off a grid, not per breed

Jess sent her real price list on 28 July 2026 (email "Fwd: Data input", three PDFs attached).
She prices by **size band × coat type**, not per breed: five bands (Colossal 45kg+, Large,
Medium, Small, Toy) × five coats (smooth, short double, long double, curly, wire). That grid is
`PRICING` in `api/management/commands/seed_breeds.py`; the 224 rows in `BREEDS` each just name
a cell. Change a price in the grid and every breed in that band follows.

Two things in there are still estimates, and the docstring says which:

- **Which cell a breed sits in.** Her list gives each breed's size band but only *implies* the
  coat by the order she typed them in, and the order breaks down in places — so the coat is our
  reading of the breed. Wrong cell means wrong price.
- **`avg_schedule_weeks`.** Her list has no intervals at all; `SCHEDULE_WEEKS` derives one from
  the coat.

Breeds she didn't list — the poodle crosses, Pug, Jack Russell, Dachshunds, Border Collie,
Golden Retriever — are marked `# not on Jess's list` and their band is a guess.

One breed is deliberately **not** where her list put it: she had **German Spitz** in Colossal
(45kg+, £140), but the Klein is 5-8kg, the Mittel 10-11kg, and the giant variety is the
Keeshond, which she lists separately in Medium. It sits in Medium here, at £70. That is the only
band overridden, and the comment beside it says why.

**`entrypoint.sh` runs `seed_breeds` without `--overwrite` on every boot**, so a price change
in the grid reaches new breeds only. Moving the ones already in the database onto it takes a
one-off `docker compose exec web python manage.py seed_breeds --overwrite` on the host — and
that also discards any edit Jess has made in the app, which is the whole reason it isn't the
default.

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

### Light and dark are both first-class

The palette above is the *light* half. Anything whose correct value depends on the background
it lands on is a **role**, not a constant, and lives on `MojoPalette` — a `ThemeExtension` in
`app_colors.dart` read through `context.mojo`:

| Role | Use | Light | Dark |
|---|---|---|---|
| `muted` | captions, inactive icons | `#5E5E5E` | `#B0B0B0` |
| `accent` | brand green for text/icons on the page | `#01821B` | `#02D42C` |
| `tint` | solid pale-green block (avatars, today's cell) | `#D2FFD4` | `#015412` |
| `onTint` | text/icons drawn on a `tint` block | `#01821B` | `#02D42C` |
| `tintWash` | faint band behind a profile header | `#EDFFEE` | `#16301A` |
| `hairline` | borders, dividers, input outlines | `#E2E2E2` | `#2E2E2E` |

Do not reach for `AppColors.inkSecondary`, `surfaceTint`, `hairline`, or bare `primary` as a
foreground in a widget — those are the light values, and using them directly is what made the
app unreadable in dark mode. The deep green in particular is about 2:1 on `#121212`.

**The five temperament colours are a role too**, for the same reason: the badge draws the
grade's name *as text* in its colour on a 12%-alpha wash of itself, and the original three
were only ever checked on white — on the dark scaffold they came out between 3.1:1 and 3.9:1.
Read them through `context.temperamentColour(code)`, never `AppColors.temperamentColor`
directly, which defaults to the light set. An unknown code returns **grey, not the easy
green**: a phone on an older build talking to a newer server would otherwise paint a bitey
dog reassuringly green, and that is how somebody gets bitten.

`AppColors.display()` deliberately leaves its colour **null** so `Text` inherits `onSurface`
from the theme. It used to default to `ink`, which is why the login wordmark and every screen
title were invisible in dark mode — near-black on near-black. Never give it a default again.

`templates/base.html` mirrors the same roles as CSS variables, and its
`prefers-color-scheme: dark` block must override `--green`, `--tint` and `--error` as well as
the neutrals, for exactly the same reason. Every server-rendered page extends it — the intake
form and the password-reset pages both — so a role fixed there is fixed for all of them.

`test/theme_test.dart` holds the line: display text must resolve to the theme's colour, and
every role must clear WCAG AA against the surface it is used on.

### The admin wears the same palette

`api/static/mojo/admin.css`, pulled in by `templates/admin/base_site.html`, which **shadows**
the file of that name inside `django.contrib.admin`. It is almost entirely a redefinition of
Django's own custom properties, because the admin already drives every surface off them.

- **The three-block structure is copied from Django and has to stay.**
  `html[data-theme="light"], :root` / `@media (prefers-color-scheme: dark) { :root }` /
  `html[data-theme="dark"]`. The admin's theme toggle writes `data-theme` on `<html>`, and
  `html[data-theme="dark"]` outranks a bare `:root`, so a light value written only as `:root`
  loses to `dark_mode.css` for anyone who has picked a theme. Every variable `dark_mode.css`
  sets must be set again in **both** dark blocks or its Django-blue value survives.
- **Several variables do two unrelated jobs, and that constrains the value.** `--header-bg` is
  not just the page header, it is the caption bar on every module and inline group, which is
  why the admin keeps a green bar where the web pages use a white one. `--breadcrumbs-fg` is
  reused as a foreground *on* `--primary` by the filter widget, so it cannot be the deep green.
  `--accent` is the wordmark colour **and** the calendar caption's background under text Django
  hardcodes to `#333`, so it has to be the pale tint in dark mode too. Changing one of these to
  suit the surface you are looking at will break the other one somewhere you are not.
- Square corners are one `* { border-radius: 0 !important }`. Django sets a radius in seven
  stylesheets plus a vendored select2, several above any sane specificity — this is a
  deliberate `!important`, not a lazy one.
- `ApiConfig.verbose_name` is what stops the index and every breadcrumb reading **"API"**.

`AdminSkinTests` in `api/tests.py` is the guard, and what it guards is the shadow going stale:
a Django upgrade that restructures the `branding` or `extrastyle` blocks would silently drop
the branding and leave the default blue, with nothing failing until Jess opened it. It also
asserts the stylesheet is somewhere `collectstatic` will find it — `{% static %}` renders a
link to a missing file quite happily, and production has manifest storage and no `runserver`
fallback to cover for it.

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

The page is written against Jess's paper Grooming Booking Card, transcribed in
`docs/paper-cards.md` along with the two ongoing record cards. That file is the spec — read it
before changing what the form asks.

## Consent is a row, not a boolean

The paper card carries six disclaimers, "each signed and dated". They are `Consent` rows
against the client (`ConsentKind` in `api/models.py`), not flags on `Client`, for two reasons:
what somebody agreed to **on the day** is the record, and policy wording changes — a boolean
would quietly claim they had agreed to whatever the current text says. Each row stores the
wording it was signed against. Withdrawing agreement is a *new row*; nothing is edited or
deleted, and the admin inline is deliberately read-only.

- **Five of the six are required, `PHOTOS` is not.** It is the only one the card phrases as a
  question, and declining it must still let the form through. `REQUIRED_CONSENTS` is the list.
- **`Client.photo_consent` is nullable and null means "never asked"** — not "no". Anything
  about to publish a photo must treat null as don't. Same rule as the staff-only fields above,
  and `photoConsent` in `models.dart` deliberately does not coerce a missing key to `false`.
  There are tests on both sides.
- **The required set is enforced in `PublicIntakeSubmissionSerializer`, not just in the page's
  JavaScript.** The intake endpoint is public; a disclaimer only the browser checks is not a
  disclaimer.
- Consents ride on the submission as JSON and only become rows at approval, exactly like the
  dogs do — and they keep the *submission's* timestamp, not the approval's.

`templates/intake/policies.html` is page 2 of the card reproduced verbatim, typos and all. It
is a policy document; do not tidy the wording.

## One visit record, two cards

Jess keeps two paper record cards — "Ongoing Record for Dogs" and "Ongoing Record for Nails /
Flee / Ticks" (`docs/paper-cards.md`). Both land on **`GroomSession`**, told apart by
`visit_type`. One model rather than two because the cards are the same shape and hers are filed
per dog: splitting them would split a dog's history in half. The screen is
`visit_record_screen.dart`, and which fields it shows is driven by the type.

Neither card is client-facing. `GroomSessionViewSet` is `IsAdminUser` for the whole endpoint —
that is the gate, not field-level masking.

Things worth knowing:

- **`recorded_minutes` overrides the phase total.** A nails visit runs no timer, and Jess
  sometimes forgets to start one on a groom. `total_minutes` prefers it when set.
- **`apply_to_dog()` refuses a nails visit.** Twenty minutes is how long a nail trim takes;
  writing it to `Dog.groom_minutes` would book the next full groom into a twenty-minute slot.
- **`temperament_observed` deliberately does not write back to `Dog.temperament`.** That field
  drives the per-day booking limits, and one rough afternoon should not silently change how
  many dogs Jess can take.
- **`bathed_well_behaved` is nullable.** "Not bathed" and "bathed and hated it" are different
  things. Same rule as everywhere else here: null is not false, on both sides.
- **`final_body` / `final_feet` / `final_tail` are what was *done*.** The `pref_*` fields on the
  dog are what the owner asked for at intake. Do not conflate them.

## Services are a catalogue; ServiceType is still the category

Jess listed thirteen things she does — Full Groom, Nail Clipping, Hand Stripping and the
rest. They are `Service` rows, seeded by `seed_breeds`. A dog carries `default_services`
(what it usually has); an appointment carries `services` (what is being done), and that
drives the length and the quote through `resolve_slot()`.

**`ServiceType` was not replaced by it**, and must not be. It stays as the coarse category
for three reasons: `GroomSession.visit_type` is a *paper-card discriminator* and one model
exists precisely so a dog's history isn't split; `apply_to_dog()` needs something to hang a
guard off; and keeping it makes the whole thing additive — **an appointment with no services
resolves byte-identically to one from before the catalogue existed**, which is the property
that let it deploy ahead of the app build.

Four things that are easy to get wrong:

- **`Appointment.save()` cannot read `self.services`.** On a create there is no pk yet, and
  DRF sets many-to-manys *after* `.save()`. Resolution happens in `apply_service_defaults()`,
  called once the relation exists — from the serializer, from `BookingSeriesViewSet._materialise`
  and from the admin's `save_related()`. Miss `_materialise` and a standing nail-trim series
  blocks out three hours a fortnight forever.
- **`save()` only defaults on insert.** It used to default on every save, so
  `apply_service_defaults` would carefully work out "no price" and `save()` would immediately
  replace it with the dog's groom price — quoting £50 for an unpriced service.
- **`apply_to_dog()` guards on more than the visit type now.** Before the catalogue a GROOM
  visit was always a whole groom; a 25-minute Tidy Up is one too, and letting that overwrite
  a 105-minute `Dog.groom_minutes` is the old bug in a new coat.
- **Every price and duration seeds blank** except Full Groom, which takes the dog's. Her price
  list covers full grooms only. `get_or_create(code=...)` means a price she sets survives a
  redeploy, and unlike breeds, **`--overwrite` must not touch price or duration** — for breeds
  the grid is her source of truth, for services she is.

`Dog.default_services` is **not** staff-only: it is what the owner asked for, and a client
needs it to request the right kind of booking.

## The diary is a time axis, not a list

Jess: *"have it blocked out, as booking in multiple dogs it's a bit hard to continue booking
without seeing the blocked out time for the clash, if you could hold to 'slide' a blocked out
groom up and down"*. `widgets/calendar/` is that, built rather than pulled in.

No package, deliberately. Every candidate imposes its own rounded-corner theming on an app
whose brand rule is square, and — decisively — they expose `onDragEnd(newTime)` as
accept-or-revert, which cannot express *show the server's warnings and move it anyway*.

- `timeline_metrics.dart` — one `scale` drives every dimension. **72dp an hour** at scale 1.0;
  a 20-minute nail visit clamps to `minBlockHeight` (26dp) so it stays tappable, a lie of
  under two minutes of axis. Drags snap to **5** minutes, not 15 — she books 09:10.
- `timeline_layout.dart` — pure, and the part worth testing directly. Overlapping bookings
  form clusters and take lanes by **greedy first-fit**: each takes the lowest-numbered lane
  free by the time it starts. Get that wrong and 09:00–10:00 / 09:30–10:30 / 10:15–11:00 looks
  three deep when it is only ever two. ≤3 lanes cascade at 18dp so the earlier block's leading
  edge stays visible (Jess's "still able to overlap a bit"); beyond that they split evenly.
- Dragging is **not** `LongPressDraggable` — its feedback follows the finger in two dimensions
  and cannot snap, so the block floats free then teleports. `Positioned.top` is driven from
  state instead.
- **Week view is read-only.** At ~49dp columns a two-axis drag is a coin flip between "move to
  Tuesday" and "move 30 minutes", and Jess's own framing splits them: week to see, day to
  slide.

`next_available_slots()` in `scheduling.py` is her "next available appointment". It is the
first code ever to read `AppSettings.booking_slot_buffer_minutes` — that setting existed from
the start with no screen and no reader, which is exactly how it stayed dead; Settings now has
a row for it. It returns `reason: 'no_opening_hours'` when the table is empty, because an
empty list would read as "fully booked" when the real answer is "set your hours up".

## Scanned paperwork is not a photo

`DogDocument` is a separate model from `DogPhoto`, and its files live in
`PRIVATE_MEDIA_ROOT` — a **sibling** of `MEDIA_ROOT`, never a child.

Caddy serves `/media/*` with `file_server` and no authentication whatsoever. A dog photo is
low stakes; a scanned intake form carries the client's name, address, postcode, phone,
emergency contact, vet and **signature**, and obscurity fails the moment a URL lands in a
browser history or a screenshot. They go out through a gated download view instead, and the
serializer never emits `file` — a `FileField` would serialise a `MEDIA_URL` path that 404s but
still discloses the layout.

Uploads are checked by **magic bytes, not the browser's content type**, SVG is refused
outright (scriptable, and inline rendering would be stored XSS on the API's own origin), and
`upload_to` produces a random token so the filename cannot leak a client's name into a log.

Three deployment facts:

- `docker-compose.prod.yml` mounts `./private-media` and Caddy must **not**.
- `.dockerignore` excludes it, and that is load-bearing. `Dockerfile` ends in `COPY . .`, and on
  the host the build context *is* the directory the compose file bind-mounts out of — so without
  it every image layer carries the scanned forms, which is the same disclosure the sibling
  directory, the gated view and the random `upload_to` token all exist to prevent.
- `tools/backup.sh` covers it. It used to be backed up by nothing at all: the pre-deploy dump was
  database only. The same script covers `media/` and `.env` — a good SQL dump cannot bring the
  app back without the secret key and database password.

`.dockerignore` excludes `mobile/build|.dart_tool|ios|android|test` but **not `mobile/assets/`**,
because `load_silhouette_svg` reads `dog_silhouette.svg` off disk **at runtime**. Excluding
`mobile/` wholesale fails silently — the loader catches `OSError` and returns `''`, so the intake
page renders with no dog and nothing in the log. Listed as individual subdirectories rather than
`mobile/` plus a `!` re-inclusion for exactly that reason.

One trap found by its own test: **DRF turns a missing boolean into `False` for multipart form
data.** `visible_to_client` arrived `False` on every upload, so every document Jess filed would
have been invisible to the client — silently, and the opposite of the point.
`AbsentMeansDefaultBooleanField` exists for that.

## A nails visit is not priced off the breed grid

`ServiceType` on `Appointment` splits `GROOM` from `NAILS`. The grid in `seed_breeds.py` prices
full grooms only, and **Jess's price list has nothing for a nail trim at all** —
`AppSettings.nail_visit_minutes` and `nail_visit_price` carry it instead.

**Both are null until she sets them in Settings → Nails, fleas and ticks, deliberately.** A
made-up default is indistinguishable from a real figure once it is in the database, and a wrong
price on an invoice is worse than a blank to fill in. So:

- `price_quoted` stays **null** on a nails booking until she has set one; nothing invents it.
- `unpriced_service_warning()` in `scheduling.py` warns that it isn't set. It is a *warning* —
  the booking still goes through, same as every other rule in that file.
- `FALLBACK_NAIL_VISIT_MINUTES` (20) exists only so an unset slot has *some* length; a
  zero-minute block would be invisible in the diary. It is never used as a price.
- On the Flutter side both are `int?`/`num?` and the screen shows "Not set". Never render a
  null as a price.

`Appointment.save()`, `booking_warnings()` and `/api/appointments/check/` all branch on the
service type. Miss one and a nail trim blocks out three hours and quotes £80.

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

## A push to main is the backend deploy

`.github/workflows/deploy.yml` SSHes into the Hetzner host and runs `./deploy.sh --yes`
after the `Tests` workflow goes green. Same shape as `luma-tech-solutions` on the same
box, deliberately — one pattern to learn rather than two. `./deploy.sh` by hand still
works and is still the first-deploy path.

Four things about it that are not obvious:

- **The gate is `workflow_run` on the whole `Tests` workflow**, not a copy of its backend
  job. A second copy of the test setup is a second thing to keep in step. The price is
  that a red *mobile* job blocks a backend deploy too, because `workflow_run` cannot wait
  on one job — `workflow_dispatch` is the escape hatch when you need to ship past a
  failing golden test.
- **`deploy.sh` must never `read` from a stdin it doesn't own.** CI pipes the remote
  script in over SSH, so the low-memory prompt's `read` would have swallowed the next
  line of the deploy and carried on with a mangled one. It now takes `--yes`, and
  refuses outright when stdin is not a terminal rather than reading anyway.
- **The health check needs `X-Forwarded-Proto: https` to mean anything.**
  `DJANGO_SECURE_HTTPS` turns on `SECURE_SSL_REDIRECT`, and `curl -f` does *not* fail on
  a 3xx, so the old check passed on the redirect alone — true of a container that boots
  and then 500s on every request. It now matches the `{"status": "ok"}` body. The smoke
  test also runs `migrate --check` in the web container, because neither `/api/health/`
  nor the admin login page touches the database and both would pass with Postgres down.
- **Rollback restores the code, not the database.** It `git reset --hard`s to the
  recorded SHA and redeploys — `reset`, not `checkout`, so the clone stays *on* main and
  the next push fast-forwards instead of merging into a detached HEAD. `entrypoint.sh`
  runs `migrate --noinput` on every start, so a failed deploy can leave a new schema
  under old code. `tools/backup.sh` runs into `/root/backups/mojo-dog-grooming` before
  every deploy (30 of each artefact kept) and has to be restored by hand.
- **`docker compose exec -T` will eat the deploy script.** The remote half is piped into
  `bash -se` over SSH, so stdin *is* the rest of the script — and `exec -T` hands the
  container that same stream. Both call sites (`pg_dump` in `tools/backup.sh`, `migrate
  --check` in the workflow) redirect `< /dev/null`. Without it the deploy half-runs, which
  is the same trap `deploy.sh` already documents for `read`.
- **The deploy is pinned to the tested commit.** `deploy.sh --ref <sha>` is passed
  `workflow_run.head_sha`; a bare `git pull origin main` takes whatever main is *now*, so
  two pushes in quick succession deploy the second, untested commit while reporting the
  first one's test result. Without `--ref` (by hand, or `workflow_dispatch`) it still pulls.

**Backups: two things that are still not true.** They live on the same disk as the live
Postgres volume, so one disk failure takes the data and every backup together — off-site
needs a destination and is deliberately not invented. And **no restore has ever been
rehearsed**, which means this is an untested backup. The procedure is at the foot of
`tools/backup.sh`. Backing up only on deploy also leaves a quiet fortnight a fortnight
behind, which is what the nightly cron in that header is for.

**Nothing was watching production before `SENTRY_DSN`.** A push to main deploys unattended,
so an unhandled 500 went to gunicorn's stdout, sat in `docker logs`, and surfaced when Jess
phoned. `sentry-sdk` is in `requirements-prod.txt`, not `requirements.txt` — that file is
pinned to match p4td and adding to it obliges the other project too — and settings.py never
imports it without a DSN. `send_default_pii` is **off and must stay off**: this app is almost
entirely personal data, and attaching request bodies and user details to every event would
copy Jess's client list to a third party by a different route.

## A tag is the release

Pushing to `main` goes to TestFlight. Pushing a `v1.0.0` tag goes to customers —
Xcode Cloud builds it, `.github/workflows/release.yml` waits for the upload to finish
processing, writes "What's New" from `CHANGELOG.md`, and submits for review with
`releaseType: AFTER_APPROVAL`. Cut one with `./tools/release.sh`; the full setup is in
`RELEASING.md`.

Three things about this that are not obvious:

- **The version users see comes from `pubspec.yaml`**, through `$(FLUTTER_BUILD_NAME)`
  in `Info.plist`. `MARKETING_VERSION` in the Xcode project is on the *test* target and
  ships nothing, so changing it there looks right and does nothing. Nothing has been
  released to the App Store yet; whatever `pubspec.yaml` says when the first tag is cut
  is what customers see for good, because App Store Connect will not take a version
  string below one already out.
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
