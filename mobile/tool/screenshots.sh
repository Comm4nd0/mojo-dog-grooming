#!/usr/bin/env bash
#
# Capture App Store + Play Store screenshots by driving the real app, signed in
# as the demo CLIENT account, across the required device sizes. Same shape as
# p4td's tool/screenshots.sh, deliberately — one pattern to learn.
#
# Run from mobile/ on a Mac (iOS sims need macOS). Requires the demo creds:
#
#   export DEMO_USERNAME='demo'
#   export DEMO_PASSWORD='••••••••'
#   ./tool/screenshots.sh            # capture on all devices
#   ./tool/screenshots.sh ios        # iOS only
#   ./tool/screenshots.sh android    # Android only
#
# Raw PNGs land in build/screenshots/<device-key>/ and are then copied into the
# fastlane layout (fastlane/screenshots for iOS deliver, fastlane/metadata for
# Android supply). Then `fastlane upload_ios` / `fastlane upload_android`.
#
# ── EDIT THESE to match the simulators/emulators you have installed ──────────
# Override at runtime by exporting newline-separated lists, e.g. in CI:
#   IOS_DEVICES_ENV=$'iPhone 17 Pro Max'  ANDROID_AVDS_ENV='Pixel_7_API_34'
#
# iOS: simulator names (xcrun simctl list devices). One per required size.
if [[ -n "${IOS_DEVICES_ENV:-}" ]]; then
  IFS=$'\n' read -rd '' -a IOS_DEVICES <<< "$IOS_DEVICES_ENV" || true
else
  IOS_DEVICES=(
    "iPhone 17 Pro Max"          # App Store 6.9" (required)
    "iPad Pro 13-inch (M5)"      # App Store iPad 13" (required — we ship iPad)
  )
fi
# Android: AVD names you created (emulator -list-avds). Phone + tablets.
if [[ -n "${ANDROID_AVDS_ENV:-}" ]]; then
  IFS=$'\n' read -rd '' -a ANDROID_AVDS <<< "$ANDROID_AVDS_ENV" || true
else
  ANDROID_AVDS=(
    "Pixel_7_API_34"             # phone
  )
fi
# Locale folder used by fastlane (App Store + Play locale, e.g. en-GB).
LOCALE="${SCREENSHOT_LOCALE:-en-GB}"
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
cd "$(dirname "$0")/.."   # -> mobile/

if [[ -z "${DEMO_USERNAME:-}" || -z "${DEMO_PASSWORD:-}" ]]; then
  echo "ERROR: set DEMO_USERNAME and DEMO_PASSWORD env vars first." >&2
  exit 1
fi

WHAT="${1:-all}"
DRIVE=(flutter drive
  --driver=test_driver/integration_test.dart
  --target=integration_test/screenshots_test.dart
  --dart-define=DEMO_USERNAME="$DEMO_USERNAME"
  --dart-define=DEMO_PASSWORD="$DEMO_PASSWORD"
)
# SCREENSHOT_VERBOSE=1 adds flutter's verbose output (granular launch/connect
# logging) — useful for diagnosing CI hangs.
[[ -n "${SCREENSHOT_VERBOSE:-}" ]] && DRIVE+=(--verbose)

slugify() { echo "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-'; }

FAILED=0

run_ios() {
  command -v xcrun >/dev/null || { echo "xcrun not found (need macOS/Xcode)"; exit 1; }
  for name in "${IOS_DEVICES[@]}"; do
    local key; key="ios-$(slugify "$name")"
    # A retry of the whole script (CI does this on flaky simulator
    # handshakes) skips devices that already captured successfully.
    if [[ -f "build/screenshots/$key/.complete" ]]; then
      echo "▶  iOS: $name — already captured, skipping"
      continue
    fi
    rm -rf "build/screenshots/$key"
    echo "▶  iOS: $name"
    # In CI the simulator is booted by a dedicated action beforehand
    # (IOS_SKIP_BOOT=1). Locally we boot it ourselves: a headless `simctl boot`
    # often doesn't bring SpringBoard up, so also launch Simulator.app and poll
    # for the real "Booted" state (bootstatus -b is unreliable — can exit -1).
    if [[ -z "${IOS_SKIP_BOOT:-}" ]]; then
      xcrun simctl boot "$name" 2>/dev/null || true
      open -a Simulator >/dev/null 2>&1 || true
      echo "   waiting for $name to finish booting…"
      for _ in $(seq 1 90); do
        if xcrun simctl list devices | grep -F "$name" | grep -q "Booted"; then
          break
        fi
        sleep 2
      done
      sleep 5
    fi
    if SCREENSHOT_OUT="build/screenshots/$key" "${DRIVE[@]}" -d "$name"; then
      # A "passing" drive that delivered no PNGs is still a failure — it has
      # happened on p4td (a bug wiped reportData['screenshots']) and marking
      # it complete would upload nothing without anyone noticing.
      if ls "build/screenshots/$key"/*.png >/dev/null 2>&1; then
        touch "build/screenshots/$key/.complete"
      else
        echo "✗  iOS drive passed but produced no screenshots for $name"
        FAILED=1
      fi
    else
      echo "✗  iOS capture failed for $name (continuing with remaining devices)"
      FAILED=1
    fi
    [[ -z "${IOS_SKIP_BOOT:-}" ]] && xcrun simctl shutdown "$name" 2>/dev/null || true
  done
}

run_android() {
  command -v emulator >/dev/null || { echo "android emulator not found"; exit 1; }
  for avd in "${ANDROID_AVDS[@]}"; do
    local key; key="android-$(slugify "$avd")"
    echo "▶  Android: $avd"
    rm -rf "build/screenshots/$key"
    emulator -avd "$avd" -no-snapshot -no-boot-anim -netdelay none -netspeed full >/dev/null 2>&1 &
    local pid=$!
    adb wait-for-device
    # wait for full boot
    until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do sleep 2; done
    if ! SCREENSHOT_OUT="build/screenshots/$key" "${DRIVE[@]}" -d emulator-5554; then
      echo "✗  Android capture failed for $avd (continuing with remaining devices)"
      FAILED=1
    fi
    adb -s emulator-5554 emu kill 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

# NOTE: deliberately NOT `rm -rf build/screenshots` here — a CI retry of the
# whole script must keep the devices that already captured (.complete markers).
[[ "$WHAT" == "all" || "$WHAT" == "ios" ]] && run_ios
[[ "$WHAT" == "all" || "$WHAT" == "android" ]] && run_android

# ── Organise raw captures into the fastlane layout ───────────────────────────
echo "▶  Organising into fastlane layout…"
# iOS deliver: fastlane/screenshots/<locale>/  (deliver maps device by pixel
# size). Prefix each file with its device key: every device captures the same
# shot names (01_my_dogs.png…), so unprefixed iPhone and iPad copies would
# overwrite each other in the shared locale folder.
mkdir -p "fastlane/screenshots/$LOCALE"
for d in build/screenshots/ios-*; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*.png; do
    [[ -e "$f" ]] || continue
    cp "$f" "fastlane/screenshots/$LOCALE/$(basename "$d")_$(basename "$f")"
  done
done

# Android supply: fastlane/metadata/android/<locale>/images/{phone,sevenInch,tenInch}Screenshots/
android_dir="fastlane/metadata/android/$LOCALE/images"
mkdir -p "$android_dir/phoneScreenshots" "$android_dir/sevenInchScreenshots" "$android_dir/tenInchScreenshots"
for d in build/screenshots/android-*; do
  [[ -d "$d" ]] || continue
  case "$d" in
    *tablet*|*nexus-9*|*10*|*pixel-tablet*) dest="$android_dir/tenInchScreenshots" ;;
    *seven*|*7in*)                          dest="$android_dir/sevenInchScreenshots" ;;
    *)                                       dest="$android_dir/phoneScreenshots" ;;
  esac
  cp "$d"/*.png "$dest/" 2>/dev/null || true
done

echo "▶  Captured files:"
find build/screenshots -name '*.png' | sort || true

if [[ "$FAILED" != "0" ]]; then
  echo "✗  One or more devices failed to capture." >&2
  exit 1
fi
echo "✅  Raw screenshots captured."
echo "    Next: fastlane upload_ios  /  fastlane upload_android"
