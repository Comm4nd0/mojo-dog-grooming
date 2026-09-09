import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/screens/client/my_bookings_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/service_locator.dart';

/// A client asking for an appointment for more than one dog.
///
/// Jess: *"usually people book all their dogs together for a groom"*. The
/// request sheet offered a dropdown with one dog in it, so an owner with
/// three sent three requests — or, more likely, one, and rang about the
/// rest. Now the sheet offers every dog on the account and the ones ticked
/// go in as one visit.
void main() {
  const emptyPage = '{"count":0,"next":null,"previous":null,"results":[]}';

  late List<(String, String, Map<String, dynamic>)> calls;

  Future<void> pump(WidgetTester tester, {required List<String> dogs}) async {
    calls = [];
    final api = ApiClient(
      baseUrl: 'https://example.test/api',
      httpClient: MockClient((request) async {
        const asJson = {'content-type': 'application/json'};
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        calls.add((request.method, request.url.path, body));
        if (request.url.path.endsWith('/dogs/')) {
          return http.Response(jsonEncode({
            'count': dogs.length,
            'results': [
              for (var i = 0; i < dogs.length; i++) {'id': i + 1, 'name': dogs[i]},
            ],
          }), 200, headers: asJson);
        }
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': 1, 'appointments': [], 'start_at': '2026-09-16T10:00:00Z',
                'end_at': '2026-09-16T12:00:00Z'}),
            201,
            headers: asJson,
          );
        }
        return http.Response(emptyPage, 200, headers: asJson);
      }),
    );
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<DataService>(DataService(api));

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AppColors.lightTheme(),
      home: const MyBookingsScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('REQUEST'));
    await tester.pumpAndSettle();
  }

  tearDown(getIt.reset);

  testWidgets('with one dog there is nothing to choose', (tester) async {
    await pump(tester, dogs: ['Bunny']);
    expect(find.text('Bunny'), findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);
    expect(find.text('SEND REQUEST'), findsOneWidget);

    await tester.tap(find.text('SEND REQUEST'));
    await tester.pumpAndSettle();
    final posts = calls.where((c) => c.$1 == 'POST').toList();
    expect(posts, hasLength(1));
    expect(posts.single.$2, endsWith('/appointments/'));
    expect(posts.single.$3['dog'], 1);
  });

  testWidgets('with several dogs every one is offered and the ticked ones go '
      'in as one visit', (tester) async {
    await pump(tester, dogs: ['Rolo', 'Tank', 'Pip']);
    expect(find.byType(FilterChip), findsNWidgets(3));
    // The first is ticked to start with, as it was when this was a dropdown.
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Rolo')).selected, isTrue);
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Tank')).selected, isFalse);
    expect(find.text('SEND REQUEST'), findsOneWidget);

    await tester.tap(find.text('ALL OF THEM'));
    await tester.pumpAndSettle();
    expect(find.text('ALL OF THEM'), findsNothing);
    expect(find.text('SEND REQUEST FOR 3 DOGS'), findsOneWidget);

    // Untick one: the button counts what is left.
    await tester.tap(find.widgetWithText(FilterChip, 'Tank'));
    await tester.pumpAndSettle();
    expect(find.text('SEND REQUEST FOR 2 DOGS'), findsOneWidget);

    await tester.tap(find.text('SEND REQUEST FOR 2 DOGS'));
    await tester.pumpAndSettle();
    final posts = calls.where((c) => c.$1 == 'POST').toList();
    expect(posts, hasLength(1));
    expect(posts.single.$2, endsWith('/booking-groups/'));
    expect(posts.single.$3['bookings'], [
      {'dog': 1, 'services': []},
      {'dog': 3},
    ]);
    // No end: the length of a visit is Jess's to set.
    expect(posts.single.$3.containsKey('end_at'), isFalse);
    expect(find.textContaining('Request sent for Rolo and Pip'), findsOneWidget);
  });

  testWidgets('nothing ticked is nothing to send', (tester) async {
    await pump(tester, dogs: ['Rolo', 'Tank']);
    await tester.tap(find.widgetWithText(FilterChip, 'Rolo'));
    await tester.pumpAndSettle();
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'SEND REQUEST'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('one dog ticked of several is an ordinary request', (tester) async {
    await pump(tester, dogs: ['Rolo', 'Tank']);
    await tester.tap(find.text('SEND REQUEST'));
    await tester.pumpAndSettle();
    final posts = calls.where((c) => c.$1 == 'POST').toList();
    expect(posts, hasLength(1));
    expect(posts.single.$2, endsWith('/appointments/'));
    expect(posts.single.$3['dog'], 1);
  });
}
