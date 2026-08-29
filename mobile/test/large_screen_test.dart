import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/screens/client/client_shell.dart';
import 'package:mojo_app/screens/staff/staff_shell.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/groom_timer_service.dart';
import 'package:mojo_app/services/service_locator.dart';
import 'package:mojo_app/widgets/common.dart';

/// The app on an iPad.
///
/// Every screen here was laid out for a phone, and the iOS build targets
/// tablets too (`TARGETED_DEVICE_FAMILY = "1,2"`, all orientations) — so
/// without these guards the tablet experience is whatever a phone layout does
/// when stretched to 1,300 points, which for a form is a text field you turn
/// your head to read. Two rules hold it together:
///
/// * page content is capped at a readable width by [PageBody], which must be
///   a no-op on phones — nothing below the cap may shift by a pixel;
/// * at [kRailBreakpoint] the shells swap the bottom tabs for a
///   [NavigationRail], because on a tablet in landscape the bottom bar spends
///   the scarcest dimension on navigation.
void main() {
  tearDown(getIt.reset);

  const emptyPage = '{"count":0,"next":null,"previous":null,"results":[]}';

  void installServices({required bool staff}) {
    final mock = MockClient((request) async {
      return http.Response(
        // `/pending/`, `/settings/` and `/me/` are maps; everything else is a
        // page. A page body parses as a map with every count missing, which
        // the models read as zero — exactly the quiet state wanted here.
        emptyPage,
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final api = ApiClient(baseUrl: 'http://test/api', httpClient: mock);
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<AuthService>(staff ? _StaffAuth(api) : _ClientAuth(api));
    getIt.registerSingleton<DataService>(DataService(api));
    getIt.registerSingleton<GroomTimerService>(GroomTimerService());
  }

  Future<void> pumpAt(WidgetTester tester, Size size, Widget home) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: AppColors.lightTheme(), home: home));
    await tester.pumpAndSettle();
  }

  group('PageBody', () {
    testWidgets('is a no-op on a phone', (tester) async {
      // Byte-identical below the cap: this is what keeps every existing phone
      // layout and golden untouched.
      await pumpAt(
        tester,
        const Size(390, 844),
        const Scaffold(body: PageBody(child: SizedBox.expand(key: Key('content')))),
      );
      expect(tester.getSize(find.byKey(const Key('content'))).width, 390);
    });

    testWidgets('caps and centres content on a tablet', (tester) async {
      await pumpAt(
        tester,
        const Size(1366, 1024),
        const Scaffold(body: PageBody(child: SizedBox.expand(key: Key('content')))),
      );
      final rect = tester.getRect(find.byKey(const Key('content')));
      expect(rect.width, 720);
      // Centred, not flushed left — equal margins either side.
      expect(rect.left, closeTo((1366 - 720) / 2, 0.1));
    });
  });

  group('the staff shell', () {
    testWidgets('keeps the bottom tabs on a phone', (tester) async {
      installServices(staff: true);
      await pumpAt(tester, const Size(390, 844), const StaffShell());

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('moves the tabs to a rail on a tablet', (tester) async {
      installServices(staff: true);
      await pumpAt(tester, const Size(1194, 834), const StaffShell());

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      // The list content beside the rail is capped at a readable width, not
      // stretched across the remaining ~1100 points.
      final search = find.widgetWithText(TextField, 'Dog, owner or phone number');
      expect(tester.getSize(search).width, lessThanOrEqualTo(720));
    });

    testWidgets('a running timer is still visible beside the rail', (tester) async {
      // The rail replaces the tabs, not the "a running clock is always
      // visible" rule — the strip moves to the foot of the content area.
      installServices(staff: true);
      await pumpAt(tester, const Size(1194, 834), const StaffShell());

      final timer = getIt<GroomTimerService>();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes(1, 'PREP', 12);
      await tester.pump();

      expect(find.textContaining('Teddy'), findsOneWidget);
      expect(find.text('12:00'), findsOneWidget);
    });
  });

  group('the client shell', () {
    testWidgets('moves the tabs to a rail on a tablet', (tester) async {
      installServices(staff: false);
      await pumpAt(tester, const Size(1194, 834), const ClientShell());

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('keeps the bottom tabs on a phone', (tester) async {
      installServices(staff: false);
      await pumpAt(tester, const Size(390, 844), const ClientShell());

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });
  });
}

/// A staff login, without going near the keychain.
class _StaffAuth extends AuthService {
  _StaffAuth(super.api);
  @override
  bool get isStaff => true;
}

class _ClientAuth extends AuthService {
  _ClientAuth(super.api);
  @override
  bool get isStaff => false;
}
