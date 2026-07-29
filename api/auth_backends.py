"""Sign in with a username *or* an email address, either case.

Django's stock backend matches the username exactly, which is a bad fit here.
Clients sign up once, on a phone keyboard that capitalises the first letter,
and then come back weeks later and type whatever they remember — often the
email address they gave Jess, because that is what she has on file for them.
"Jess" failing when the account is "jess" reads as a broken app, not as a
rejected credential.

Two rules keep this from widening what a password unlocks:

* An exact username match always wins. Without that, someone could register the
  username ``alice@example.com`` and start intercepting Alice's sign-in
  attempts — the password would still have to be right, but the lookup should
  never be steerable by what another user picked as their name.
* An ambiguous identifier authenticates nobody. Django does not enforce
  case-insensitive uniqueness on usernames, and nothing enforces unique emails
  on rows that predate ``MojoUserCreateSerializer``, so "matches two accounts"
  is possible and must fail closed rather than pick one.
"""

from django.contrib.auth import get_user_model
from django.contrib.auth.backends import ModelBackend
from django.db.models import Q


class UsernameOrEmailBackend(ModelBackend):
    def authenticate(self, request, username=None, password=None, **kwargs):
        User = get_user_model()
        identifier = (username or kwargs.get(User.USERNAME_FIELD) or '').strip()
        if not identifier or not password:
            return None

        candidates = list(
            User.objects.filter(Q(username__iexact=identifier) | Q(email__iexact=identifier))[:5]
        )
        exact = [user for user in candidates if user.username == identifier]
        if exact:
            candidates = exact

        if len(candidates) != 1:
            # No match, or an ambiguous one. Run the hasher anyway so a missing
            # account doesn't answer measurably faster than a wrong password.
            User().set_password(password)
            return None

        user = candidates[0]
        if user.check_password(password) and self.user_can_authenticate(user):
            return user
        return None
