import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/screens/staff/visit_record_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/service_locator.dart';
import 'package:mojo_app/widgets/dog_silhouette.dart';

const _emptyPage = '{"count":0,"next":null,"previous":null,"results":[]}';

/// Jess: *"Is there an easy way to add what was found in the health check on
/// grooms to problem areas?"* — one button under the health check, opening
/// the problem-area editor with what she wrote already in the reason.
void main() {
  tearDown(getIt.reset);
  late List<Map<String, dynamic>> created;

  Future<void> pumpCard(WidgetTester tester, {int dogId = 1}) async {
    created = [];
    final api = ApiClient(
      baseUrl: 'http://test/api',
      httpClient: MockClient((request) async {
        const asJson = {'content-type': 'application/json'};
        if (request.method == 'POST' && request.url.path.endsWith('/problem-areas/')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          created.add(body);
          return http.Response(jsonEncode({...body, 'id': 9, 'source': 'STAFF'}), 201,
              headers: asJson);
        }
        return http.Response(_emptyPage, 200, headers: asJson);
      }),
    );
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<DataService>(DataService(api));
    tester.view.physicalSize = const Size(800, 4400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.lightTheme(),
      home: VisitRecordScreen(dogId: dogId, dogName: 'Zaba', visitType: 'GROOM'),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the health check notes become the problem area reason', (tester) async {
    await pumpCard(tester);
    final notes = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Anything found',
    );
    await tester.enterText(notes, 'Small cyst on the neck');
    await tester.tap(find.byKey(const Key('health-check-to-problem-area')));
    await tester.pumpAndSettle();

    expect(find.text('Problem area — Zaba'), findsOneWidget);
    expect(find.text('Small cyst on the neck'), findsOneWidget);

    // Mark one square on the dog and save.
    final picker = find.byType(DogSilhouettePicker);
    await tester.tapAt(tester.getCenter(picker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE AREA'));
    await tester.pumpAndSettle();

    expect(created, hasLength(1));
    expect(created.single['dog'], 1);
    expect(created.single['reason'], 'Small cyst on the neck');
    expect(created.single['grid_cells'], isNotEmpty);
    // Back on the card, which is unsaved and still open.
    expect(find.text("Added to Zaba's problem areas."), findsOneWidget);
    expect(find.text('Small cyst on the neck'), findsOneWidget);
  });

  testWidgets('a walk-in has no dog to mark, so no button', (tester) async {
    await pumpCard(tester, dogId: 0);
    expect(find.byKey(const Key('health-check-to-problem-area')), findsNothing);
  });
}
