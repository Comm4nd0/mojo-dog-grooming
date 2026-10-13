import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/screens/staff/invoices_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/service_locator.dart';

void main() {
  tearDown(getIt.reset);
  final writes = <http.Request>[];
  Future<void> pump(WidgetTester tester, {bool priced = true}) async {
    writes.clear();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient(baseUrl: 'https://test/api', httpClient: MockClient((request) async {
      if (request.method != 'GET') {
        writes.add(request);
        return http.Response('{}', 200);
      }
      return http.Response(jsonEncode({'results': [
        {'id': 2, 'full_name': 'Alice Adams', 'uid': 'MOJO-002'},
      ], 'next': null}), 200);
    }));
    getIt.registerSingleton<DataService>(DataService(api));
    final invoice = Invoice.fromJson({
      'id': 4, 'client': 2, 'client_name': 'Alice Adams', 'number': 'INV-0004',
      'status': 'DRAFT', 'auto_generated': true,
      'notes': priced ? 'Review before sending' : 'Price needed: Full groom — Bunny.',
      'lines': priced ? [
        {'appointment': 12, 'description': 'Full groom — Bunny', 'quantity': '2', 'unit_price': '50', 'line_total': '100'},
      ] : [],
    });
    await tester.pumpWidget(MaterialApp(theme: AppColors.lightTheme(),
      home: InvoiceFormScreen(invoice: invoice)));
    await tester.pumpAndSettle();
  }

  testWidgets('draft price edit keeps the booking, quantity and invoice notes', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Full groom — Bunny'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Price (£)'), '55');
    await tester.tap(find.text('SAVE LINE'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('SAVE DRAFT'));
    await tester.tap(find.text('SAVE DRAFT'));
    await tester.pumpAndSettle();
    expect(writes.single.method, 'PATCH');
    expect(writes.single.url.path, '/api/invoices/4/');
    final body = jsonDecode(writes.single.body) as Map<String, dynamic>;
    expect(body['lines'].single['appointment'], 12);
    expect(body['lines'].single['unit_price'], '55');
    expect(body['lines'].single['quantity'], '2');
    expect(body['notes'], 'Review before sending');
    expect(body.containsKey('status'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unpriced draft asks for a real price rather than inserting zero', (tester) async {
    await pump(tester, priced: false);
    await tester.tap(find.text('ADD'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Description'), 'Full groom');
    await tester.tap(find.widgetWithText(ElevatedButton, 'ADD'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a price, including 0 for a free groom.'), findsOneWidget);
    expect(writes, isEmpty);
    await tester.enterText(find.widgetWithText(TextFormField, 'Price (£)'), '45');
    await tester.tap(find.widgetWithText(ElevatedButton, 'ADD'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('SAVE DRAFT'));
    await tester.tap(find.text('SAVE DRAFT'));
    await tester.pumpAndSettle();
    expect(jsonDecode(writes.single.body)['lines'].single['unit_price'], '45');
    expect(jsonDecode(writes.single.body)['notes'], '');
    expect(tester.takeException(), isNull);
  });
}
