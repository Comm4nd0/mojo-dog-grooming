# Releasing

Live is on the App Store. TestFlight is for Jess to try things before customers
see them. **A tag is the only thing that reaches customers** — pushing to `main`
never does.

## Cutting a release

```bash
# 1. Write what customers will read, under a new "## [1.11.0]" heading.
$EDITOR CHANGELOG.md

# 2. Tag it.
./tools/release.sh 1.11.0
```

That is the whole job. The script sets `mobile/pubspec.yaml`, dates the
changelog entry, commits, tags and pushes. From there:

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

`release.yml` needs a key to submit on your behalf. App Store Connect → Users
and Access → Integrations → App Store Connect API → **+**:

- Access: **App Manager** (less than this cannot submit for review).
- Download the `.p8`. Apple lets you download it **once**.

Then GitHub → Settings → Secrets and variables → Actions → New repository secret,
three times:

| Secret | Where it comes from |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID above the key list |
| `APP_STORE_CONNECT_KEY_ID` | The key's ID column |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The whole `.p8` file contents, `-----BEGIN` line and all |

### Try it without submitting anything

Before trusting it with a real release, run the workflow by hand:

GitHub → Actions → **Release to the App Store** → Run workflow → version
`1.10.0`, dry run **true**.

It authenticates, finds the app, reads the changelog and prints every change it
*would* make without making any. That is worth doing once: a submission cannot
be withdrawn without it counting against you.

You can do the same locally:

```bash
pip install "PyJWT[crypto]" requests
export APP_STORE_CONNECT_ISSUER_ID=... APP_STORE_CONNECT_KEY_ID=...
export APP_STORE_CONNECT_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"
python tools/appstore_release.py --version 1.10.0 --dry-run
```

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

**"Version 1.11.0 is already PENDING_DEVELOPER_RELEASE"** — someone started the
release by hand in App Store Connect. The script refuses to write over a version
it did not create. Finish or delete it there, then re-run the workflow.

**"No processed build for 1.11.0 after 60 minutes"** — the Xcode Cloud build
failed or never started. Check the Report navigator in Xcode; the tag pattern
`v*` on the Release workflow is the usual culprit.

**Tag pushed by mistake** — delete it before Xcode Cloud finishes:

```bash
git push origin :refs/tags/v1.11.0
git tag -d v1.11.0
```

Once the review submission is in, cancel it in App Store Connect instead.

**Apple rejected it** — fix the code, then release a new patch version. Versions
are never reused; App Store Connect will not take a second binary under one.

## Android

Not automated, and not currently shippable: `mobile/android/app/build.gradle.kts`
signs release builds with the **debug** key. Getting Play working needs a release
keystore, Gradle signing wired to environment variables, and a Play Console
service account. None of that is in place.
