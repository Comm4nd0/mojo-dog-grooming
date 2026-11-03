import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/screens/staff/calendar_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/groom_timer_service.dart';
import 'package:mojo_app/services/service_locator.dart';

/// Jess: *"With more than two bookings I can't click the last dogs paw print
/// for their profile"* — the + button floated over the last row's paw and
/// the list had nothing to scroll it out from under.
void main() {
  tearDown(getIt.reset);

  final day = DateTime(2026, 11, 2);

  Map<String, dynamic> booking(int id, String dog, int hour) => {
        'id': id, 'dog': id, 'dog_name': dog, 'client_name': 'Owner $id',
        'start_at': DateTime(2026, 11, 2, hour).toIso8601String(),
        'end_at': DateTime(2026, 11, 2, hour + 1).toIso8601String(),
        'duration_minutes': 60, 'status': 'BOOKED', 'booking_type': 'ADHOC',
        'service_type': 'GROOM', 'services': [],
      };

  testWidgets('the last booking\'s paw can be scrolled clear of the + button', (tester) async {
    // An iPhone 15-sized screen, where three bookings filled the list.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = ApiClient(
      baseUrl: 'http://test/api',
      httpClient: MockClient((request) async {
        final results = request.url.path == '/api/appointments/'
            ? [booking(1, 'Zaba', 10), booking(2, 'Louis', 11), booking(3, 'Maisie', 13),
               booking(4, 'Teddy', 15)]
            : [];
        return http.Response(
          jsonEncode({'count': results.length, 'next': null, 'previous': null, 'results': results}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<AuthService>(_StaffAuth(api));
    getIt.registerSingleton<DataService>(DataService(api));
    getIt.registerSingleton<GroomTimerService>(GroomTimerService());

    await tester.pumpWidget(MaterialApp(
      theme: AppColors.lightTheme(),
      home: CalendarScreen(initialDate: day),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();

    final paws = find.byTooltip('Dog profile');
    expect(paws, findsWidgets);
    final list = find.ancestor(of: paws.first, matching: find.byType(Scrollable)).first;
    await tester.drag(list, const Offset(0, -1000));
    await tester.pumpAndSettle();

    final lastPaw = tester.getRect(paws.last);
    final fab = tester.getRect(find.byType(FloatingActionButton));
    expect(lastPaw.overlaps(fab), isFalse,
        reason: 'paw $lastPaw is under the + button $fab');
    expect(lastPaw.bottom, lessThanOrEqualTo(fab.top));
  });
}

class _StaffAuth extends AuthService {
  _StaffAuth(super.api);

  @override
  bool get isStaff => true;
}
