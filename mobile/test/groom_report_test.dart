import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/screens/staff/dog_profile_screen.dart';
import 'package:mojo_app/screens/staff/visit_record_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/groom_timer_service.dart';
import 'package:mojo_app/services/service_locator.dart';

/// A client login, without going near the keychain.
class _ClientAuth extends AuthService {
  _ClientAuth(super.api);
  @override
  bool get isStaff => false;
}

const _emptyPage = '{"count":0,"next":null,"previous":null,"results":[]}';

void main() {
  group('the groom report model', () {
    test('a missing checklist key is "not recorded", never "not done"', () {
      // The rule the whole card runs on: null is not false. A report parsed
      // off an older server, or a card written before the checklist existed,
      // must not tell an owner their dog's nails were skipped.
      final report = GroomReport.fromJson({
        'id': 1,
        'dog': 2,
        'dog_name': 'Biscuit',
        'started_at': '2026-08-20T10:00:00+01:00',
      });
      for (final item in report.checklist) {
        expect(item.done, isNull, reason: item.label);
      }
      expect(report.hasChecklist, isFalse);
      expect(report.checklistSkipped, isEmpty);
    });

    test('only an explicit false counts as skipped', () {
      final report = GroomReport.fromJson({
        'id': 1,
        'dog': 2,
        'dog_name': 'Biscuit',
        'started_at': '2026-08-20T10:00:00+01:00',
        'nails_done': true,
        'hygiene_area_done': false,
      });
      expect(report.checklistSkipped, ['hygiene area']);
    });

    test("the checklist reads in Jess's order", () {
      final labels = GroomReport.fromJson({
        'id': 1,
        'dog': 2,
        'dog_name': 'Biscuit',
        'started_at': '2026-08-20T10:00:00+01:00',
      }).checklist.map((item) => item.label).toList();
      expect(labels, [
        'Health check',
        'Nails clipped',
        'Ears cleaned',
        'Hygiene area',
        'Feet clipped out',
        'Bathed',
        'Blow dried',
        'Usual groom carried out',
      ]);
    });

    test('the staff card and the owner report agree on the list', () {
      // Both build through the one helper, so this failing would mean the
      // helper grew a fork — but it is the property the report depends on.
      final session = GroomSession(
        id: 1,
        dogId: 2,
        dogName: 'Biscuit',
        startedAt: DateTime(2026, 8, 20),
        timings: const [],
        totalMinutes: 0,
        bathed: false,
      );
      final report = GroomReport(
        id: 1,
        dogId: 2,
        dogName: 'Biscuit',
        startedAt: DateTime(2026, 8, 20),
        bathed: false,
      );
      expect(
        session.checklist.map((item) => item.label),
        report.checklist.map((item) => item.label),
      );
      expect(session.checklistSkipped, report.checklistSkipped);
    });
  });

  group('the unified visit card', () {
    tearDown(getIt.reset);

    Future<void> pumpCard(WidgetTester tester, {String? visitType}) async {
      final mock = MockClient((request) async {
        const asJson = {'content-type': 'application/json'};
        if (request.url.path.endsWith('/equipment/')) {
          return http.Response(
            jsonEncode({
              'count': 2,
              'results': [
                {'id': 1, 'name': 'Clippers', 'uid': 'EQ-1', 'is_active': true},
                {'id': 2, 'name': 'Slicker brush', 'uid': 'EQ-2', 'is_active': true},
              ],
            }),
            200,
            headers: asJson,
          );
        }
        return http.Response(_emptyPage, 200, headers: asJson);
      });
      final api = ApiClient(baseUrl: 'http://test/api', httpClient: mock);
      getIt.registerSingleton<ApiClient>(api);
      getIt.registerSingleton<DataService>(DataService(api));

      tester.view.physicalSize = const Size(800, 4200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: AppColors.lightTheme(),
        home: VisitRecordScreen(
          dogId: 1,
          dogName: 'Biscuit',
          visitType: visitType,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the whole card whatever the visit was for', (tester) async {
      // Jess: "I don't think it needs to be a separate thing for
      // nails/fleas/ticks really". The card no longer forks on the type.
      await pumpCard(tester, visitType: VisitType.nailsFleasTicks);
      for (final section in [
        'Checklist', 'Fleas and ticks', 'Matting found',
        'Bathing and drying', 'How it was left',
      ]) {
        expect(find.text(section), findsOneWidget, reason: '"$section" is missing');
      }
      // All eight of Jess's items, in her order.
      for (final label in [
        'Health check', 'Nails clipped', 'Ears cleaned', 'Hygiene area',
        'Feet clipped out', 'Bathed', 'Blow dried', 'Usual groom carried out',
      ]) {
        expect(
          find.widgetWithText(CheckboxListTile, label),
          findsOneWidget,
          reason: '"$label" is missing from the checklist',
        );
      }
    });

    testWidgets('refuses to save until it knows what kind of visit this was',
        (tester) async {
      // A null visitType is the profile's ADD VISIT. Guessing "groom" here
      // would feed a twenty-minute nail trim into the groom-time average.
      await pumpCard(tester, visitType: null);
      await tester.tap(find.text('SAVE RECORD'));
      await tester.pump();
      expect(find.text('Say what kind of visit this was.'), findsOneWidget);
    });

    testWidgets('an answer about the bath means a bath happened', (tester) async {
      // The answer is typed now — Jess: "not quite as simple as yes or no
      // well behaved" — but the entailment is the same one the dropdown
      // carried: writing anything about the bath ticks Bathed.
      await pumpCard(tester, visitType: VisitType.groom);
      expect(find.text('Done'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Bathing'),
        'Good as gold once the water ran',
      );
      await tester.pumpAndSettle();

      // The Bathed tile ticked itself — the same entailment the server
      // applies, shown before the save instead of after it.
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('equipment is one field that opens into the list', (tester) async {
      // Jess: "Can the equipment selection be a drop down menu? Just takes up
      // a bit of space when filling out the groom card."
      await pumpCard(tester, visitType: VisitType.groom);
      expect(find.text('Equipment used'), findsOneWidget);
      // No chip wall on the card itself.
      expect(find.widgetWithText(FilterChip, 'Clippers'), findsNothing);

      await tester.tap(find.text('Equipment used'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Clippers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DONE'));
      await tester.pumpAndSettle();

      // The field now names what was picked.
      expect(find.text('Clippers'), findsOneWidget);
    });
  });

  group('an owner reading a dog profile', () {
    tearDown(getIt.reset);

    testWidgets('sees the groom reports and none of the staff card', (tester) async {
      final mock = MockClient((request) async {
        const asJson = {'content-type': 'application/json'};
        if (request.url.path.endsWith('/dogs/1/')) {
          // Client-shaped: the staff-only fields are absent, exactly as
          // StaffOnlyFieldsMixin strips them.
          return http.Response(
            jsonEncode({
              'id': 1,
              'name': 'Biscuit',
              'breed_label': 'Cockapoo (small)',
              'is_active': true,
              'problem_areas': [],
            }),
            200,
            headers: asJson,
          );
        }
        if (request.url.path.endsWith('/groom-reports/')) {
          return http.Response(
            jsonEncode({
              'count': 1,
              'results': [
                {
                  'id': 9,
                  'dog': 1,
                  'dog_name': 'Biscuit',
                  'visit_type': 'GROOM',
                  'visit_type_display': 'Groom',
                  'started_at': '2026-08-20T10:00:00+01:00',
                  'health_check_done': true,
                  'nails_done': true,
                  'hygiene_area_done': false,
                  'checklist_notes': 'Too wriggly for the hygiene area today.',
                  'temperament_display': 'Feisty',
                  'notes': 'Lovely once the dryer was off.',
                },
              ],
            }),
            200,
            headers: asJson,
          );
        }
        return http.Response(_emptyPage, 200, headers: asJson);
      });

      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = ApiClient(baseUrl: 'http://test/api', httpClient: mock);
      getIt.registerSingleton<ApiClient>(api);
      getIt.registerSingleton<AuthService>(_ClientAuth(api));
      getIt.registerSingleton<DataService>(DataService(api));
      getIt.registerSingleton<GroomTimerService>(GroomTimerService());

      await tester.pumpWidget(MaterialApp(
        theme: AppColors.lightTheme(),
        home: const DogProfileScreen(dogId: 1),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Groom reports'), findsOneWidget);
      // The line an owner acts on: what was deliberately left, not nulls.
      expect(find.textContaining('not done: hygiene area'), findsOneWidget);
      // Jess's side of the record stays hers.
      expect(find.text('Visit records'), findsNothing);
      expect(find.text('+ ADD VISIT'), findsNothing);
    });
  });
}
