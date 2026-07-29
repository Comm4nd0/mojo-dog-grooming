# Releasing

TestFlight is for Jess to try things before customers see them. **A tag is the
only thing that reaches customers** — pushing to `main` never does.

Nothing has gone to the App Store yet; `pubspec.yaml` is at `0.1.0`, which is a
TestFlight number. Whatever the first tag says is the version customers see for
good, because App Store Connect will not accept a version string below one
already released. `1.0.0` is the obvious first one.

## Cutting a release

```bash
# 1. Add what changed under "## [Unreleased]" in the changelog.
$EDITOR CHANGELOG.md

# 2. Tag it.
./tools/release.sh 1.0.0
```

That is the whole job. The script renames the `[Unreleased]` heading to the
version and dates it, sets `mobile/pubspec.yaml`, commits, tags and pushes. From
there:

1. **Xcode Cloud** sees the tag, builds, and uploads to App Store Connect.
2. **`.github/workflows/release.yml`** waits for Apple to finish processing that
   upload, writes the changelog text into "What's New", attaches the build, and
   submits for review.
3. **Apple** reviews it, usually within a day. It goes live on approval —
   nothing else to press.

App Store Connect emails you at each step, including rejections.

The script refuses to run on a dirty tree, off `main`, out of step with
`origin/main`, on a version that is not above the last tag, or without a
changelog section. Each of those has a way of only being noticed hours later,
via an email from Apple.

## One-time setup

Both halves need setting up once. Until they are, tagging builds nothing.

### Xcode Cloud: build on tags

There is already a workflow that builds `main` into TestFlight. Add a second one
for releases — Xcode → Product → Xcode Cloud → Manage Workflows → +:

| Setting | Value |
|---|---|
| Name | Release |
| Start Condition | **Tag Changes**, pattern `v*` |
| Environment | Latest release Xcode, macOS |
| Actions | Archive — iOS |
| Post-Actions | **TestFlight and App Store** |

Leave "Automatically manage version and build number" **off**. The version comes
from the tag via `ci_post_clone.sh`, and letting Xcode Cloud set it too means two
things deciding the same field.

### App Store Connect API key

`release.yml` needs a key to submit on your behalf. This is the fiddly half of
the setup, so in detail:

**1. Make the key.** [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
→ **Users and Access** (top nav) → **Integrations** tab → **App Store Connect
API** in the left sidebar → **Team Keys** → the blue **+**.

- Name: anything — `GitHub Actions` does.
- Access: **App Manager**. Developer is not enough; it can read the app but not
  submit, and that only shows up at the last call of a real release.
- Generate, then **Download** the `.p8`. Apple allows this **once** — if you
  lose it, revoke the key and make another.

If there is no **Integrations** tab, your Apple ID is not an Account Holder or
Admin on the team. Nobody else can make this key for you to use; whoever holds
that role has to create it.

**2. Collect three values.**

| Value | Where |
|---|---|
| Issuer ID | Above the key list, small grey text with a Copy button. A UUID. |
| Key ID | The **KEY ID** column of the key you just made. 10 characters. |
| Private key | The `.p8` file you downloaded, contents and all |

**3. Put them in GitHub.** In this repository: **Settings** → **Secrets and
variables** → **Actions** → **New repository secret**, three times. Names must
match exactly:

| Secret name | Value |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | The issuer UUID |
| `APP_STORE_CONNECT_KEY_ID` | The 10-character key ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | `cat AuthKey_XXXXXXXXXX.p8` and paste **everything**, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines and the line breaks between |

Open the `.p8` in a plain text editor, not Preview or Word. The most common
failure is the key arriving as one long line with its newlines lost.

**4. Check it.** GitHub → **Actions** → **Check App Store credentials** → **Run
workflow**. It takes seconds, submits nothing, and says which of the three is
wrong if any are. Green means a tag will release.

Or locally:

```bash
pip install "PyJWT[crypto]" requests
export APP_STORE_CONNECT_ISSUER_ID=... APP_STORE_CONNECT_KEY_ID=...
export APP_STORE_CONNECT_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
python tools/appstore_release.py --check-credentials
```

What the failures mean:

| Message | Cause |
|---|---|
| `does not look like a .p8 file` | The secret holds the key ID or a fragment, not the file |
| `Could not sign with that private key` | The `.p8` lost its line breaks — repaste it whole |
| `401` / `NOT_AUTHORIZED` | Issuer ID and Key ID are swapped, or the key was revoked |
| `No app with bundle id … is visible` | Right team, wrong app, or the key predates the app |
| `can see the app but not its review submissions` | Access is below App Manager |

### Try it without submitting anything

Once the credentials check passes and a build has been uploaded, rehearse the
release itself:

GitHub → Actions → **Release to the App Store** → Run workflow → version
`1.0.0`, dry run **true**.

It authenticates, finds the app, waits for the build, reads the changelog and
prints every change it *would* make without making any. Worth doing once: a
submission cannot be withdrawn without it counting against you.

Locally, the same:

```bash
python tools/appstore_release.py --version 1.0.0 --dry-run
```

Note the difference from `--check-credentials`: a dry run still waits for a
processed build to exist, so run it after Xcode Cloud has uploaded one.

## Versions

`mobile/pubspec.yaml` is the source of truth. `Info.plist` takes
`CFBundleShortVersionString` from `$(FLUTTER_BUILD_NAME)`, which comes from
there, so that number is what appears on the listing. The `MARKETING_VERSION` in
the Xcode project belongs to the test target and is not what ships — changing it
does nothing.

The tag, `pubspec.yaml` and the `CHANGELOG.md` heading must all agree. Both
`ci_post_clone.sh` and `release.yml` stop the build if they don't, rather than
shipping a binary whose version contradicts its tag.

Build numbers are **minutes since 2026-01-01**, set in `ci_post_clone.sh`.
`CI_BUILD_NUMBER` looks like the obvious choice and is a trap: it counts per
Xcode Cloud workflow, so the TestFlight workflow and the Release workflow both
start at 1, and App Store Connect rejects a build number it has already seen for
a version. A timestamp is monotonic across every workflow and machine and cannot
repeat.

## If something goes wrong

**"Version 1.0.0 is already PENDING_DEVELOPER_RELEASE"** — someone started the
release by hand in App Store Connect. The script refuses to write over a version
it did not create. Finish or delete it there, then re-run the workflow.

**"No processed build for 1.0.0 after 60 minutes"** — the Xcode Cloud build
failed or never started. Check the Report navigator in Xcode; the tag pattern
`v*` on the Release workflow is the usual culprit.

**Tag pushed by mistake** — delete it before Xcode Cloud finishes:

```bash
git push origin :refs/tags/v1.0.0
git tag -d v1.0.0
```

Once the review submission is in, cancel it in App Store Connect instead.

**Apple rejected it** — fix the code, then release a new patch version. Versions
are never reused; App Store Connect will not take a second binary under one.

## Android

Not automated, and not currently shippable: `mobile/android/app/build.gradle.kts`
signs release builds with the **debug** key. Getting Play working needs a release
keystore, Gradle signing wired to environment variables, and a Play Console
service account. None of that is in place.
