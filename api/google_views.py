"""Sign in with Google: the endpoints.

Three routes, all under ``/api/auth/google/``:

* ``GET`` — whether Google sign-in is switched on, and the client ID the app
  should ask Google for. Public, because the login screen needs it before
  anybody is signed in, and a client ID is not a secret.
* ``POST`` — sign in with a Google ID token, making a client login if this
  Google account has never been seen. Hands back the same ``auth_token`` as
  the password login, so the app treats the two identically from there on.
* ``POST connect/`` and ``DELETE connect/`` — link or unlink Google on the
  account already signed in.

The rules that make it safe are on :class:`~api.models.GoogleIdentity`: never
link on an email match, and never a staff login. Both are enforced here.
"""

import re

from django.conf import settings
from django.contrib.auth.models import User
from django.db import IntegrityError, transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle, UserRateThrottle
from rest_framework.views import APIView

from . import google_auth
from .models import GoogleIdentity


class GoogleLoginThrottle(AnonRateThrottle):
    """The sign-in budget, spent by POST only.

    A subclass with a fixed scope, for the reason ForgottenPasswordThrottle
    gives: ScopedRateThrottle reads its scope off the view on every request.
    And not ``throttle_scope`` on the view either, because the same view answers
    the login screen's GET, which must never spend the sign-in budget.
    """

    scope = 'google_login'

    def allow_request(self, request, view):
        if request.method == 'GET':
            return True
        return super().allow_request(request, view)


STAFF_REFUSAL = (
    "Google sign-in isn't available for staff logins. Sign in with your password."
)
NOT_ENABLED = "Google sign-in isn't set up yet."
UNAVAILABLE = "Couldn't reach Google just now. Try again in a moment."


def _verify(request):
    """The verified claims, or a Response to return instead."""
    if not google_auth.is_enabled():
        return None, Response({'detail': NOT_ENABLED}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
    try:
        return google_auth.verify_id_token(request.data.get('id_token')), None
    except google_auth.GoogleTokenError as error:
        return None, Response({'detail': str(error)}, status=status.HTTP_400_BAD_REQUEST)
    except google_auth.GoogleUnavailable:
        return None, Response({'detail': UNAVAILABLE}, status=status.HTTP_503_SERVICE_UNAVAILABLE)


def _username_for(email):
    """A username for a login made through Google, unique in any case.

    The part of the address before the @, cut down to the characters
    registration accepts — the person never types it, but Jess sees it on the
    Logins screen, so it should look like them rather than like a number.
    """
    base = re.sub(r'[^\w.+-]', '', email.split('@', 1)[0])[:30] or 'client'
    if len(base) < 3:
        base = f'{base}_client'
    candidate, suffix = base, 1
    while User.objects.filter(username__iexact=candidate).exists():
        suffix += 1
        candidate = f'{base}{suffix}'
    return candidate


class GoogleSignInView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []
    throttle_classes = [AnonRateThrottle, GoogleLoginThrottle]

    def get(self, request):
        return Response({
            'enabled': google_auth.is_enabled(),
            'server_client_id': settings.GOOGLE_OAUTH_WEB_CLIENT_ID or None,
        })

    def post(self, request):
        claims, refusal = _verify(request)
        if refusal:
            return refusal

        identity = GoogleIdentity.objects.select_related('user').filter(subject=claims['sub']).first()
        created = False
        if identity:
            user = identity.user
            if not user.is_active:
                return Response(
                    {'detail': 'This account has been switched off. Contact Mojo and Co.'},
                    status=status.HTTP_403_FORBIDDEN,
                )
            if user.is_staff or user.is_superuser:
                # Linked before the account was made staff. The link stays —
                # removing it silently would be its own surprise — but it
                # opens nothing.
                return Response({'detail': STAFF_REFUSAL}, status=status.HTTP_403_FORBIDDEN)
        else:
            if User.objects.filter(email__iexact=claims['email']).exists():
                # See GoogleIdentity: the address matching proves nothing about
                # who holds the account's password. Registration already
                # answers "that email is in use", so this discloses nothing new.
                return Response(
                    {
                        'code': 'account_exists',
                        'detail': (
                            'There is already a Mojo and Co account for '
                            f"{claims['email']}. Sign in with your password, then "
                            'connect Google from the account menu.'
                        ),
                    },
                    status=status.HTTP_409_CONFLICT,
                )
            try:
                with transaction.atomic():
                    user = User(
                        username=_username_for(claims['email']),
                        email=claims['email'],
                        first_name=claims['first_name'][:150],
                        last_name=claims['last_name'][:150],
                    )
                    # No password at all, rather than a random one: nothing can
                    # guess it, and "forgotten password" can still give them one.
                    user.set_unusable_password()
                    user.save()
                    identity = GoogleIdentity.objects.create(
                        user=user, subject=claims['sub'], email=claims['email'],
                    )
            except IntegrityError:
                # Two taps landing together for the same Google account.
                return Response(
                    {'detail': 'That sign-in was already being set up. Try again.'},
                    status=status.HTTP_409_CONFLICT,
                )
            created = True

        identity.last_used_at = timezone.now()
        identity.save(update_fields=['last_used_at'])
        token, _ = Token.objects.get_or_create(user=user)
        return Response(
            {'auth_token': token.key, 'created': created},
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class GoogleConnectView(APIView):
    """Link Google to the account already signed in, or unlink it."""

    permission_classes = [IsAuthenticated]
    throttle_classes = [UserRateThrottle]

    def post(self, request):
        user = request.user
        if user.is_staff or user.is_superuser:
            return Response({'detail': STAFF_REFUSAL}, status=status.HTTP_403_FORBIDDEN)
        claims, refusal = _verify(request)
        if refusal:
            return refusal

        existing = GoogleIdentity.objects.filter(subject=claims['sub']).first()
        if existing and existing.user_id != user.id:
            return Response(
                {'detail': 'That Google account is already connected to a different Mojo and Co login.'},
                status=status.HTTP_409_CONFLICT,
            )
        mine = GoogleIdentity.objects.filter(user=user).first()
        if mine and mine.subject != claims['sub']:
            return Response(
                {'detail': f'This login is already connected to {mine.email}. Disconnect that first.'},
                status=status.HTTP_409_CONFLICT,
            )
        identity, created = GoogleIdentity.objects.get_or_create(
            user=user, defaults={'subject': claims['sub'], 'email': claims['email']},
        )
        return Response(
            {'google_email': identity.email},
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )

    def delete(self, request):
        user = request.user
        identity = GoogleIdentity.objects.filter(user=user).first()
        if identity is None:
            return Response(status=status.HTTP_204_NO_CONTENT)
        if not user.has_usable_password():
            return Response(
                {
                    'detail': (
                        'Google is the only way into this account, so disconnecting '
                        "it would lock you out. Use \"I've forgotten my password\" "
                        'on the sign-in screen to get a password first.'
                    ),
                },
                status=status.HTTP_409_CONFLICT,
            )
        identity.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)
