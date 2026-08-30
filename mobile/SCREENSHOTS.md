# Store screenshots — automated

Generate App Store **and** Play Store screenshots from one Flutter integration
test and upload them — no manual capturing on each device. Same pipeline as
p4td's, deliberately: one pattern to learn.

How it works: the test signs in as a **demo client account** on the real
backend and walks the client screens — My dogs, the dog profile, a groom
report, My bookings, the request sheet, and the login screen with the logo —
taking a screenshot at each. A script runs that test across the required
device sizes; fastlane then uploads them.

```
seed demo data ──► capture (per device) ──► upload
 (Django cmd)        tool/screenshots.sh      fastlane upload_*
```

> **A client account, never staff.** These credentials sit in GitHub secrets
> and will eventually be handed to App Review — and a staff login is Jess's
> entire client book. `ClientScopedMixin` confines the demo account to the
> records the seed command creates.

> **Plain screenshots, no framing.** The shots are uploaded as captured — no
> device bezels and no captions burned onto the image. `frameit` has no frames
> for the simulator/emulator resolutions we capture at, so framing is
> deliberately not used (p4td learned this the slow way).

## CI (GitHub Actions — no Mac needed)

1. Seed the demo account against production (once, and after any password
   rotation):
   ```bash
   ssh root@178.104.29.66
   cd /root/mojo-dog-grooming
   docker compose -f docker-compose.prod.yml exec -T web \
     python manage.py seed_demo_data --password '<pick one>' < /dev/null
   ```
   Idempotent — re-running updates in place and never touches anything outside
   the `MOJO-DEMO` client.
2. Add these repository **secrets** (Settings → Secrets and variables →
   Actions):
   | Secret | For |
   |---|---|
   | `DEMO_USERNAME`, `DEMO_PASSWORD` | the seeded demo client login |
   | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key — create at App Store Connect → Users and Access → Integrations; `ASC_KEY_P8` is the **contents** of the `.p8` file |
   | `PLAY_STORE_SERVICE_ACCOUNT_JSON` | Play upload — only once a Play listing exists (Android is not otherwise shippable yet; see CLAUDE.md) |
3. Actions tab → **Store Screenshots** → **Run workflow**. Pick platforms
   (`both`/`ios`/`android`) and whether to upload. **Upload defaults to off**:
   until the store secrets are in place, the PNGs land as downloadable
   workflow artifacts (`ios-screenshots`, `android-screenshots`) and nothing
   else is attempted.

Devices captured in CI: iPhone 17 Pro Max (covers every iPhone size), iPad
Pro 13" (covers the iPad listing and, via "iPad app on Apple silicon Macs",
the Mac App Store), Pixel 7 emulator (Play phone screenshots).

## Locally (Mac for iOS; anything for Android)

```bash
cd mobile
flutter pub get                      # pulls in integration_test
export DEMO_USERNAME='demo'
export DEMO_PASSWORD='••••••••'
./tool/screenshots.sh                # or `ios` / `android`
```

Raw PNGs land in `build/screenshots/<device>/`, organised copies in
`fastlane/screenshots/` (iOS) and `fastlane/metadata/android/` (Android).
Upload with `cd fastlane && fastlane ios upload_ios` (needs `ASC_KEY_ID`,
`ASC_ISSUER_ID`, `ASC_KEY_PATH`) or `fastlane android upload_android` (needs
`SUPPLY_JSON_KEY`).

## Keeping it honest

- Every capture confirms it reached the intended screen before shooting, and
  **skips with a log line rather than failing** when it can't — a missing
  shot is visible in the artifact; a failed run delivers nothing. The `SS>`
  trace in the drive log says how far the walkthrough got.
- The shot names (`01_my_dogs` … `06_login`) are numbered by story, not by
  capture order: the login screen is captured first (it only exists signed
  out) but listed last, so the store listing leads with the app's value.
- If the client UI changes shape, the finders in
  `integration_test/screenshots_test.dart` are the thing to update — each
  step is labelled.
