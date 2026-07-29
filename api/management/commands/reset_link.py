"""Mint a password reset link from the command line.

The in-app version needs a signed-in superuser, which is exactly what is
missing when the superuser is the one locked out. This is the way back in for
that case, and it needs nothing but shell access to the host:

    docker compose -f docker-compose.prod.yml exec web python manage.py reset_link jess

``createsuperuser`` would also get someone in, but by adding a second admin
account rather than restoring the first — which then has to be tidied up, and
tends not to be.
"""

from django.conf import settings
from django.contrib.auth.models import User
from django.core.management.base import BaseCommand, CommandError
from django.db.models import Q

from api.models import AppSettings, PasswordResetToken
from api.passwords import build_reset_link, send_reset_email


class Command(BaseCommand):
    help = 'Issue a single-use password reset link for an account.'

    def add_arguments(self, parser):
        parser.add_argument('identifier', help='Username or email address.')
        parser.add_argument(
            '--email', action='store_true',
            help='Also email the link (needs EMAIL_HOST configured).',
        )

    def handle(self, *args, **options):
        identifier = options['identifier'].strip()
        matches = list(
            User.objects.filter(Q(username__iexact=identifier) | Q(email__iexact=identifier))[:5]
        )
        exact = [user for user in matches if user.username == identifier]
        if exact:
            matches = exact
        if not matches:
            raise CommandError(
                f'No account matches "{identifier}". Run `manage.py accounts` to see the list.'
            )
        if len(matches) > 1:
            names = ', '.join(user.username for user in matches)
            raise CommandError(f'"{identifier}" matches several accounts ({names}). Use the username.')

        user = matches[0]
        reset = PasswordResetToken.issue(user)
        # No request to build from out here, so the host comes from
        # PUBLIC_BASE_URL. Check it if the link below looks wrong.
        link = build_reset_link(reset.token)

        self.stdout.write(self.style.SUCCESS(f'Reset link for {user.username}:'))
        self.stdout.write('')
        self.stdout.write(f'  {link}')
        self.stdout.write('')
        self.stdout.write(
            f'Works once, expires in {settings.PASSWORD_RESET_TTL_HOURS} hours. '
            'Any earlier link for this account has just been voided.'
        )

        if options['email']:
            sent, error = send_reset_email(user, link, AppSettings.get().business_name)
            if sent:
                self.stdout.write(self.style.SUCCESS(f'Emailed to {user.email}.'))
            else:
                self.stdout.write(self.style.WARNING(
                    error or 'Email is not configured (set EMAIL_HOST) — send the link by hand.'
                ))
