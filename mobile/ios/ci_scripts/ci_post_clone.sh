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

echo "=== Configuring the iOS build ==="
# --config-only stops after writing Generated.xcconfig and running pod install,
# which is all Xcode Cloud needs before it takes over with xcodebuild.
#
# --build-number is the part that matters for TestFlight. pubspec.yaml pins
# `version: 0.1.0+1`, so every build would otherwise be uploaded as build 1 and
# App Store Connect rejects a build number it has already seen — the second
# upload onwards would fail. CI_BUILD_NUMBER increments per Xcode Cloud build,
# and reaches CFBundleVersion through FLUTTER_BUILD_NUMBER in Generated.xcconfig.
flutter build ios \
    --config-only \
    --release \
    --build-number="$CI_BUILD_NUMBER"

echo "=== Ready: $(grep FLUTTER_BUILD_NUMBER ios/Flutter/Generated.xcconfig) ==="
