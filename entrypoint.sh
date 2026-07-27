#!/bin/sh
# Runs migrations and seeds reference data before handing over to gunicorn.
set -e

echo ">>> Applying migrations..."
python manage.py migrate --noinput

# Idempotent: existing breeds, limits and hours are left alone.
echo ">>> Seeding reference data..."
python manage.py seed_breeds

if [ -n "$DJANGO_SUPERUSER_USERNAME" ] && [ -n "$DJANGO_SUPERUSER_PASSWORD" ]; then
    echo ">>> Ensuring the admin account exists..."
    python manage.py shell -c "
from django.contrib.auth.models import User
import os
username = os.environ['DJANGO_SUPERUSER_USERNAME']
if not User.objects.filter(username=username).exists():
    User.objects.create_superuser(
        username,
        os.environ.get('DJANGO_SUPERUSER_EMAIL', 'admin@mojoandco.uk'),
        os.environ['DJANGO_SUPERUSER_PASSWORD'],
    )
    print(f'Created superuser {username}')
else:
    print(f'Superuser {username} already exists')
"
fi

exec "$@"
