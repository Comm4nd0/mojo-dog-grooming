"""Django settings for the Mojo & Co grooming backend.

Dev runs on SQLite with DEBUG on; production runs on PostgreSQL behind Caddy.
Everything environment-specific comes from the environment (see .env.example),
so the same image runs in both places.
"""

import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent

load_dotenv(BASE_DIR / '.env')


def env_bool(name, default=False):
    return os.getenv(name, str(default)).strip().lower() in {'1', 'true', 'yes', 'on'}


def env_list(name, default=''):
    return [item.strip() for item in os.getenv(name, default).split(',') if item.strip()]


SECRET_KEY = os.getenv('DJANGO_SECRET_KEY', 'dev-insecure-change-me')
DEBUG = env_bool('DJANGO_DEBUG', True)
ALLOWED_HOSTS = env_list('DJANGO_ALLOWED_HOSTS', '*')

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'rest_framework',
    'rest_framework.authtoken',
    'djoser',
    'corsheaders',
    'api',
]

MIDDLEWARE = [
    'corsheaders.middleware.CorsMiddleware',
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'mojo_backend.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / 'templates'],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'mojo_backend.wsgi.application'

# ── Database ───────────────────────────────────────────────────────────
# DATABASE_URL (postgres://…) in production; SQLite otherwise so a fresh
# checkout runs with no services to start.
DATABASE_URL = os.getenv('DATABASE_URL', '')
if DATABASE_URL:
    from urllib.parse import urlparse

    parsed = urlparse(DATABASE_URL)
    DATABASES = {
        'default': {
            'ENGINE': 'django.db.backends.postgresql',
            'NAME': parsed.path.lstrip('/'),
            'USER': parsed.username or '',
            'PASSWORD': parsed.password or '',
            'HOST': parsed.hostname or '',
            'PORT': str(parsed.port or ''),
            'CONN_MAX_AGE': 60,
        }
    }
else:
    DATABASES = {
        'default': {
            'ENGINE': 'django.db.backends.sqlite3',
            'NAME': BASE_DIR / 'db.sqlite3',
        }
    }

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {
        'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',
        # The app has always told people "at least 8 characters"; Django's
        # default of 8 matches, but pin it so the two can't drift apart.
        'OPTIONS': {'min_length': 8},
    },
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

# Clients type their email as often as their username when signing back in,
# and phone keyboards capitalise. See api/auth_backends.py for why an exact
# username match still wins and why an ambiguous identifier fails closed.
AUTHENTICATION_BACKENDS = [
    'api.auth_backends.UsernameOrEmailBackend',
    'django.contrib.auth.backends.ModelBackend',
]

LANGUAGE_CODE = 'en-gb'
TIME_ZONE = 'Europe/London'
USE_I18N = True
USE_TZ = True

STATIC_URL = 'static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
STORAGES = {
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {
        # Manifest storage requires collectstatic to have run, which is true in
        # the production image but not for a bare `runserver`.
        'BACKEND': (
            'django.contrib.staticfiles.storage.StaticFilesStorage'
            if DEBUG
            else 'whitenoise.storage.CompressedManifestStaticFilesStorage'
        ),
    },
}

MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / 'media'

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# ── DRF ────────────────────────────────────────────────────────────────
REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': (
        'rest_framework.authentication.TokenAuthentication',
        'rest_framework.authentication.SessionAuthentication',
    ),
    'DEFAULT_PERMISSION_CLASSES': (
        'rest_framework.permissions.IsAuthenticated',
    ),
    # Damp brute-force attempts on anonymous endpoints (login, registration,
    # the public intake form). Authenticated app traffic is never anon-throttled.
    'DEFAULT_THROTTLE_CLASSES': (
        'rest_framework.throttling.AnonRateThrottle',
    ),
    'DEFAULT_THROTTLE_RATES': {
        'anon': '60/min',
        # Submitting an intake form is the abuse vector, so it stays tight.
        'intake': '20/hour',
        # Loading the form page is not: a client may reload it, come back to
        # it, or share an IP with the rest of their household. Sharing one
        # bucket with the submission would let ordinary reloading lock someone
        # out of actually sending their details.
        'intake_form': '120/hour',
        # Sign-in. Loose enough that a household on one IP, or Jess flipping
        # between her staff and a test client login, never notices; tight
        # enough that guessing passwords at scale is not worth starting.
        'login': '12/min',
        # Setting a new password from a reset link. The same split as intake,
        # and for the same reason: opening the page must not spend the budget
        # for submitting it.
        'password_reset': '20/hour',
        'password_reset_form': '120/hour',
        # Asking for help getting back in. Deliberately mean — each one puts a
        # row in front of Jess, so this is a nuisance vector as much as a
        # security one.
        'password_reset_request': '5/hour',
    },
    'DEFAULT_PAGINATION_CLASS': 'rest_framework.pagination.PageNumberPagination',
    'PAGE_SIZE': 100,
    # One reverse proxy (Caddy) in front of gunicorn — throttle the real client
    # IP from X-Forwarded-For, not the proxy's.
    'NUM_PROXIES': 1,
}

DJOSER = {
    'USER_ID_FIELD': 'id',
    'LOGIN_FIELD': 'username',
    'SERIALIZERS': {
        'current_user': 'api.serializers.DjoserUserSerializer',
        'user': 'api.serializers.DjoserUserSerializer',
        # Registration is the one place a stranger writes to the User table.
        # The custom serializer requires an email and refuses names or
        # addresses that only differ from an existing account by case.
        'user_create': 'api.serializers.MojoUserCreateSerializer',
    },
}

# ── CORS / CSRF ────────────────────────────────────────────────────────
CORS_ALLOW_ALL_ORIGINS = env_bool('CORS_ALLOW_ALL_ORIGINS', DEBUG)
CORS_ALLOWED_ORIGINS = env_list('CORS_ALLOWED_ORIGINS')
CSRF_TRUSTED_ORIGINS = env_list('CSRF_TRUSTED_ORIGINS')

# ── HTTPS hardening (prod only) ────────────────────────────────────────
if env_bool('DJANGO_SECURE_HTTPS', False):
    SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
    SECURE_SSL_REDIRECT = True
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_HSTS_SECONDS = 31536000
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    SECURE_HSTS_PRELOAD = True

# ── Email ──────────────────────────────────────────────────────────────
# Optional throughout. With no EMAIL_HOST the backend discards mail rather
# than erroring, and every feature that can email something also hands the
# link back so it can be sent by hand — which is how Mojo and Co has always
# delivered intake forms. Set EMAIL_HOST to turn real sending on.
EMAIL_HOST = os.getenv('EMAIL_HOST', '')
EMAIL_PORT = int(os.getenv('EMAIL_PORT', '587'))
EMAIL_HOST_USER = os.getenv('EMAIL_HOST_USER', '')
EMAIL_HOST_PASSWORD = os.getenv('EMAIL_HOST_PASSWORD', '')
EMAIL_USE_TLS = env_bool('EMAIL_USE_TLS', True)
DEFAULT_FROM_EMAIL = os.getenv('DEFAULT_FROM_EMAIL', 'Mojo and Co <info@mojoandco.uk>')

if EMAIL_HOST:
    EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
elif DEBUG:
    EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'
else:
    EMAIL_BACKEND = 'django.core.mail.backends.dummy.EmailBackend'

# Whether anything will actually be delivered. The API reports this so the app
# can say "copy this link and send it yourself" instead of claiming an email
# is on its way that nobody will ever receive.
EMAIL_ENABLED = bool(EMAIL_HOST)

# ── Business defaults ──────────────────────────────────────────────────
# How many appointments a BookingSeries materialises ahead of today.
BOOKING_SERIES_HORIZON_WEEKS = int(os.getenv('BOOKING_SERIES_HORIZON_WEEKS', '26'))
# How long an emailed intake form link stays valid.
INTAKE_INVITE_TTL_DAYS = int(os.getenv('INTAKE_INVITE_TTL_DAYS', '30'))
# How long a password reset link stays valid. Short by design — it is handed
# over WhatsApp or read down the phone as often as it is emailed.
PASSWORD_RESET_TTL_HOURS = int(os.getenv('PASSWORD_RESET_TTL_HOURS', '24'))
# Where links point when nothing built them from a live request — the
# management commands, and any email sent from a shell.
PUBLIC_BASE_URL = os.getenv('PUBLIC_BASE_URL', 'https://app.mojoandco.uk').rstrip('/')
