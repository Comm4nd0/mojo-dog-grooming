#!/bin/sh

# Xcode Cloud post-clone script.
#
# Xcode Cloud clones the repository and runs xcodebuild. It knows nothing about
# Flutter, and this project cannot be built from a clean checkout without it:
# `ios/Flutter/Generated.xcconfig` is gitignored (it hardcodes a machine-local
# FLUTTER_ROOT) and the Pods directory is not committed. Without this script the
# build fails immediately on the missing xcconfig.
#
# Runs from mobile/ios/ci_scripts, which Xcode Cloud uses as the working
# directory. Keep it executable (chmod +x) or Xcode Cloud silently skips it.

set -e

# Match the SDK developers build with. Pinned to a tag rather than tracking
# `stable`, so a Flutter release can never change what CI produces on its own.
FLUTTER_VERSION="3.41.9"
FLUTTER_HOME="$CI_WORKSPACE_PATH/flutter"

echo "=== Installing Flutter $FLUTTER_VERSION ==="
git clone https://github.com/flutter/flutter.git \
    --depth 1 --branch "$FLUTTER_VERSION" "$FLUTTER_HOME"
export PATH="$FLUTTER_HOME/bin:$PATH"

# Xcode Cloud images have shipped with and without CocoaPods over time; the
# Flutter tool needs it to resolve the plugin pods.
if ! command -v pod > /dev/null 2>&1; then
    echo "=== Installing CocoaPods ==="
    HOMEBREW_NO_AUTO_UPDATE=1 brew install cocoapods
fi

flutter --version
flutter precache --ios

cd "$CI_PRIMARY_REPOSITORY_PATH/mobile"

# ── Which version is being built ───────────────────────────────────────
#
# Two kinds of build reach this script and they must not be stamped the same:
#
#   * a push to main, which goes to TestFlight for Jess to try;
#   * a v1.0.0 tag, which goes to the App Store for customers.
#
# The version users see comes from pubspec.yaml via $(FLUTTER_BUILD_NAME) in
# Info.plist. On a tag build the tag is authoritative and pubspec must agree
# with it — a tag that says 1.0.0 producing a binary that says 0.1.0 is the
# kind of mistake nobody notices until a customer reports the old bug is back.
PUBSPEC_VERSION=$(grep '^version:' pubspec.yaml | head -1 | sed 's/^version:[[:space:]]*//' | cut -d'+' -f1)

if [ -n "$CI_TAG" ]; then
    TAG_VERSION=$(echo "$CI_TAG" | sed 's/^v//')
    if [ "$TAG_VERSION" != "$PUBSPEC_VERSION" ]; then
        echo "!!! Tag $CI_TAG says $TAG_VERSION but pubspec.yaml says $PUBSPEC_VERSION."
        echo "!!! Use tools/release.sh, which sets both together."
        exit 1
    fi
    BUILD_NAME="$TAG_VERSION"
    echo "=== Release build of $BUILD_NAME (tag $CI_TAG) ==="
else
    BUILD_NAME="$PUBSPEC_VERSION"
    echo "=== TestFlight build of $BUILD_NAME (branch ${CI_BRANCH:-unknown}) ==="
fi

# CI_BUILD_NUMBER counts *per Xcode Cloud workflow*, so the TestFlight workflow
# and the release workflow each start at 1 and will collide — and App Store
# Connect rejects a build number it has already seen for a version. Minutes
# since 2026-01-01 is monotonic, shared by every workflow and machine, and
# cannot repeat, which is the only property that actually matters here.
BUILD_NUMBER=$(( ($(date +%s) - 1767225600) / 60 ))

echo "=== Checking the app still works before building it ==="
# Cheap (a few seconds) next to an Xcode archive, and the last chance to stop a
# broken build reaching customers without anyone looking at it.
flutter pub get
flutter analyze
flutter test

echo "=== Configuring the iOS build ==="
# --config-only stops after writing Generated.xcconfig and running pod install,
# which is all Xcode Cloud needs before it takes over with xcodebuild. Both
# version fields reach the binary through that xcconfig.
flutter build ios \
    --config-only \
    --release \
    --build-name="$BUILD_NAME" \
    --build-number="$BUILD_NUMBER"

echo "=== Ready: $BUILD_NAME ($BUILD_NUMBER) ==="
grep 'FLUTTER_BUILD_NAME\|FLUTTER_BUILD_NUMBER' ios/Flutter/Generated.xcconfig
