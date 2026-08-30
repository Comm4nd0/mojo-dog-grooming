// App Store / Play Store screenshot harness.
//
// This drives the REAL app, signed in as a curated demo CLIENT account on the
// live backend, and captures each client-facing screen that sells the app:
// their dogs, a dog's profile, a groom report, their bookings and the
// request-an-appointment sheet — with the login screen (and the new logo)
// captured last in numbering so the listing leads with value.
//
// A **client** account on purpose, never a staff one: the demo credentials
// also go to App Review, and a staff login is Jess's whole client book.
// ClientScopedMixin means the demo account can only ever photograph its own
// seeded records. Seed them with `python manage.py seed_demo_data` — see
// SCREENSHOTS.md.
//
// It is run via `flutter drive` (see test_driver/integration_test.dart) by the
// tool/screenshots.sh script, which loops over the required device sizes.
//
// Credentials are passed at build time so they never live in the repo:
//   flutter drive ... \
//     --dart-define=DEMO_USERNAME=demo \
//     --dart-define=DEMO_PASSWORD=•••••
//
// Each capture is deterministic: navigate, confirm arrival by a marker that
// only exists on the intended screen, then shoot. A step that can't confirm
// logs and skips rather than failing the whole run — a missing shot is
// visible in the artifact, a failed run delivers nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mojo_app/main.dart';
import 'package:mojo_app/screens/client/groom_report_screen.dart';
import 'package:mojo_app/screens/staff/dog_profile_screen.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/service_locator.dart';

const _demoUsername = String.fromEnvironment('DEMO_USERNAME');
const _demoPassword = String.fromEnvironment('DEMO_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('client store screenshots', (tester) async {
    _log('test started');
    expect(
      _demoUsername.isNotEmpty && _demoPassword.isNotEmpty,
      isTrue,
      reason: 'Pass --dart-define=DEMO_USERNAME=.. and --dart-define=DEMO_PASSWORD=..',
    );

    // Mirror main(): the locator, then a settled auth state. Start signed
    // OUT so MojoApp lands on the login screen we want to shoot.
    setupLocator();
    final auth = getIt<AuthService>();
    try {
      await auth.restore();
      _log('auth restored (signedIn=${auth.isSignedIn})');
    } catch (e) {
      _log('restore failed (continuing): $e');
    }
    try {
      await auth.signOut();
      _log('signed out');
    } catch (e) {
      _log('signOut failed (continuing): $e');
    }

    await tester.pumpWidget(const MojoApp());
    _log('pumped MojoApp (signed out)');
    await _waitFor(tester, seconds: 4);

    // Required before screenshots on BOTH Android and iOS — render the live
    // Flutter surface into an image. Call once, after the first frames.
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    _log('surface converted');

    // ── 06. Login ──────────────────────────────────────────────────────────
    // The logo and the sign-in form. Shot now (signed out is the only time it
    // exists) but numbered last so the listing leads with the app's value.
    if (find.text('DOG GROOMING').evaluate().isNotEmpty) {
      await binding.takeScreenshot('06_login');
      _log('shot 06_login');
    } else {
      _log('login screen marker not found — skipped 06_login');
    }

    // Sign in as the demo client (real network call to the live API). MojoApp
    // listens to AuthService, so the tree swaps to ClientShell by itself —
    // no navigator surgery needed.
    _log('signing in…');
    await auth.signIn(_demoUsername, _demoPassword);
    _log('signed in (staff=${auth.isStaff})');
    expect(auth.isSignedIn, isTrue, reason: 'Demo sign-in failed');
    await _waitFor(tester, seconds: 6);

    // ── 01. My dogs ────────────────────────────────────────────────────────
    final onMyDogs = find.text('My dogs').evaluate().isNotEmpty;
    _log('on my dogs: $onMyDogs');
    if (onMyDogs) {
      await binding.takeScreenshot('01_my_dogs');
      _log('shot 01_my_dogs');
    }

    // ── 02. Dog profile ────────────────────────────────────────────────────
    // The dog rows are the only ListTiles on this screen (the rail and the
    // bottom tabs are neither), so the first one is the demo dog.
    final dogRow = find.byType(ListTile);
    if (dogRow.evaluate().isNotEmpty) {
      await tester.tap(dogRow.first);
      await _waitFor(tester, seconds: 6);
    }
    final onProfile = find.byType(DogProfileScreen).evaluate().isNotEmpty;
    _log('on dog profile: $onProfile');
    if (onProfile) {
      await binding.takeScreenshot('02_dog_profile');
      _log('shot 02_dog_profile');

      // ── 03. Groom report — the owner's window on a visit ─────────────────
      // Report tiles lead with the scissors (a nails visit shows a paw); no
      // other client-visible tile uses either icon.
      var reportTile = find.widgetWithIcon(ListTile, Icons.content_cut);
      if (reportTile.evaluate().isEmpty) {
        reportTile = find.widgetWithIcon(ListTile, Icons.pets_outlined);
      }
      await _ensureVisible(tester, reportTile);
      if (reportTile.evaluate().isNotEmpty) {
        await tester.tap(reportTile.first);
        await _waitFor(tester, seconds: 3);
        if (find.byType(GroomReportScreen).evaluate().isNotEmpty) {
          await binding.takeScreenshot('03_groom_report');
          _log('shot 03_groom_report');
          await _goBack(tester);
        } else {
          _log('report screen not reached — skipped 03_groom_report');
        }
      } else {
        _log('no report tile found — skipped 03_groom_report');
      }

      // Back to the shell for the tabs.
      await _goBack(tester);
    } else {
      _log('could not reach dog profile — skipped 02/03');
    }

    // ── 04. Bookings ───────────────────────────────────────────────────────
    // 'Bookings' labels the destination in both layouts — the bottom bar on a
    // phone and the rail on an iPad.
    await _tapText(tester, 'Bookings');
    await _waitFor(tester, seconds: 4);
    final onBookings = find.text('My bookings').evaluate().isNotEmpty;
    _log('on bookings: $onBookings');
    if (onBookings) {
      await binding.takeScreenshot('04_bookings');
      _log('shot 04_bookings');

      // ── 05. Request an appointment ───────────────────────────────────────
      await _tapText(tester, 'REQUEST');
      await _waitFor(tester, seconds: 3);
      if (find.text('Request an appointment').evaluate().isNotEmpty) {
        await binding.takeScreenshot('05_request');
        _log('shot 05_request');
      } else {
        _log('request sheet did not open — skipped 05_request');
      }
    }

    _log('test finished');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

final List<String> _trace = [];

void _log(String message) {
  // Prefixed so it's easy to grep in the flutter drive output.
  // ignore: avoid_print
  print('SS> $message');
  // The iOS simulator log reader drops app-side prints intermittently, so the
  // trace also rides in reportData — the driver prints it host-side when the
  // run ends. MERGE into reportData, never replace it: takeScreenshot() keeps
  // the captured PNGs there, and assigning a fresh map discards every one.
  _trace.add(message);
  try {
    final binding = IntegrationTestWidgetsFlutterBinding.instance;
    final data = binding.reportData ?? <String, dynamic>{};
    data['trace'] = List<String>.of(_trace);
    binding.reportData = data;
  } catch (_) {}
}

/// Tap a widget found by its exact visible text, logging (rather than failing)
/// if it isn't on screen — keeps the harness resilient to small UI changes.
Future<void> _tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  if (finder.evaluate().isEmpty) {
    _log('tap target not found: "$text"');
    return;
  }
  await tester.tap(finder.first);
  await tester.pump(const Duration(milliseconds: 300));
}

/// Pumps frames in real time for [seconds], letting real async work (network
/// loads, image decoding) complete without the hangs `pumpAndSettle` can hit
/// on screens with continuous animations or polling.
Future<void> _waitFor(WidgetTester tester, {required int seconds}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Best-effort scroll until [finder] is on screen.
Future<void> _ensureVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    try {
      await tester.ensureVisible(finder.first);
      await tester.pump(const Duration(milliseconds: 200));
    } catch (_) {}
    return;
  }
  // Not built yet — nudge the profile's list down and look again.
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isEmpty) return;
  for (var i = 0; i < 4 && finder.evaluate().isEmpty; i++) {
    await tester.drag(scrollable.first, const Offset(0, -900));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _goBack(WidgetTester tester) async {
  try {
    await tester.pageBack();
  } catch (_) {
    final back = find.byTooltip('Back');
    if (back.evaluate().isNotEmpty) await tester.tap(back.first);
  }
  await _waitFor(tester, seconds: 2);
}
