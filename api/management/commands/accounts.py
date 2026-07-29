"""List the logins on this installation.

The question this exists to answer is "what is my username?". Usernames are
chosen at registration or set from ``DJANGO_SUPERUSER_USERNAME`` on first boot,
so nothing in the repository knows what they are — only the running database
does. Reaching for the Django shell to find out is a poor answer when someone
is locked out and reading instructions off a phone.

Prints no passwords or tokens: there is nothing here that is not already
visible in the admin.
"""

from django.contrib.auth.models import User
from django.core.management.base import BaseCommand
from django.utils import timezone


class Command(BaseCommand):
    help = 'List the accounts on this installation, newest last.'

    def add_arguments(self, parser):
        parser.add_argument('--staff', action='store_true', help='Staff accounts only.')
        parser.add_argument('--search', default='', help='Match username, email or name.')

    def handle(self, *args, **options):
        users = User.objects.select_related('client').order_by('date_joined')
        if options['staff']:
            users = users.filter(is_staff=True)
        if options['search']:
            term = options['search']
            users = users.filter(username__icontains=term) | users.filter(email__icontains=term)

        rows = list(users)
        if not rows:
            self.stdout.write('No accounts match.')
            return

        width = max(len(user.username) for user in rows)
        for user in rows:
            marks = []
            if user.is_superuser:
                marks.append('superuser')
            elif user.is_staff:
                marks.append('staff')
            if not user.is_active:
                marks.append('disabled')
            client = getattr(user, 'client', None)
            if client:
                marks.append(f'client {client.uid}')
            last = user.last_login
            when = 'never signed in' if last is None else f'last in {timezone.localtime(last):%d %b %Y}'

            line = f'{user.username:<{width}}  {user.email or "(no email)":<32}  {when}'
            if marks:
                line += f'  [{", ".join(marks)}]'
            self.stdout.write(line)

        self.stdout.write('')
        self.stdout.write(f'{len(rows)} account{"" if len(rows) == 1 else "s"}.')
