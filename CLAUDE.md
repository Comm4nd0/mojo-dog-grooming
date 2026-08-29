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
  services/           api_client, auth_service, biometric_service, data_service,
                      groom_timer_service, service_locator
  screens/            login_screen, lock_screen, account_switcher
  screens/staff/      doguments, dog/client profiles, calendar, timers, visit records,
                      invoices, services, equipment, to-dos, documents, logins,
                      medical_and_breeds (the reference shelf under More)
  screens/client/     my dogs, my bookings, my profile, claim profile
  widgets/            common.dart, dog_silhouette.dart, biometric_toggle.dart,
                      searchable_picker.dart, duration_picker.dart,
                      contact_actions.dart, temperament_picker.dart,
                      service_picker.dart, weekday_picker.dart
  widgets/calendar/   the time-axis diary — metrics, layout, painter,
                      day and week timelines
```

## Commands

Backend:
```bash
python manage.py migrate && python manage.py seed_breeds
python manage.py test api        # 437 tests
python manage.py runserver 0.0.0.0:8000
python manage.py accounts        # who can sign in — usernames live only in the DB
python manage.py reset_link jess # a way back in when the superuser is locked out
```

Mobile:
```bash
cd mobile && flutter pub get
flutter analyze && flutter test  # 232 tests
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
`Client.leaflet_received`, `Client.particular_about_standard` and `Client.notes` are Jess's
private working notes. `particular_about_standard` is her request and belongs here rather than
on the dog — it is a fact about the *owner*, it applies to every dog they bring, and it is
plainly not something to show them written down about themselves.

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

Approving a client's reschedule request follows the same rule: the move is applied and the
warnings come back with it, so a clash is something Jess is *told about* and can slide in the
day view, never something that refuses her.

## Who is due, and asking about a booking

Two things that both come down to the same gap — nothing in this system tells anybody anything.
There is no push, no SMS, and email is on the dummy backend, so `PendingView` polling is the
only signal there has ever been.

**`GET /api/dogs/due/`** (`dogs_due()` in `scheduling.py`) is `suggested_next_groom` across the
whole book. That endpoint could only answer for a dog Jess had already thought to check, which
means a client who quietly stops coming is never noticed — and rebooking a lapsed client is the
cheapest work there is.

**A dog already in the diary is left off the list.** That is the property that makes it a call
list rather than a report, and it is worth defending: put the booked ones back in and the
handful worth ringing are buried. `include_booked=1` exists for the rare whole-book question.
A **cancelled** booking does not count as being in the diary — that is the exact moment a dog
most needs to be back on the list, and there is a test for it.

Never-groomed dogs are included and **marked**, with `due_date` and `days_overdue` both null.
Their due date is genuinely unknown rather than far away, and coercing that to `0` would file
them under "due today", which is a claim nobody made. Same rule as everywhere else here. They
sort last, because "40 days overdue" is a firmer statement than "never been in".

Jess found a dog on this list the evening of the day she groomed it — *"shes ad hock and was
in today, don't know what I've done wrong"* — and she hadn't. Three separate things put it
there, and all three are now closed:

- **"In the diary" starts at midnight this morning, not at this second.** It was
  `start_at >= now`, so a booking dropped out of the reckoning the moment it began. A groom is
  not marked completed until it's written up, which may be days later, and in between the dog
  looked like one nobody had booked.
- **A visit written up marks its booking done.** `GroomSession.link_to_appointment()` — see
  the visit-record section below. Until that existed, `dogs_due` counted *completed*
  appointments and nothing in the app ever completed one.
- **`Dog.is_ad_hoc` takes a dog off the list altogether.** The sum is "last groom + interval",
  and every dog has an interval whether or not one was ever agreed, so a dog that comes when
  the owner rings is permanently about to be late. It does **not** change
  `effective_schedule_weeks`: `suggested_next_groom` still answers for that dog when asked
  directly, which is a fair question about any dog. What changes is that nothing volunteers
  it. `include_ad_hoc=1` for the whole-book question, same as `include_booked`.

**The dog profile answers "next booking" from the diary, not from the sum.** That row used to
be labelled "Next due" and showed `suggested_next_groom` — last groom plus the interval. Jess
asked for it to read **Next booking**, so it now reads the diary and says what is actually in
it, including **"Nothing booked"**, which is the prompt to ring the owner. Calling arithmetic a
booking is how somebody stops chasing a dog that has nothing in the diary at all. The sum keeps
its own row underneath, labelled **Due**, carrying the server's `basis` wording ("8 weeks after
12 Jun 2026") so the figure is never a mystery.

Two things it has to get right, both the same shape as `dogs_due`: the window starts at
**midnight this morning**, not at this second, because a groom is not written up until it is
written up; and a **cancelled** booking is not a booking, because that is the moment a dog most
needs booking again. A failed fetch renders as nothing at all rather than "Nothing booked" —
that is the one wrong answer on this row, because it is the one Jess would act on by booking
the dog in twice.

**`Dog.is_daycare` and `Dog.daycare_days`** are Jess's *"can there be a daycare dog tickbox and
be able to put what days they're in?"*. Weekday numbers in a `JSONField`, **0 = Monday**,
matching `WEEKDAY_CHOICES` and Python's `date.weekday()` — Dart's `DateTime.weekday` is 1-based,
so never pass one straight through. `validate_weekdays` is the only thing between that column
and a string, a `7`, or a `True` that would quietly mean Tuesday; `Dog.save()` sorts. The flag
and the days are separate fields on purpose — a dog can be signed up before the days are
settled, and a tickbox that unticks itself when you clear the days is a tickbox that argues.
**Neither is staff-only**: it is the arrangement the owner made and already knows about, the
same call as `default_services`.

**`AppointmentChangeRequest`** is a client asking to cancel or move. Before it, a client who
could not make it had *no in-app path at all* — ring the salon, or don't turn up. A no-show
costs Jess the slot; a cancellation she hears about is a slot she can refill.

It is a request, not a write, and the same shape as `ClientChangeRequest` and
`ClientClaimRequest` for the same reason: everything a client sends in is reviewed. Bookings
stay read-only to them — `AppointmentViewSet` still refuses their PATCH and DELETE, and this
does not go round it.

- `approve` takes an optional `start_at`, so Jess can move it to a time other than the one
  asked for. That is the common case, not the exception: the client picks something that
  clashes and she puts them in the next real gap. Mirrors claim approval taking a `client_id`.
- `apply()` **carries the duration over rather than recomputing it.** The length was resolved
  from the booking's services when it was made, and re-running `resolve_slot` would silently
  re-price a slot Jess may have adjusted by hand.
- The app says "request sent", never "cancelled" or "moved". Nothing has changed until she
  approves it, and saying otherwise is how somebody doesn't turn up to a groom that is still on.

**`DogChangeRequest`** is the same review shape for the dog record — Jess's *"Can the owner
have an option to 'suggest changes / update details' about the dog?"*. One deliberate
difference from `ClientChangeRequest`: **`message` is free text and approval applies
nothing**. There is no safe whitelist of dog fields to `setattr` — breed drives pricing and
the preferences carry Jess's own wording — so approving records "dealt with" and she makes
the edit herself; the queue row opens the dog so the suggestion and the form sit side by
side. Ownership of `dog` is checked in the viewset with the same single 403 as
`AppointmentChangeRequest`, so the endpoint cannot probe which dog ids exist. It counts into
`PendingView` and has its own tab on Waiting for you. The client's button is on the dog
profile, in the spot the staff book-bar occupies.

**A client asking for an out-of-hours slot is told so before they send** — Jess: *"if it's
'out of hours' can it come up with a message letting them know"*. The request sheet and the
reschedule flow read `/opening-hours/` and `/closures/` (both already client-readable) and
show her message — likely to be moved or turned down — inline. It warns and never blocks,
same as every rule in `scheduling.py`; a fetch failure or **no hours configured at all**
warns about nothing, because a salon with no hours set must not tell every client they are
out of hours.

## The breed record is a reference sheet that also prices

`Breed` began as three numbers and is now Jess's breed standards record — *"a little snippet of
the whole dog"*: KC group, life span, activity, size, height, weight, what it was bred for,
chest/head/ear/tail shape, colours, typical temperament, technique, and five groom styles.

**`tail_shape` was `head_shape`** until Jess asked for the swap — `head_type` was already
covering the head and the tail had nowhere to go.

`0017` does it in two steps because both one-step versions are wrong. Drop-and-add throws away
what she has typed. A bare rename keeps it and files it under the wrong heading, and a breed
sheet reading *"Tail shape: broad, blocky skull"* is worse than an empty one — the empty one is
honest, and that one is a confident answer to a question nobody asked. Same rule as
`nail_visit_price`. So the `RenameField` carries the column across and `rehome_head_shape` then
moves each value to the field that does mean the head — `head_type` where it is free, `notes`
under its own heading where it is not — leaving `tail_shape` **blank** for her to fill in. That
half does not reverse, and says so.

**`typical_temperament` is free text and nothing seeds it.** Her words off the UK Kennel
Club's pages, and the same rule as `MedicalNote`: this is somebody else's description of a
breed, and text that merely reads plausibly is worse than the blank, because the blank is
honest. There is a test asserting `seed_breeds` writes none. It is about the *breed* — never
read it as a stand-in for `Dog.temperament`, which is the dog in front of you and drives the
booking limits.

**Two of those fields are not decoration.** `size_band` and `coat_type` are the two axes of
`PRICING` in `seed_breeds`. The band was in `BREEDS` all along and was never stored, so the
grid knew it and the model did not; `0016` backfills it for the 224 seeded rows. That is a
one-off in the shape of `0006` and for the same reason — `seed_breeds --overwrite` would fill
it in too, but it also resets price, time and interval, discarding every figure Jess has
edited. Never reach for `--overwrite` to add a column.

**Three of the eight coats are not on the grid.** Hairless, corded and silky/drop are Jess's
additions; her price list covers the other five. They price at whatever she sets and nothing is
guessed — `is_priced_by_the_grid` is false for them and the app says so on the record rather
than showing a figure nobody worked out. Same rule as `nail_visit_price`: an invented price is
indistinguishable from a real one once it is in the table.

Everything descriptive is **free text on purpose**. She is still working out what belongs on
this record, and a fixed option list would be something to work around. The four she did
enumerate — group, activity, size, coat — are choices.

`groom_style_*` pre-fills a new dog's `pref_*` in the dog form via `preference_defaults()`.
**Head maps to face** — the breed record says head, a dog's preferences say face, and a groomer
means the same area; `pref_skirt` has no breed counterpart. It only ever fills *blanks*: picking
a breed must not wipe what a client actually asked for, and a mis-tap on the picker must not
rewrite it. The form says what it filled in, so the words are never mysterious.

## Medical notes are Jess's, not ours

`MedicalNote` is the reference she looks a condition up in — what it means, what to watch for
when grooming, what to do if it happens in the salon. Her idea: *"if medical issue with the dog
you can look up what it means or if you need to take care when grooming"*.

**Nothing is seeded and nothing is written by this codebase, deliberately.** This is veterinary
information, and text that merely sounds right is worse than an empty table because somebody
would act on it. There is a test asserting the table is empty after `seed_breeds`. Every entry
carries a `source`, and one without a source is shown as unattributed rather than as fact —
`isAttributed` in `models.dart`, flagged in amber on the screen and in the admin's list display.

Not on `Dog`: a particular dog's conditions are `Dog.medical_issues` and `Dog.medical_notes`,
staff-gated with the rest of that profile. This is the dictionary, not the record.
`IsStaffOrReadOnly`, because a client reading a general reference harms nothing.

In the app it lives under **More → Medical and Breed Standards**
(`medical_and_breeds_screen.dart`), beside the breed list — both used to close out Settings,
and Jess asked for the move: neither is a setting, they are what she looks things up in
mid-groom.

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

**A selected chip must state its own colours.** `ChipThemeData` set a label colour and no
`selectedColor`, so Material fell back to `colorScheme.secondaryContainer` — a role this scheme
never sets, whose getter then returns `secondary`, i.e. `primaryBright`. In dark mode `onTint`
*is* `primaryBright`, so the label was drawn in exactly the colour of the background behind it:
a contrast ratio of **1.0**, and Jess's *"you can't see the text because the background changes
to the same colour as the text"*. Light mode was 2.5:1, no better. Both states are now stated
outright — unselected is an outline, selected is a filled `tint` block, one label colour reads
on both — and the checkmark stays on, because colour alone should not be what tells you a chip
is selected. The lesson generalises: an unset M3 colour role does not fall back to nothing, it
falls back to *another role*, and that is how two perfectly good palette values end up on top
of each other.

### Big screens are real screens

The iOS build targets iPad (`TARGETED_DEVICE_FAMILY = "1,2"`, all orientations), so every
screen has to survive 1,300 logical pixels, not just a phone. Two rules carry it:

- **`PageBody` in `widgets/common.dart` caps page content at a readable width** (720dp;
  the silhouette editor uses 640 so grid cells stay finger-sized). Every list and form
  screen's `body:` is wrapped in it — and both dog-profile bottom bars, so their buttons
  sit under the content column. It is a **no-op below the cap**: phones and goldens are
  byte-identical. Internally it is `Padding`, deliberately not `Align` + `ConstrainedBox`
  — `Align` without a heightFactor expands to its incoming constraints, and Scaffold
  measures `bottomNavigationBar` against the whole screen height, so the Align version
  grew the book bar to 3,000pt and squeezed the profile body to zero. That is the same
  trap `_bookBar`'s own comment documents; this widget wraps bars as well as bodies, so
  it must add width margins and change nothing else.
- **At `kRailBreakpoint` (840dp, in `staff_shell.dart`) both shells swap the bottom tabs
  for a `NavigationRail`** — in tablet landscape a bottom bar spends the scarcest
  dimension on navigation. The staff timer strips move to the foot of the content area:
  the rail replaces the tabs, not the "a running clock is always visible" rule.

Deliberately **not** capped: the diary (a time axis is the one screen that gets better
with width — week view exists for exactly that), the document viewer, and the fullscreen
photo. The photo grid uses `SliverGridDelegateWithMaxCrossAxisExtent` (140dp) rather than
a fixed 3 columns, so an iPad gets more thumbnails instead of enormous ones. The
server-rendered pages were always fine — `base.html` caps `.wrap` at 680px.
`test/large_screen_test.dart` holds all of this.

`test/theme_test.dart` holds the line: display text must resolve to the theme's colour, and
every role must clear WCAG AA against the surface it is used on. The chip checks resolve
Material's fallbacks rather than asserting the fields are non-null — the bug was a green chip,
not a missing config value, and a null check would have failed with "null" instead of the
ratio that explains it.

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

**A walk-in can have consent recorded too.** For a long time `Consent` rows had exactly one
creation path — intake approval — so a client Jess set up across the counter had no consent
record and no way to get one. `ConsentViewSet` (`/api/consents/`) is that route: staff only,
create-and-read only, `POST`/`GET` and nothing else, so the append-only rule is the HTTP method
list rather than a convention. `signed_at` may be backdated to the date on the paper card but
never forward-dated. **`wording` is stamped server-side from the enum** and ignored on input —
the point of storing it is that a later rewording cannot rewrite what somebody agreed to, and a
caller-supplied string could say anything.

`GET /api/consents/kinds/` serves the six and which are required, rather than the app carrying
its own copy. Same reasoning as the temperament labels: two copies of a string drift, and here
the copy that matters is the one stored against a signature. The app also needs the list
*before* any consent exists — precisely the walk-in case — so it cannot read them off rows.

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

On the client profile the **Agreed terms** block sits last, at Jess's request. It is a signed
record rather than something she works from, and in the middle of the page it was pushing the
dogs — the reason she opens a client at all — below the fold.

## One visit record, one card

Jess keeps two paper record cards — "Ongoing Record for Dogs" and "Ongoing Record for Nails /
Flee / Ticks" (`docs/paper-cards.md`). Both land on **`GroomSession`**, told apart by
`visit_type`. One model rather than two because the cards are the same shape and hers are filed
per dog: splitting them would split a dog's history in half. The screen is
`visit_record_screen.dart` — and since her *"I don't think it needs to be a separate thing for
nails/fleas/ticks really"*, it is **one card for every visit**: the type no longer changes what
the screen shows, fleas and ticks are two plain checkboxes on it, and the profile's two add
buttons became one.

**`visit_type` outlives the unified card, on purpose.** It is not presentation: it is what
keeps a twenty-minute nail trim out of `recalculate_average_groom_minutes()` and out of
`apply_to_dog()`. So the card still has to know, and the way it knows matters — a visit
arriving from the timer is a groom by construction and is never asked; editing keeps the
record's own answer; the profile's ADD VISIT passes **null**, which makes the card ask "What
kind of visit" with nothing pre-picked and refuse to save unanswered. Same rule as the intake
form's radios: a pre-picked answer is an answer nobody gave, and here the wrong guess would
quietly shrink the dog's booking length.

The card is not client-facing — `GroomSessionViewSet` is `IsAdminUser` for the whole endpoint,
that is the gate, not field-level masking — **with one deliberate exception**: the groom
report, below.

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
- **`high_velocity_dryer` is nullable too**, at Jess's request — *"can we change to well
  behaved like the bathed"*. It was a switch defaulting to off, so a groom nobody wrote it down
  for was stored identically to one where the dryer was deliberately kept away from the dog,
  and on a dog that will not tolerate one that is the fact worth having. `0017` clears the
  existing `False` values to null, exactly as `0007` did for `is_neutered` and for the same
  reason: not one of them can be told apart from a switch nobody touched.
- **`bathing_notes` and `drying_notes` superseded the yes/no pair on the card** — her next
  message once she had used it: *"Can the bathing and high velocity dryer be option to type as
  not quite as simple as yes or no well behaved"*. Free text (`0021`), blank meaning "not
  recorded". The booleans **stay**: every old card stores its answer there, the app renders an
  old boolean as words ("Well behaved") rather than losing it, and older builds still write
  them. A bathing note entails `bathed` exactly as the boolean did; a drying note deliberately
  entails nothing — "dried off in the crate" is drying without a blow dry. Neither note is on
  the groom report. `shampoo_used` was retired from the card at the same time (*"the shampoo
  used is a bit irrelevant so just get rid of it"*) — the column stays so nothing typed is
  lost, the app no longer shows or sends it.
- **A saved visit finds its booking and marks it done** — `link_to_appointment()`. Jess: *"did
  a 'groom for teddy', set an appointment and then did the timer and managed to add the session
  but wasn't automatically assigned to the appointment?"* It wasn't: `GroomTimerScreen` took an
  `appointmentId` and the only place that opened it never passed one. The match is deliberately
  narrow — it fills a **blank** appointment only (an id she sent is an answer, this is a
  guess), same **local day** only (a groom written up Thursday must not close Tuesday's slot),
  a booking with **no session on it already** (so a nails visit and a groom on the same day
  don't both claim it), an **active** one only, and it marks it completed only once it has
  actually **started**. The app says which booking it landed on rather than leaving her to
  open the diary and check.
- **Closing a booking is offered back.** Marking one off the back of a *different* action is a
  fair inference and a poor thing to do silently, so `link_to_appointment()` leaves the status
  it replaced on `appointment_status_before` — not a column, true of one save — and the app's
  snack carries an UNDO that puts exactly that back. Not a sensible-looking guess: undoing a
  `CONFIRMED` booking as `BOOKED` would quietly lose the confirmation. It is null unless *this*
  save changed something, so a booking that was already done offers no undo for a status
  nobody set. One tap from reversible is what makes it reasonable to do unasked.
- **`final_body` / `final_feet` / `final_tail` are what was *done*.** The `pref_*` fields on the
  dog are what the owner asked for at intake. Do not conflate them.

### A timed groom is not a bookable slot

Jess: *"the 'groom time' is nowhere near the appointment time (which would be how long to book
them in for)"*. It never could be. The timer counts five phases — prep, wash, dry, clip, strip
— and a booking also has to cover the nails, the ears, the hygiene area, the health check and
handing the dog over at both ends. Writing the stopwatch figure straight to `Dog.groom_minutes`
is what booked a 55-minute slot for a 90-minute job, and the *average* did it again by a second
route.

`AppSettings.groom_time_buffer_minutes` is the distance between the two figures, and
`GroomSession.bookable_minutes` is where it lands. **Describe it as "drop-off, collection and
anything done off the clock", never "nails, ears, the health check"** — the first wording
shipped said that, and Jess corrected it: she does the nails and ears inside the timed
phases, so the timer does see them. What the phases genuinely never cover is the handover at
both ends.

- **Null until Jess sets it, and nothing is guessed.** Same call as `nail_visit_price` and for
  the same reason — a buffer this codebase invented would be indistinguishable from one she
  measured, and every booking in the diary would be the wrong length on the strength of it.
  Until she fills it in, behaviour is **byte-identical to before**, which is the property that
  let this ship without moving a single figure already in her diary.
- **Applied at both places a timed total becomes a booking length**: `apply_to_dog()` and
  `recalculate_average_groom_minutes()`. Buffering one and not the other is the same bug behind
  a different door — the override is what she sets deliberately, the average is what creeps up
  on her.
- **Never applied to `recorded_minutes`.** That is her own figure for how long the whole visit
  took, typed in when the timer was not used, so it already includes everything the buffer
  stands for. Adding to it double-counts. `total_minutes` still reports what was *timed* — the
  record card is a record, not a booking estimate.
- **Changing it re-derives every dog's average**, in `AppSettings.save()`, because the averages
  are stored with the buffer already in them. Doing it at read time instead would put a
  settings lookup inside `effective_groom_minutes`, which renders once per row on `Doguments` —
  the N+1 that `average_groom_minutes` was denormalised to avoid in the first place. The
  recompute only fires when the figure actually moved.
- **One figure for the business, not one per dog.** The overhead it covers is handling, not
  coat, so it barely moves between a toy and a colossal. A dog that genuinely differs gets its
  groom time set by hand, which overrides all of this anyway.
- **The phases are shown back.** Every timed groom stored its phase breakdown and displayed
  none of it — the card kept one total and the timer screen was gone by the time Jess looked.
  Her framing is the right one: *"can the 'appointment time' be the 'how long the groom took'
  but the timer is 'actual grooming time' so I can click on it and see the timer?"*. The record
  card now carries both, the timed one opening into Prep / Wash / Dry / Clip / Strip, and the
  dog's visit list leads with the whole-groom figure and names the timed one beside it when
  they differ. The breakdown is read-only: the phases are a measurement, and the figure she can
  change is the one above, which is the one that does anything.
- **`total_minutes` is neither of the two figures she named** and is not what to render. It is
  `recorded_minutes` or the phase sum, with no buffer. Use `bookable_minutes` for how long the
  groom took and `timedSeconds` (Dart, off the timings) for what the stopwatch measured.
- `formatClock` lives in `models.dart` beside `formatDuration`, not in the timer screen. It
  stopped being only the timer's the moment a saved visit showed the same figures back, and
  importing that screen from the record card would be a cycle.
- The timer screen quotes the **bookable** figure on its save button and spells out the sum
  underneath, and the snack afterwards reads `session.bookable_minutes` rather than the
  stopwatch. Saying the wrong one is how the number on the dog becomes a surprise. With no
  buffer set it says so, and names the parts the timer does not count.

### The finishing checklist

Jess: *"can we add a little 'check list' “Nails Clipped, Hygiene Area, Health Check, Ears
Cleaned” with a little box under to fill in why something not done"* — and then, once she had
used it: *"Can it just have tick boxes. 'Health Checked, Nails Clipped, Ears Cleaned, Hygiene
Area, Feet Clipped Out, Bathed, Blow Dried, Usual Groom Carried Out'"*. **Eight flags** (the
second four in `0020`) and `checklist_notes`, in her second message's order — which is also why
the tiles lead with the health check, not the nails. It goes **beyond the paper card**, like
`final_face` before it — the card is the spec for everything else, so the difference is
deliberate.

- **All eight are nullable, and null means the list was never worked down.** Same rule as
  `bathed_well_behaved` and `high_velocity_dryer`, arrived at the same way: a box that starts
  unticked cannot tell "I left the hygiene area" from "I have not been down this list yet", and
  here the first one is the fact worth having — it is exactly what the reason box explains.
- **`nails_done` is one column across both paper cards.** It already existed on the
  nails/fleas/ticks card, and whether this dog's nails were clipped at this visit is one fact.
  Two columns would disagree the first time Jess clipped nails during a groom, and "when were
  Bunny's nails last done" would miss every groom-card answer. `0018` widens it to nullable and
  clears the unasked `False`s on GROOM rows only — on a nails visit a `False` was a real
  answer, so that half does not reverse, and says so.
- **`bathed` and `blow_dried` are filled in by entailment, never guessed.** They sit beside
  `bathed_well_behaved` and `high_velocity_dryer` without repeating them — those record how the
  dog *took* it, these whether it *happened* — and an answer about how the bath went means a
  bath went. `GroomSession.save()` fills a null `bathed` from a non-null behaviour answer and a
  null `blow_dried` from a dryer recorded as *used* (only those directions hold; "dryer not
  used" says nothing about drying), `0020` backfills the same way, the serializer refuses the
  outright contradictions, and the card ticks the pair together in the UI so Jess sees the
  entailment before the server applies it. An explicit answer of hers is never overwritten.
- **The list is uniform tristate on the one card.** The old nails card coerced `nails_done` to
  two-state; the unified card sends the third state for every visit, and the serializer still
  refuses a NAILS visit that names none of nails, fleas or ticks. `fleas_treated` and
  `ticks_removed` stay two-state like the matting flags — the card asks whether it happened, so
  an unticked box is an answer.
- The tile ignores the value Flutter's tristate `Checkbox` hands back and sets its own order:
  not recorded → **done** → not done → not recorded. Flutter's own cycle puts "not done" under
  the first tap, and the common case is the opposite. The subtitle names the state in words,
  because a dash is only obvious once somebody has told you what it means.
- The visit list on a dog's profile summarises **only what was marked not done**. A checklist
  worked straight down says nothing worth a line; the one job she had to leave does.

### The groom report is the owner's window, and a whitelist

Jess: *"The owner should be able to see this"* — the checklist, *"notes from any of the above,
why it was not carried out"*, *"then the temperament of the dog and an anything to note text
box"*. That is `GET /api/groom-reports/`: a **second route over `GroomSession`**, read-only
(`ReadOnlyModelViewSet`, so the write surface is the HTTP method list, same shape as
`ConsentViewSet`), scoped `ClientScopedMixin(client_lookup='dog__client')`, serving the
whitelist in `GroomReportSerializer` — the eight ticks, `checklist_notes`, `fleas_treated` /
`ticks_removed`, the temperament **label** (through `temperament_label()`, never the frozen
enum — the person it describes is reading it), and `notes`. Everything else on the card —
health check findings, matting, sensitive notes, timings, shampoo, equipment — stays behind
the staff-only endpoint, and `test_the_report_is_a_whitelist` pins the exact key set so a new
model field has to be admitted deliberately.

Four things worth keeping true:

- **The staff card marks what the owner can read.** The checklist header, the visit note and
  the temperament caption each say so, and `sensitive_notes` — sitting between two shared
  fields — says "Staff only" outright. Jess writes with a reader now; the boundary belongs on
  the card, not in her memory.
- **The owner's report renders answered items only.** On the staff card a null row is Jess's
  own to-do list and stays visible; on the report, "Not recorded" eight times over reads as
  eight worries, and every visit written up before the checklist existed would be all of them.
  What was done, and what was deliberately left with the reason, is the report.
- **`notes` ("Anything to note") became owner-visible retroactively.** It had always been on
  the card; anything typed in it before the report existed is now readable by that dog's
  owner. `sensitive_notes` is the box that was always meant for what the owner must not see,
  and it stays staff-only.
- The client sees reports on the dog profile (`_reportsSection`, the client-side counterpart
  of the staff `_visitsSection`), opening into `screens/client/groom_report_screen.dart`.

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

## The groom timer outlives its screen

Jess: *"is it not possible to have the timer running in the background, mostly whilst prep,
clipping or stripping just need to be able to check notes as I figured out today whilst doing
bunny"*. It could not. Every count lived in `_GroomTimerScreenState`, so backing out to read
the dog's handling notes threw the whole groom away without a word — and the notes are on the
screen directly underneath.

`GroomTimerService` (`services/groom_timer_service.dart`) holds it instead, registered as a
singleton in `service_locator`. `GroomTimerScreen` is a view over it, and closing that screen
pauses nothing.

**It holds one session per dog now, and two can run at once.** Jess: *"can it be 'paused' so
once all the 'prep' done on one, the 'prep' for the other can be added? Like I will bath one
and they can 'dry' in the crate for a bit and I will get on with 'bathing' the other dog?"*.
Dogs from one household are groomed interleaved, so `openFor` a second dog **adds** a session
rather than asking what to do with the first — the old held-dog dialog is gone, and with it
the trap where the only button that moved things on threw an hour of timing away. One phase
runs at a time *per dog*; another dog's phase keeps counting. The shell bar shows a strip per
live session and the timer screen offers the other dogs as one-tap switches. Saving or
discarding clears **only that dog's** session (`clearSession`). The persisted blob is now
`{sessions: [...]}` but `restore()` still reads the old single-session shape — the format
changed under phones that may have a groom on the clock, and there is a test for it. The
"disk loses to memory" rule is unchanged and now guards the whole list.

- **Elapsed time is always a wall-clock difference, never a tick count.** A backgrounded app
  stops getting `Timer.periodic` callbacks; `DateTime.now().difference(since)` does not care.
  The ticker exists only to repaint.
- **It persists on every change**, to `FlutterSecureStorage` — already a dependency, and not
  because a running timer is a secret. iOS will kill the app mid-groom while the camera is
  open, and two hours of timing is not something to lose to that. A write that fails is
  swallowed: the in-memory half is what she actually asked for.
- **A phase restored without its start stamp is dropped, not restarted.** Counting it from now
  would read as a phase that had only just begun.
- **A phase running longer than `implausibleRun` (4h) is flagged and never adjusted.** The
  screen says which one and Jess types the real figure in. A number this code invented would
  be indistinguishable from one she measured — the same rule as `nail_visit_price`.
- **Another dog's session is never merged in.** `holdsAnotherDog()`, and the screen asks
  before discarding.
- **A restore landing late must not overwrite a session already opened.** Jess: the timer was
  *"stuck on teddy instead of the actual dog it's meant for"*. Reading the session back off the
  keystore is a round trip the constructor deliberately does not block on, so a screen could
  open the timer for the dog in front of her and have the restore land a moment later and put
  the previous dog back — name, clock and all. Memory is the live session and disk is a
  snapshot of an older one, so **disk loses**, and `GroomTimerService.ready` lets anything that
  decides *which dog* wait for the read first. There is a test that fails without the guard.
- **Switching dogs must not cost a groom.** The way out of "Teddy is still being timed" used to
  be discard or nothing, which is the other half of the same complaint: the only button that
  moved things on threw an hour of timing away, so the honest answer was to back out — and then
  the timer said Teddy for good. The dialog now offers **WRITE UP TEDDY**, which hands that
  session to its own record card, and only clears the timer if the card was actually saved.
- Two places show a running timer, because a timer you can walk away from is one that gets
  left on: a bar above the tabs in `StaffShell`, and the dog profile's FAB, which reads
  `TIMING · 12:34`. The profile matters most — it is the screen she leaves the timer *for*,
  and a pushed route sits over the shell.

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
- **Every child of the day's `Stack` must be `Positioned`.** A `Stack` sizes itself to its
  non-positioned children and only falls back to `constraints.biggest` when it has none — and
  the width arrives *loose*, because a `Column` gives its children loose cross-axis constraints
  unless told to stretch. `_nowLine` used to return a `SizedBox.shrink()` when the time fell
  outside the drawn window; that one 0x0 child took the Stack to **zero width**, so the grid,
  the shading and every hour line painted into nothing. The window ends at 19:00, so this was
  the whole day view going blank on **today only, every evening** — every other date rendered,
  which is exactly what made it read as bad data rather than layout. `week_timeline.dart` had
  already worked this out and says so in its own `_nowLine`; the day view now returns a list
  the same way, and `SizedBox(width: double.infinity)` makes the Stack's width tight so no
  future stray child can do it again.
- **`DayTimeline` takes an injectable `now`, for tests only.** The failing case only existed
  after closing time, and a test that can only fail in the evening passes all morning while the
  bug is still there. `timeline_layout.dart` stays clock-free — the widget is where the clock
  gets in, so that is where the seam is.
- **Today is marked on the date strip with a red border**, Jess's request. A border and not a
  fill, because the fill already means "the day you are looking at" and those are two different
  questions; red because that is what the now-line uses and nothing else on the screen does.
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

**A REQUESTED block in the day view opens a decision sheet, not the edit form** — book it in
(with the same advisory check the queue runs), turn it down, open the booking, or ring. Jess:
*"view the item in the diary, then have the ability to approve/deny it from there?"* — the
diary is where the clash is visible, so the answer is one tap away there. Waiting for you
gained "See it in the diary" buttons that push `CalendarScreen(initialDate:)`, which is why
that screen takes an optional date at all: pushed it shows a back button and lands on the day
in question; as a shell tab nothing passes one.

**Booking a household together** — *"usually people book all their dogs together for a
groom"*. The booking form offers the owner's other dogs as chips once a dog is picked; each
ticked dog gets **its own appointment at the same start time**, sized to its own groom time
with no services named, so the server resolves each dog's price exactly as a booking made
alone. The deliberate overlap is the point (one bathing while the other crate-dries) and no
check can see it anyway — none of the bookings exist when the checks run — but each extra
dog's *other* warnings (temperament caps, hours) are merged into the one confirm dialog,
prefixed with the dog's name. Book-together and the repeat switch exclude each other: a
series materialises one dog.

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

## Invoice numbers are the server's, and the app has a timeout

**`Invoice.number` blank means "allocate the next one"** — `Invoice.next_number()`, MAX+1 over
`INV-####`. The app used to send `INV-${millisecondsSinceEpoch % 100000}`: sequential-*looking*
and nothing more. It did not sort, could not be read down a phone, told a client nothing, and
modulo a timestamp it could collide with an existing number and fail the unique constraint in
front of Jess. A number she types herself is still honoured, and only `INV-`-shaped ones count
towards the sequence, so a one-off written on a paper receipt ("2026-04-CASH") sits alongside
without shifting the counter.

Deleting a *draft* frees its number again, and that is correct rather than a gap: only a draft
can be deleted at all (`perform_destroy`), and a draft has never been sent, so nobody has been
quoted it. Anything sent or paid must be voided instead, precisely so its number stays used up.
`save()` retries on `IntegrityError` because read-then-write races, and the unique index is the
real guarantee.

**`ApiClient` now has a timeout** (20s, 90s for uploads and downloads). There was none, and the
failure it left open is the likeliest one here: a phone that has drifted out of range of the
salon wifi holds the socket open rather than refusing, so the future never completed — and every
screen is `_loading = true` until its fetch returns. A spinner that never resolves, with no way
out but force-quitting. A timeout surfaces as `NoConnectionException`, the same as an outright
refusal, because from the user's side they are the same thing.

`MojoNetworkImage` in `widgets/common.dart` wraps `cached_network_image`, which had been in
`pubspec.yaml` the whole time and was imported by nothing. **Only for `MEDIA_URL` images** —
dog photos, served by Caddy directly. Scanned paperwork goes through the gated download view and
`ApiClient.getBytes`, and must never be pointed at it.

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
