#!/usr/bin/env bash
#
# Cut a release.
#
#     ./tools/release.sh 1.10.0
#
# Sets the version in pubspec.yaml, dates the changelog entry, commits, tags and
# pushes. The tag is what starts everything else: Xcode Cloud builds and uploads
# it, and .github/workflows/release.yml submits it for review.
#
# The version lives in three places that have to agree — pubspec.yaml, the git
# tag, and the CHANGELOG heading — and both CI scripts refuse to build if they
# don't. This exists so they are set together rather than remembered separately.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    CURRENT=$(grep '^version:' mobile/pubspec.yaml | head -1 | sed 's/^version:[[:space:]]*//' | cut -d'+' -f1)
    echo "Usage: ./tools/release.sh <version>   (currently $CURRENT)"
    exit 1
fi
VERSION="${VERSION#v}"

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "!!! '$VERSION' is not x.y.z. App Store Connect only accepts that shape."
    exit 1
fi

# ── Checks worth failing on ────────────────────────────────────────────

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "!!! On '$BRANCH'. Releases are cut from main, so that what ships is what"
    echo "!!! CI has been testing."
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "!!! Uncommitted changes. The tag would not describe what you are shipping:"
    git status --short
    exit 1
fi

git fetch --quiet origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "!!! Local main and origin/main have diverged. Pull or push first —"
    echo "!!! CI builds origin, not your working copy."
    exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "!!! Tag v$VERSION already exists. Versions are never reused: App Store"
    echo "!!! Connect will not take a second binary under one."
    exit 1
fi

if ! grep -q "^## \[$VERSION\]" CHANGELOG.md; then
    echo "!!! No '## [$VERSION]' section in CHANGELOG.md."
    echo "!!! That text is what customers read on the App Store — write it first."
    exit 1
fi

# The App Store refuses a version string below the one already live, and the
# failure comes hours later from Apple rather than from here.
PREVIOUS=$(git tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//')
if [ -n "$PREVIOUS" ]; then
    HIGHEST=$(printf '%s\n%s\n' "$PREVIOUS" "$VERSION" | sort -V | tail -1)
    if [ "$HIGHEST" != "$VERSION" ] || [ "$PREVIOUS" = "$VERSION" ]; then
        echo "!!! $VERSION is not above the last released $PREVIOUS."
        exit 1
    fi
fi

# ── Do it ──────────────────────────────────────────────────────────────

echo "Releasing $VERSION (previous tag: ${PREVIOUS:-none})"
echo
sed -n "/^## \[$VERSION\]/,/^## /p" CHANGELOG.md | sed '$d' | sed 's/^/    /'
echo

read -r -p "Tag and push this? Once Apple approves it, it goes live. [y/N] " REPLY
case "$REPLY" in
    [yY]) ;;
    *) echo 'Nothing done.'; exit 0 ;;
esac

# pubspec keeps its build number placeholder; CI replaces it with a monotonic
# one, so there is nothing here worth maintaining by hand.
sed -i.bak -E "s/^version: [0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$/version: $VERSION+1/" mobile/pubspec.yaml
rm -f mobile/pubspec.yaml.bak

TODAY=$(date +%Y-%m-%d)
sed -i.bak -E "s/^## \[$VERSION\].*$/## [$VERSION] - $TODAY/" CHANGELOG.md
rm -f CHANGELOG.md.bak

git add mobile/pubspec.yaml CHANGELOG.md
git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Release $VERSION"

git push origin main
git push origin "v$VERSION"

cat <<EOF

Pushed v$VERSION.

  1. Xcode Cloud builds and uploads it (watch it in Xcode → Report navigator).
  2. The Release workflow waits for that upload, sets What's New from the
     changelog, and submits for review.
  3. Apple reviews it — usually a day. It goes live on approval with nothing
     else to press.

App Store Connect emails you either way.
EOF
