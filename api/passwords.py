"""Issuing, addressing and delivering password reset links.

Delivery is best-effort and never load-bearing. Mojo and Co has no SMTP server
configured by default — intake forms have always been sent by pasting the link
into a message — so every caller here gets the link back and can hand it over
however it suits: WhatsApp, a text, or reading it out over the phone.

That is why :func:`send_reset_email` reports what happened instead of raising.
An email that silently went nowhere would be worse than no email at all: Jess
would tell a client to check their inbox and neither of them would ever find
out why nothing arrived.
"""

import logging

from django.conf import settings
from django.core.mail import send_mail
from django.urls import reverse

logger = logging.getLogger(__name__)


def build_reset_link(token, request=None):
    """The absolute URL of the reset page for ``token``.

    Built from the live request where there is one, so a link generated on the
    LAN during development points at the LAN address rather than the public
    host. ``PUBLIC_BASE_URL`` covers the callers that have no request —
    management commands, and anything run from a shell.
    """
    path = reverse('password-reset-form', args=[token])
    if request is not None:
        return request.build_absolute_uri(path)
    return f'{settings.PUBLIC_BASE_URL}{path}'


def reset_email_body(user, link, business_name, hours):
    greeting = user.first_name or user.username
    return (
        f'Hi {greeting},\n\n'
        f'Someone at {business_name} has sent you a link to set a new password '
        f'for your account ({user.username}).\n\n'
        f'{link}\n\n'
        f'The link works once and expires in {hours} hours. If you did not ask '
        f'for it, you can ignore this email — your password has not changed.\n\n'
        f'{business_name}\n'
    )


def send_reset_email(user, link, business_name, address=None):
    """Try to email the link. Returns ``(sent, error)``.

    ``sent`` is False with no error when email simply is not configured, which
    is the normal case in this deployment rather than a fault.
    """
    to = (address or user.email or '').strip()
    if not to:
        return False, 'That account has no email address on file.'
    if not settings.EMAIL_ENABLED:
        return False, None

    try:
        send_mail(
            subject=f'Set a new password for {business_name}',
            message=reset_email_body(user, link, business_name, settings.PASSWORD_RESET_TTL_HOURS),
            from_email=settings.DEFAULT_FROM_EMAIL,
            recipient_list=[to],
            fail_silently=False,
        )
    except Exception as error:  # noqa: BLE001 — any delivery failure is reported, not raised
        logger.warning('Password reset email to %s failed: %s', to, error)
        return False, f'Could not send the email: {error}'
    return True, None
