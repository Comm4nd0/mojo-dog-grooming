# Mojo and Co

Dog grooming management for [Mojo and Co](https://mojoandco.uk) — a Django REST backend and a
Flutter app for iOS and Android.

Staff get the whole business: client and dog records, a searchable dog list, the diary, groom
phase timers, photos, invoicing and an equipment register. Clients get their own details, their
own bookings, and can request an appointment or fill in an intake form.

## Getting started

**Backend**

```bash
python -m venv venv
venv/Scripts/activate        # or: source venv/bin/activate
pip install -r requirements.txt
python manage.py migrate
python manage.py seed_breeds
python manage.py createsuperuser
python manage.py runserver 0.0.0.0:8000
```

Runs on SQLite with no services to start. The admin is at `/admin/`.

**Mobile**

```bash
cd mobile
flutter pub get
flutter run --dart-define=MOJO_API_BASE=http://<your-lan-ip>:8000/api
```

Without `--dart-define` the app points at `https://app.mojoandco.uk/api`.

## Tests

```bash
python manage.py test api     # 81 backend tests
cd mobile && flutter test     # 33 widget, model and golden tests
```

The backend suite covers the access-control rules the design rests on: a client can only reach
their own records, and staff-only fields (temperament, whether an owner is chatty, private
notes) never appear in a client-facing payload.

## Deploying

Target is the Hetzner host, port 8010, behind Caddy.

```bash
cp .env.example .env          # fill in the secrets
./deploy.sh
```

Then add the block from `Caddyfile` to the host's Caddy config. `app.mojoandco.uk` needs a DNS
A record pointing at the host before a certificate can be issued.

## Notes for whoever picks this up

See [CLAUDE.md](CLAUDE.md) — particularly the two access-control rules and the reason
staff-only field gating happens in `get_fields()` rather than `__init__`.

The seeded breed times and prices are general estimates, not Mojo and Co's own figures. They
are editable in the app under Settings → Breeds.
