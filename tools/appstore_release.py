#!/usr/bin/env python3
"""Take a build that Xcode Cloud uploaded and put it in front of customers.

Xcode Cloud stops at "uploaded to App Store Connect". Everything after that —
creating the version, writing What's New, attaching the build, submitting for
review — is manual clicking, which is the part worth automating because it is
the part that gets forgotten or done at 11pm.

It is deliberately a separate step rather than an Xcode Cloud post-action. A
freshly uploaded build sits in PROCESSING for anywhere between two minutes and
half an hour, and nothing can be attached to a version until it finishes. Xcode
Cloud charges for that waiting by the minute and times out; a Linux runner
waits for free.

Usage (see .github/workflows/release.yml, which is what normally runs it):

    export APP_STORE_CONNECT_ISSUER_ID=... KEY_ID=... PRIVATE_KEY="$(cat key.p8)"
    python tools/appstore_release.py --version 1.0.0
    python tools/appstore_release.py --version 1.0.0 --dry-run

--dry-run does every read, prints exactly what it would change, and submits
nothing. Use it the first time: a submission cannot be taken back, and Apple
counts a withdrawn one against you.

Needs: pip install "PyJWT[crypto]" requests
"""

import argparse
import os
import re
import sys
import time
from pathlib import Path

try:
    import jwt
    import requests
except ImportError:  # pragma: no cover - a setup problem, not a code path
    sys.exit('Install the dependencies first: pip install "PyJWT[crypto]" requests')

API = 'https://api.appstoreconnect.apple.com/v1'
BUNDLE_ID = 'uk.co.mojoandco.mojoApp'
PLATFORM = 'IOS'

# App Store Connect will not let a version be edited once it is on its way to
# review. Anything outside this set means a human has already started something,
# and writing over it would be worse than stopping.
EDITABLE_STATES = {
    'PREPARE_FOR_SUBMISSION',
    'DEVELOPER_REJECTED',
    'REJECTED',
    'METADATA_REJECTED',
    'INVALID_BINARY',
}

WHATS_NEW_LIMIT = 4000


class AppStoreError(RuntimeError):
    pass


# ── Auth ───────────────────────────────────────────────────────────────

def make_token():
    """A 15-minute ES256 token, as App Store Connect requires.

    Apple rejects anything valid for more than 20 minutes, so this is minted per
    run rather than cached anywhere.
    """
    issuer = os.environ.get('APP_STORE_CONNECT_ISSUER_ID', '').strip()
    key_id = os.environ.get('APP_STORE_CONNECT_KEY_ID', '').strip()
    private_key = os.environ.get('APP_STORE_CONNECT_PRIVATE_KEY', '').strip()

    missing = [
        name for name, value in [
            ('APP_STORE_CONNECT_ISSUER_ID', issuer),
            ('APP_STORE_CONNECT_KEY_ID', key_id),
            ('APP_STORE_CONNECT_PRIVATE_KEY', private_key),
        ] if not value
    ]
    if missing:
        raise AppStoreError(
            'Missing credentials: ' + ', '.join(missing) + '. '
            'These come from App Store Connect → Users and Access → Integrations → '
            'App Store Connect API, and live in the repository secrets.'
        )

    # A .p8 pasted into a secret often arrives with literal \n instead of real
    # newlines, which fails deep inside the crypto library with an unhelpful
    # message. Fix it here rather than making someone debug it there.
    if '\\n' in private_key and '\n' not in private_key:
        private_key = private_key.replace('\\n', '\n')

    if 'BEGIN PRIVATE KEY' not in private_key:
        raise AppStoreError(
            'APP_STORE_CONNECT_PRIVATE_KEY does not look like a .p8 file. It '
            'wants the whole thing, including the "-----BEGIN PRIVATE KEY-----" '
            'and "-----END PRIVATE KEY-----" lines — not just the middle, and '
            'not the key ID.'
        )

    now = int(time.time())
    try:
        return jwt.encode(
            {'iss': issuer, 'iat': now, 'exp': now + 15 * 60, 'aud': 'appstoreconnect-v1'},
            private_key,
            algorithm='ES256',
            headers={'kid': key_id, 'typ': 'JWT'},
        )
    except Exception as error:  # noqa: BLE001 — the crypto layer's errors are unreadable
        raise AppStoreError(
            f'Could not sign with that private key ({error}). The usual cause is '
            'the .p8 losing its line breaks on the way into the secret — paste '
            'the file contents whole, exactly as downloaded.'
        ) from error


class Client:
    def __init__(self, dry_run=False):
        self.token = make_token()
        self.dry_run = dry_run
        self.session = requests.Session()

    def _call(self, method, path, **kwargs):
        url = path if path.startswith('http') else f'{API}{path}'
        try:
            response = self.session.request(
                method,
                url,
                headers={
                    'Authorization': f'Bearer {self.token}',
                    'Content-Type': 'application/json',
                },
                timeout=60,
                **kwargs,
            )
        except requests.RequestException as error:
            raise AppStoreError(f'Could not reach App Store Connect: {error}') from error
        if response.status_code >= 400:
            raise AppStoreError(
                f'{method} {url} failed with {response.status_code}: '
                f'{_readable_errors(response)}'
            )
        return response.json() if response.content else {}

    def get(self, path, **kwargs):
        return self._call('GET', path, **kwargs)

    def write(self, method, path, payload, description):
        """A call that changes something. Announced, and skipped on a dry run."""
        if self.dry_run:
            print(f'  [dry run] would {description}')
            return {}
        print(f'  {description}')
        return self._call(method, path, json=payload)


def _readable_errors(response):
    try:
        errors = response.json().get('errors', [])
    except ValueError:
        return response.text[:400]
    if not errors:
        return response.text[:400]
    return ' | '.join(
        f"{error.get('title', '?')}: {error.get('detail', '')}" for error in errors
    )


# ── Changelog ──────────────────────────────────────────────────────────

def whats_new_for(version, changelog_path):
    """The customer-facing notes for ``version``, straight out of CHANGELOG.md.

    Keeping one copy means the notes on the App Store and the notes in the repo
    cannot disagree, and that writing them is part of cutting the release rather
    than something remembered afterwards in a web form.
    """
    text = Path(changelog_path).read_text(encoding='utf-8')
    pattern = re.compile(
        rf'^##\s*\[{re.escape(version)}\][^\n]*\n(.*?)(?=^##\s|\Z)',
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        raise AppStoreError(
            f'No "## [{version}]" section in {changelog_path}. '
            'Customers read that text on the App Store, so a release without it '
            'would ship blank release notes.'
        )

    notes = match.group(1).strip()
    if not notes:
        raise AppStoreError(f'The [{version}] section in {changelog_path} is empty.')
    if len(notes) > WHATS_NEW_LIMIT:
        raise AppStoreError(
            f'The [{version}] notes are {len(notes)} characters; Apple allows '
            f'{WHATS_NEW_LIMIT}.'
        )
    return notes


# ── The release itself ─────────────────────────────────────────────────

def find_app(client):
    data = client.get('/apps', params={'filter[bundleId]': BUNDLE_ID})['data']
    if not data:
        raise AppStoreError(
            f'No app with bundle id {BUNDLE_ID} is visible to this API key. '
            'Check the key has App Manager access.'
        )
    return data[0]['id']


def wait_for_build(client, app_id, version, timeout_minutes, poll_seconds=60):
    """Block until the uploaded build for ``version`` finishes processing.

    This is the whole reason the step runs here and not in Xcode Cloud. A build
    is not attachable the moment it is uploaded — Apple re-signs and scans it
    first, and how long that takes is entirely up to them.
    """
    deadline = time.time() + timeout_minutes * 60
    reported = None

    while time.time() < deadline:
        builds = client.get('/builds', params={
            'filter[app]': app_id,
            'filter[preReleaseVersion.version]': version,
            'sort': '-uploadedDate',
            'limit': 5,
        })['data']

        if not builds:
            if reported != 'waiting':
                print(f'  no build for {version} uploaded yet, waiting…')
                reported = 'waiting'
        else:
            build = builds[0]
            state = build['attributes'].get('processingState')
            number = build['attributes'].get('version')
            if state == 'VALID':
                print(f'  build {number} of {version} is ready')
                return build['id'], number
            if state in ('FAILED', 'INVALID'):
                raise AppStoreError(
                    f'Build {number} of {version} came back {state}. App Store '
                    'Connect will have emailed the reason.'
                )
            if reported != state:
                print(f'  build {number} is {state}, waiting…')
                reported = state

        time.sleep(poll_seconds)

    raise AppStoreError(
        f'No processed build for {version} after {timeout_minutes} minutes. '
        'Check the Xcode Cloud build actually uploaded.'
    )


def find_or_create_version(client, app_id, version):
    existing = client.get(f'/apps/{app_id}/appStoreVersions', params={
        'filter[versionString]': version,
        'filter[platform]': PLATFORM,
        'limit': 1,
    })['data']

    if existing:
        entry = existing[0]
        state = entry['attributes'].get('appStoreState')
        if state not in EDITABLE_STATES:
            raise AppStoreError(
                f'Version {version} is already {state} in App Store Connect. '
                'Someone has started this release by hand — sort that out before '
                'running this again.'
            )
        print(f'  version {version} already exists ({state})')
        return entry['id']

    created = client.write(
        'POST', '/appStoreVersions',
        {
            'data': {
                'type': 'appStoreVersions',
                'attributes': {
                    'platform': PLATFORM,
                    'versionString': version,
                    # Live as soon as Apple approves it, with no second button
                    # to press. This is the setting that makes a tag mean
                    # "release", so it is set explicitly rather than inherited.
                    'releaseType': 'AFTER_APPROVAL',
                },
                'relationships': {'app': {'data': {'type': 'apps', 'id': app_id}}},
            }
        },
        f'create version {version}',
    )
    if client.dry_run:
        return None
    return created['data']['id']


def set_whats_new(client, version_id, notes):
    localizations = client.get(
        f'/appStoreVersions/{version_id}/appStoreVersionLocalizations'
    )['data']
    if not localizations:
        raise AppStoreError('That version has no localizations to write notes into.')

    # Every locale gets the same text. The listing is English-only; if that ever
    # changes this is the place that has to learn about it, and writing to all
    # of them keeps a stale locale from showing last release's notes.
    for localization in localizations:
        locale = localization['attributes'].get('locale')
        client.write(
            'PATCH', f"/appStoreVersionLocalizations/{localization['id']}",
            {
                'data': {
                    'type': 'appStoreVersionLocalizations',
                    'id': localization['id'],
                    'attributes': {'whatsNew': notes},
                }
            },
            f'set What\'s New for {locale}',
        )


def attach_build(client, version_id, build_id, build_number):
    client.write(
        'PATCH', f'/appStoreVersions/{version_id}/relationships/build',
        {'data': {'type': 'builds', 'id': build_id}},
        f'attach build {build_number}',
    )


def submit_for_review(client, app_id, version_id):
    """Submit through reviewSubmissions, not appStoreVersionSubmissions.

    The older endpoint still exists but fails for apps on Apple's current
    submission experience, which is all of them now. A submission is a container
    that items are added to and which is then sent as a whole.
    """
    open_submissions = client.get('/reviewSubmissions', params={
        'filter[app]': app_id,
        'filter[state]': 'READY_FOR_REVIEW',
        'limit': 1,
    })['data']

    if open_submissions:
        submission_id = open_submissions[0]['id']
        print(f'  reusing the open submission {submission_id}')
    else:
        created = client.write(
            'POST', '/reviewSubmissions',
            {
                'data': {
                    'type': 'reviewSubmissions',
                    'attributes': {'platform': PLATFORM},
                    'relationships': {'app': {'data': {'type': 'apps', 'id': app_id}}},
                }
            },
            'open a review submission',
        )
        if client.dry_run:
            return
        submission_id = created['data']['id']

    client.write(
        'POST', '/reviewSubmissionItems',
        {
            'data': {
                'type': 'reviewSubmissionItems',
                'relationships': {
                    'reviewSubmission': {
                        'data': {'type': 'reviewSubmissions', 'id': submission_id}
                    },
                    'appStoreVersion': {
                        'data': {'type': 'appStoreVersions', 'id': version_id}
                    },
                },
            }
        },
        'add the version to the submission',
    )

    client.write(
        'PATCH', f'/reviewSubmissions/{submission_id}',
        {
            'data': {
                'type': 'reviewSubmissions',
                'id': submission_id,
                'attributes': {'submitted': True},
            }
        },
        'send it to Apple for review',
    )


def check_credentials():
    """Answer one question: is the key set up correctly?

    Separate from --dry-run, which still waits for a build to exist. Getting the
    key made, scoped and pasted in is the fiddly part of the setup, and finding
    out whether it worked should not mean waiting an hour for an unrelated
    failure about a missing build.
    """
    # Signing happens locally, so getting this far only proves the .p8 is a
    # usable key — not that Apple has ever heard of it. Say exactly that; a
    # premature "credentials accepted" is worse than no message when someone is
    # working out which of three secrets is wrong.
    client = Client(dry_run=True)
    print('The private key is valid and signed a token.')
    print('Asking App Store Connect whether it accepts it…')

    app_id = find_app(client)
    app = client.get(f'/apps/{app_id}')['data']['attributes']
    print(f"Accepted. Found: {app.get('name')} ({BUNDLE_ID}), app id {app_id}")

    # Reading apps needs only Developer access; submitting needs App Manager,
    # and the difference does not show up until the very last call of a real
    # release. Ask now, while it is cheap to fix.
    try:
        client.get('/reviewSubmissions', params={'filter[app]': app_id, 'limit': 1})
        print('The key can read review submissions, so it has enough access to submit.')
    except AppStoreError:
        print(
            '\nThe key can see the app but not its review submissions, which '
            'usually means its access level is below App Manager. Change it in '
            'App Store Connect → Users and Access → Integrations.'
        )
        return 1

    print('\nAll three secrets are right. A tag will release.')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--check-credentials', action='store_true',
        help='Verify the API key works and stop. Touches nothing, needs no build.',
    )
    parser.add_argument('--version', help='Marketing version, e.g. 1.0.0')
    parser.add_argument('--changelog', default='CHANGELOG.md')
    parser.add_argument(
        '--wait-minutes', type=int, default=60,
        help='How long to wait for Apple to finish processing the upload.',
    )
    parser.add_argument(
        '--dry-run', action='store_true',
        help='Read everything, change nothing. Worth doing once — a submission '
             'cannot be taken back.',
    )
    args = parser.parse_args()

    if args.check_credentials:
        try:
            return check_credentials()
        except AppStoreError as error:
            print(f'\nCredentials not working: {error}', file=sys.stderr)
            return 1

    if not args.version:
        parser.error('--version is required (or use --check-credentials)')

    version = args.version.lstrip('v')

    try:
        # Read the notes before touching the API: a missing changelog section
        # should stop the release, not leave it half-made.
        notes = whats_new_for(version, args.changelog)
        print(f"What's New for {version} ({len(notes)} characters):\n")
        print('\n'.join(f'    {line}' for line in notes.splitlines()))
        print()

        client = Client(dry_run=args.dry_run)
        if args.dry_run:
            print('DRY RUN — nothing will be changed.\n')

        print('Finding the app…')
        app_id = find_app(client)

        print(f'Waiting for a processed build of {version}…')
        build_id, build_number = wait_for_build(client, app_id, version, args.wait_minutes)

        print(f'Preparing version {version}…')
        version_id = find_or_create_version(client, app_id, version)
        if version_id is None:
            print('\nDry run stops here — there is no version to write notes into yet.')
            return 0

        set_whats_new(client, version_id, notes)
        attach_build(client, version_id, build_id, build_number)

        print('Submitting for review…')
        submit_for_review(client, app_id, version_id)

    except AppStoreError as error:
        print(f'\nRelease stopped: {error}', file=sys.stderr)
        return 1

    if args.dry_run:
        print('\nDry run finished. Nothing was submitted.')
    else:
        print(
            f'\n{version} (build {build_number}) is with Apple. It goes live '
            'automatically once approved — usually a day or so, and App Store '
            'Connect emails either way.'
        )
    return 0


if __name__ == '__main__':
    sys.exit(main())
