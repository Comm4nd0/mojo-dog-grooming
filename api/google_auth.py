"""Sign in with Google — checking the token the app hands over.

The app gets an ID token from Google on the phone and sends it here. Nothing
about the person is taken from the app itself: the only facts this code acts on
are the ones Google vouches for inside that token, and it asks Google whether
the token is genuine rather than trusting the bytes it was given.

**Why Google's tokeninfo endpoint and not a JWT library.** ``requirements.txt``
is pinned to match p4td on the same host, and adding a package there obliges
the other project too — the same reason ``sentry-sdk`` lives in the prod file.
Verifying the signature locally needs a JWT library and a fetched, cached key
set. Asking Google costs one HTTPS round trip per sign-in, which for one
groomer's client list is nothing, and it is done with the standard library.
The checks that matter are made here either way: Google checks the signature
and expiry, this checks who the token was *issued to* and that the email is
verified.

**What is checked, and why each one is not optional:**

* ``aud`` is one of our own client IDs. Without it, an ID token any other app
  obtained for its own users — a quiz, a game — would sign that person in here.
  This is the check that makes a token *ours*.
* ``iss`` is Google.
* ``email_verified`` is true. Google accounts can carry addresses nobody has
  proved they own, and an unverified address is a claim, not an identity.
* ``exp`` is in the future. Google refuses an expired token already; this is
  the belt to that brace, and it is cheap.
"""

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request

from django.conf import settings

logger = logging.getLogger(__name__)

TOKENINFO_URL = 'https://oauth2.googleapis.com/tokeninfo'
GOOGLE_ISSUERS = {'accounts.google.com', 'https://accounts.google.com'}


class GoogleTokenError(Exception):
    """The token was not one to act on. The message is safe to show."""


class GoogleUnavailable(Exception):
    """Google could not be asked. Not the person's fault, and worth retrying."""


def allowed_client_ids():
    """Every client ID a token may have been issued to.

    The web client ID is the one the Android app asks for (it is the
    ``serverClientId``), and iOS tokens carry the iOS client's own ID, so the
    list is the web ID plus any extras.
    """
    ids = []
    if settings.GOOGLE_OAUTH_WEB_CLIENT_ID:
        ids.append(settings.GOOGLE_OAUTH_WEB_CLIENT_ID)
    ids.extend(settings.GOOGLE_OAUTH_EXTRA_CLIENT_IDS)
    return ids


def is_enabled():
    return bool(settings.GOOGLE_OAUTH_WEB_CLIENT_ID)


def fetch_tokeninfo(id_token):
    """Ask Google what this token says. Split out so tests can stand in for it."""
    url = f'{TOKENINFO_URL}?{urllib.parse.urlencode({"id_token": id_token})}'
    try:
        with urllib.request.urlopen(url, timeout=8) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        # 400 is Google's answer for a token that is invalid or expired.
        if error.code == 400:
            return None
        logger.warning('Google tokeninfo answered %s', error.code)
        raise GoogleUnavailable() from error
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        logger.warning('Google tokeninfo could not be reached: %s', error)
        raise GoogleUnavailable() from error


def verify_id_token(id_token):
    """Return the verified claims, or raise :class:`GoogleTokenError`.

    Only ``sub``, ``email`` and the names are returned — ``sub`` is the one
    that identifies the person for good; an email address can change hands.
    """
    if not isinstance(id_token, str) or not id_token.strip():
        raise GoogleTokenError('Google did not send a sign-in token.')

    claims = fetch_tokeninfo(id_token.strip())
    if not claims:
        raise GoogleTokenError('Google could not confirm that sign-in. Try again.')

    if claims.get('aud') not in allowed_client_ids():
        # Logged, because the likeliest cause is a client ID missing from the
        # server's settings rather than anyone trying anything.
        logger.warning('Google token issued to an unrecognised client: %s', claims.get('aud'))
        raise GoogleTokenError('That Google sign-in was not for Mojo and Co.')
    if claims.get('iss') not in GOOGLE_ISSUERS:
        raise GoogleTokenError('Google could not confirm that sign-in. Try again.')
    try:
        expires = int(claims.get('exp', 0))
    except (TypeError, ValueError):
        expires = 0
    if expires <= time.time():
        raise GoogleTokenError('That Google sign-in has expired. Try again.')
    # tokeninfo reports booleans as strings.
    if str(claims.get('email_verified')).lower() != 'true' or not claims.get('email'):
        raise GoogleTokenError(
            'Google has not verified the email on that account, so it cannot be used to sign in.'
        )
    if not claims.get('sub'):
        raise GoogleTokenError('Google could not confirm that sign-in. Try again.')

    return {
        'sub': str(claims['sub']),
        'email': claims['email'].strip(),
        'first_name': (claims.get('given_name') or '').strip(),
        'last_name': (claims.get('family_name') or '').strip(),
    }
