// Jess: "can we add a drop down of 'Per Groom' or 'Per Hour' please?"
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/screens/staff/dog_form_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/service_locator.dart';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  group('Dog price basis', () {
    test('an hourly rate is labelled as one and the groom price is separate', () {
      final dog = Dog.fromJson({
        'id': 1, 'name': 'Boycie', 'price': '30.00', 'price_basis': 'HOUR',
        'price_effective': '30.00', 'groom_price': '120.00',
        'groom_minutes_effective': 240,
      });
      expect(dog.isPricedPerHour, isTrue);
      expect(dog.priceLabel, '${formatMoney(30)} an hour');
      expect(dog.groomPrice, 120);
    });

    test('per hour on a blank price is not an hourly rate', () {
      // The breed default is a whole-groom price whatever the basis says.
      final dog = Dog.fromJson({
        'id': 1, 'name': 'Boycie', 'price': null, 'price_basis': 'HOUR',
        'price_effective': '80.00',
      });
      expect(dog.isPricedPerHour, isFalse);
      expect(dog.priceLabel, formatMoney(80));
      expect(dog.groomPrice, 80);
    });

    test('an older server with no basis reads as per groom', () {
      final dog = Dog.fromJson({'id': 1, 'name': 'Boycie', 'price': '55', 'price_effective': '55'});
      expect(dog.priceBasis, 'GROOM');
      expect(dog.groomPrice, 55);
      final row = DogSummary.fromJson({'id': 1, 'name': 'Boycie', 'price_effective': '55'});
      expect(row.isPricedPerHour, isFalse);
    });

    test('the Doguments row trusts the server on per hour', () {
      final row = DogSummary.fromJson({
        'id': 1, 'name': 'Boycie', 'price_effective': '30.00', 'price_per_hour': true,
      });
      expect(row.priceLabel, '${formatMoney(30)} an hour');
    });
  });

  group('dog form', () {
    tearDown(getIt.reset);
    final writes = <http.Request>[];

    Future<void> pump(WidgetTester tester, Map<String, dynamic> existing) async {
      writes.clear();
      tester.view.physicalSize = const Size(375, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = ApiClient(
        baseUrl: 'https://test/api',
        httpClient: MockClient((request) async {
          Object result = {'results': [], 'next': null};
          if (request.method == 'PATCH' || request.method == 'POST') {
            writes.add(request);
            result = {...jsonDecode(request.body) as Map<String, dynamic>, 'id': 7};
          }
          return http.Response(jsonEncode(result), 200);
        }),
      );
      getIt.registerSingleton<ApiClient>(api);
      getIt.registerSingleton<DataService>(DataService(api));
      await tester.pumpWidget(MaterialApp(
        theme: AppColors.lightTheme(),
        home: DogFormScreen(
          presetClientId: 1,
          dog: Dog.fromJson({'id': 7, 'client': 1, 'name': 'Boycie', ...existing}),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> chooseHourly(WidgetTester tester) async {
      final dropdown = find.byKey(const Key('price-basis'));
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Per hour').last);
      await tester.pumpAndSettle();
    }

    testWidgets('per hour is saved and the sum is shown', (tester) async {
      await pump(tester, {'groom_minutes': 240, 'groom_minutes_effective': 240});
      expect(find.text('Per groom'), findsOneWidget);
      await chooseHourly(tester);
      await tester.enterText(field('Price (£)'), '30');
      await tester.pumpAndSettle();
      expect(
        find.text('${formatMoney(30)} an hour × ${formatDuration(240)} = ${formatMoney(120)} a groom'),
        findsOneWidget,
      );
      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();
      final body = jsonDecode(writes.single.body) as Map<String, dynamic>;
      expect(body['price'], '30');
      expect(body['price_basis'], 'HOUR');
    });

    testWidgets('per hour with no rate says the breed price is per groom', (tester) async {
      await pump(tester, {});
      await chooseHourly(tester);
      expect(find.textContaining('Type an hourly rate'), findsOneWidget);
    });

    testWidgets('an existing hourly dog opens on per hour', (tester) async {
      await pump(tester, {'price': '30.00', 'price_basis': 'HOUR', 'price_effective': '30.00'});
      expect(find.text('Per hour'), findsOneWidget);
      expect(find.text('Per groom'), findsNothing);
    });
  });
}
