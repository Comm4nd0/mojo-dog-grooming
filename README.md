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

## Accounts

Usernames live in the database, not in this repository — they come from `createsuperuser` or
from `DJANGO_SUPERUSER_USERNAME` on first boot. To see what exists, and to get someone back in
when they are locked out:

```bash
python manage.py accounts            # list logins: username, email, role, last sign-in
python manage.py reset_link jess     # single-use link to set a new password
```

In production, run these inside the container:

```bash
docker compose -f docker-compose.prod.yml exec web python manage.py accounts
```

Day to day a superuser does the same thing from the app — **More → Logins** — which also shows
anyone who has asked for help getting back in. `reset_link` is the way in when the superuser is
the one locked out, since the in-app version needs them signed in already.

**Mobile**

```bash
cd mobile
flutter pub get
flutter run --dart-define=MOJO_API_BASE=http://<your-lan-ip>:8000/api
```

Without `--dart-define` the app points at `https://app.mojoandco.uk/api`.

## Tests

```bash
python manage.py test api     # 283 backend tests
cd mobile && flutter test     # 135 widget, model and golden tests
```

The backend suite covers the access-control rules the design rests on: a client can only reach
their own records, and staff-only fields (temperament, whether an owner is chatty, private
notes) never appear in a client-facing payload.

## Deploying

**Backend** — the Hetzner host, port 8010, behind Caddy. **A push to `main` deploys it**, once
the tests pass: `.github/workflows/deploy.yml` dumps the database, pulls, rebuilds and rolls
back if the health check or smoke test fails. Nothing to run by hand.

Turning it on takes one secret. Generate a key, put the public half on the host, and paste the
private half into `DEPLOY_SSH_KEY` under Settings → Secrets and variables → Actions:

```bash
ssh-keygen -t ed25519 -N "" -C "mojo-github-actions-deploy" -f ~/.ssh/mojo_deploy
ssh root@178.104.29.66 "cat >> ~/.ssh/authorized_keys" < ~/.ssh/mojo_deploy.pub
cat ~/.ssh/mojo_deploy     # this is the secret
```

The host and user are not secrets — this repo is public and already names the address in
`Caddyfile` — so the workflow defaults them and only the key has to be entered. Run the first
deploy from the Actions tab by hand: `workflow_run` usually doesn't fire for the push that adds
the workflow itself.

The first-time setup, and the way in if CI is not an option:

```bash
cp .env.example .env          # fill in the secrets
./deploy.sh
```

Then add the block from `Caddyfile` to the host's Caddy config. `app.mojoandco.uk` needs a DNS
A record pointing at the host before a certificate can be issued.

**App** — a tag is the release, and the only thing that reaches customers.

```bash
$EDITOR CHANGELOG.md          # what customers read on the App Store
./tools/release.sh 1.0.0
```

Xcode Cloud builds the tag and uploads it; `.github/workflows/release.yml` then writes the
release notes, attaches the build and submits for review, and it goes live on approval.
Pushes to `main` go to TestFlight only. See [RELEASING.md](RELEASING.md) — including the
one-time Xcode Cloud and App Store Connect API key setup, which has to be done before any of
this runs.

## Notes for whoever picks this up

See [CLAUDE.md](CLAUDE.md) — particularly the two access-control rules and the reason
staff-only field gating happens in `get_fields()` rather than `__init__`.

The seeded breed times and prices are general estimates, not Mojo and Co's own figures. They
are editable in the app under Settings → Breeds.
