import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/screens/staff/blocked_time_form_screen.dart';
import 'package:mojo_app/screens/staff/client_profile_screen.dart';
import 'package:mojo_app/screens/staff/dog_profile_screen.dart';
import 'package:mojo_app/screens/staff/groom_timer_screen.dart';
import 'package:mojo_app/screens/staff/pending_grooms_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/groom_timer_service.dart';
import 'package:mojo_app/services/offline_store.dart';
import 'package:mojo_app/services/service_locator.dart';
import 'package:mojo_app/widgets/calendar/block_category.dart';

class _Staff extends AuthService {
  _Staff(super.api);
  @override
  bool get isStaff => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });
  tearDown(getIt.reset);
  final log = <http.Request>[];

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    bool dark = false,
    OfflineStore? offline,
    Size size = const Size(390, 1800),
  }) async {
    log.clear();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient(
      baseUrl: 'https://test/api',
      httpClient: MockClient((request) async {
        log.add(request);
        Object value = {'results': [], 'next': null};
        final path = request.url.path;
        if (path == '/api/dogs/1/') {
          value = {
            'id': 1,
            'client': 2,
            'name': 'Bunny',
            'breed': 5,
            'breed_label': 'Cocker Spaniel',
            'owner_grooming': 'Brushing every evening',
            'groom_expectations': 'Round feet',
            'groom_minutes_effective': 90,
          };
        }
        if (path == '/api/breeds/5/') {
          value = {
            'id': 5,
            'name': 'Cocker Spaniel',
            'tail_shape': 'Feathered',
          };
        }
        if (path == '/api/clients/2/') {
          value = {
            'id': 2,
            'first_name': 'Alice',
            'last_name': 'Adams',
            'full_name': 'Alice Adams',
          };
        }
        if (path == '/api/invoices/') {
          value = {
            'results': [
              {
                'id': 3,
                'client': 2,
                'client_name': 'Alice Adams',
                'number': 'INV-0003',
                'total': '50',
                'balance': '50',
                'status': 'DRAFT',
                'lines': [],
              },
            ],
            'next': null,
          };
        }
        if (path == '/api/settings/') value = {'groom_time_buffer_minutes': 10};
        if (request.method == 'POST' && path == '/api/groom-sessions/') {
          value = {
            ...jsonDecode(request.body) as Map<String, dynamic>,
            'id': 99,
          };
        }
        if (path == '/api/blocked-times/' && request.method == 'POST') {
          value = {
            ...jsonDecode(request.body) as Map<String, dynamic>,
            'id': 1,
          };
        }
        return http.Response(
          jsonEncode(value),
          request.method == 'POST' ? 201 : 200,
        );
      }),
    );
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<DataService>(DataService(api, offline: offline));
    getIt.registerSingleton<AuthService>(_Staff(api));
    getIt.registerSingleton<GroomTimerService>(
      GroomTimerService(),
      dispose: (timer) => timer.dispose(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppColors.darkTheme() : AppColors.lightTheme(),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'breed opens the reference sheet and next booking opens this dog\'s visits',
    (tester) async {
      await pump(tester, const DogProfileScreen(dogId: 1));
      await tester.tap(find.text('Cocker Spaniel'));
      await tester.pumpAndSettle();
      expect(log.any((r) => r.url.path == '/api/breeds/5/'), isTrue);
      expect(find.text('Feathered'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Next booking'));
      await tester.tap(find.text('Next booking'));
      await tester.pumpAndSettle();
      expect(find.text('Bunny — bookings'), findsOneWidget);
      expect(find.text('Nothing booked'), findsOneWidget);
      expect(
        log
            .where((r) => r.url.path == '/api/appointments/')
            .every((r) => r.url.queryParameters['dog'] == '1'),
        isTrue,
      );
    },
  );

  testWidgets(
    'owner profile invoices and the linked invoice list use only that owner',
    (tester) async {
      await pump(tester, const ClientProfileScreen(clientId: 2));
      await tester.ensureVisible(find.text('INV-0003'));
      expect(find.text('INV-0003'), findsOneWidget);
      await tester.tap(find.text('VIEW / ADD'));
      await tester.pumpAndSettle();
      expect(
        log
            .where((r) => r.url.path == '/api/invoices/')
            .every((r) => r.url.queryParameters['client'] == '2'),
        isTrue,
      );
      expect(find.text('Alice Adams — invoices'), findsOneWidget);
    },
  );

  testWidgets(
    'walk-in timer saves without a dog and does not offer setting a default',
    (tester) async {
      await pump(
        tester,
        const GroomTimerScreen(dogId: -12, dogName: 'Brown spaniel'),
      );
      final timer = getIt<GroomTimerService>();
      expect(timer.sessionFor(-12), isNotNull);
      timer.setMinutes(-12, 'WASH', 15);
      expect(timer.sessionFor(-12)!.totalMinutes, 15);
      await tester.pumpAndSettle();
      expect(find.textContaining('SAVE & SET AS DEFAULT'), findsNothing);
      await tester.ensureVisible(find.text('SAVE WALK-IN FOR LATER'));
      await tester.tap(find.text('SAVE WALK-IN FOR LATER'));
      await tester.pumpAndSettle();
      expect(
        log.any((r) => r.method == 'POST'),
        isTrue,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '),
      );
      final request = log.singleWhere(
        (r) => r.method == 'POST' && r.url.path == '/api/groom-sessions/',
      );
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['dog'], isNull);
      expect(body['walk_in_name'], 'Brown spaniel');
      expect(body['timings'].single['duration_seconds'], 900);
      expect(body['client_reference'], isNotEmpty);
      expect(body['apply_to_dog'], isFalse);
      expect(body['complete_card'], isFalse);
      expect(timer.sessionFor(-12), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rejected offline groom opens an editable card and saves back to the queue', (tester) async {
    final offline = OfflineStore();
    await offline.activate('staff-test');
    final reference = newGroomReference();
    await offline.enqueue({
      'client_reference': reference, 'dog': 1, 'visit_type': 'GROOM',
      'started_at': '2026-10-13T09:00:00Z', 'notes': 'Keep this note',
    }, 'Bunny');
    await offline.reject(reference, 'Please review the groom card.');
    await pump(tester, const PendingGroomsScreen(), offline: offline);
    await tester.tap(find.text('EDIT GROOM CARD'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('SAVE RECORD'), 600,
      scrollable: find.byType(Scrollable).first, maxScrolls: 30);
    await tester.tap(find.text('SAVE RECORD'));
    await tester.pumpAndSettle();
    expect(find.text('Saved grooms'), findsOneWidget);
    expect(offline.pending.single['error'], isNull);
    expect(offline.pending.single['body']['notes'], 'Keep this note');
    expect(offline.pending.single['body']['client_reference'], reference);
    expect(log.every((r) => r.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'block category saves and is readable in ${dark ? 'dark' : 'light'} mode',
      (tester) async {
        await pump(
          tester,
          BlockedTimeFormScreen(initialStart: DateTime(2026, 10, 13, 12)),
          dark: dark,
        );
        await tester.tap(find.text('No category'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dog Care').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('BLOCK IT OUT'));
        await tester.tap(find.text('BLOCK IT OUT'));
        await tester.pumpAndSettle();
        final request = log.singleWhere((r) => r.method == 'POST');
        expect(jsonDecode(request.body)['category'], 'DOG_CARE');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'category inks clear text contrast in ${dark ? 'dark' : 'light'} mode',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppColors.darkTheme() : AppColors.lightTheme(),
            home: Builder(
              builder: (context) {
                final surface = Theme.of(context).colorScheme.surface;
                for (final category in blockCategoryLabels.keys) {
                  final ink = blockCategoryColour(context, category);
                  final background = Color.alphaBlend(
                    ink.withValues(alpha: 0.08),
                    surface,
                  );
                  final a = ink.computeLuminance();
                  final b = background.computeLuminance();
                  final contrast =
                      ((a > b ? a : b) + 0.05) / ((a < b ? a : b) + 0.05);
                  expect(contrast, greaterThanOrEqualTo(4.5), reason: category);
                }
                return const SizedBox();
              },
            ),
          ),
        );
      },
    );
  }
}
