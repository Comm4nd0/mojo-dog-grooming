import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/screens/staff/calendar_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/groom_timer_service.dart';
import 'package:mojo_app/services/service_locator.dart';
import 'package:mojo_app/widgets/calendar/day_timeline.dart';

/// Jess: *"on the calendar view can swiping left and right allow swiping
/// smoothly through the days?"* The day view is a pager now, one page per
/// day, and the date strip above it has to follow — a strip that says Monday
/// over Tuesday's diary is worse than no strip.
void main() {
  tearDown(getIt.reset);

  const emptyPage = '{"count":0,"next":null,"previous":null,"results":[]}';

  void installServices() {
    final api = ApiClient(
      baseUrl: 'http://test/api',
      httpClient: MockClient((_) async => http.Response(
            emptyPage,
            200,
            headers: const {'content-type': 'application/json'},
          )),
    );
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<AuthService>(_StaffAuth(api));
    getIt.registerSingleton<DataService>(DataService(api));
    getIt.registerSingleton<GroomTimerService>(GroomTimerService());
  }

  final monday = DateTime(2026, 8, 3);

  Future<void> pumpCalendar(WidgetTester tester, {DateTime? at}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    installServices();
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.lightTheme(),
      home: CalendarScreen(initialDate: at ?? monday),
    ));
    await tester.pumpAndSettle();
  }

  DateTime shownDay(WidgetTester tester) {
    // The page under the finger is the one whose timeline is centred in the
    // viewport; off-screen neighbours may be built too.
    final timelines = tester.widgetList<DayTimeline>(find.byType(DayTimeline));
    final centre = tester.getSize(find.byType(PageView)).width / 2;
    return timelines
        .map((t) => (t, tester.getRect(find.byWidget(t)).center.dx))
        .reduce((a, b) => (a.$2 - centre).abs() < (b.$2 - centre).abs() ? a : b)
        .$1
        .day;
  }

  testWidgets('a swipe left turns to the next day and the title follows', (tester) async {
    await pumpCalendar(tester);
    expect(shownDay(tester), monday);

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    expect(shownDay(tester), monday.add(const Duration(days: 1)));
    expect(find.text(formatDate(monday.add(const Duration(days: 1)))), findsOneWidget);
  });

  testWidgets('a swipe right turns back a day', (tester) async {
    await pumpCalendar(tester);

    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();

    expect(shownDay(tester), monday.subtract(const Duration(days: 1)));
  });

  testWidgets('tapping the strip slides the pager to that day', (tester) async {
    await pumpCalendar(tester);

    // Thursday of the same week, by its number on the strip.
    await tester.tap(find.text('6').first);
    await tester.pumpAndSettle();

    expect(shownDay(tester), DateTime(2026, 8, 6));
  });

  testWidgets('the Today button lands the pager on today', (tester) async {
    await pumpCalendar(tester);

    await tester.tap(find.byTooltip('Today'));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    expect(shownDay(tester), DateTime(now.year, now.month, now.day));
  });

  group('week view', () {
    // Jess: "should be able to swipe on the week view too".
    String weekTitle(DateTime monday) =>
        '${formatDate(monday)} – ${formatDate(monday.add(const Duration(days: 6)))}';

    Future<void> openWeek(WidgetTester tester) async {
      await tester.tap(find.text('Week'));
      await tester.pumpAndSettle();
    }

    testWidgets('a swipe left turns to the next week', (tester) async {
      await pumpCalendar(tester);
      await openWeek(tester);
      expect(find.text(weekTitle(monday)), findsOneWidget);

      await tester.fling(find.byKey(const ValueKey('week-pager')), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();

      expect(find.text(weekTitle(monday.add(const Duration(days: 7)))), findsOneWidget);
    });

    testWidgets('the chevron slides the pager a week', (tester) async {
      await pumpCalendar(tester);
      await openWeek(tester);

      await tester.tap(find.byTooltip('Previous week'));
      await tester.pumpAndSettle();

      expect(find.text(weekTitle(monday.subtract(const Duration(days: 7)))), findsOneWidget);
    });

    testWidgets('the weekday is kept across the turn', (tester) async {
      // Start on a Wednesday, swipe a week on, drop back into the day view:
      // it should be the next Wednesday, not the next Monday.
      await pumpCalendar(tester, at: DateTime(2026, 8, 5));
      await openWeek(tester);

      await tester.fling(find.byKey(const ValueKey('week-pager')), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();

      expect(shownDay(tester), DateTime(2026, 8, 12));
    });
  });
}

class _StaffAuth extends AuthService {
  _StaffAuth(super.api);
  @override
  bool get isStaff => true;
}
