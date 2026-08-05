import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/screens/staff/dog_profile_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/groom_timer_service.dart';
import 'package:mojo_app/services/service_locator.dart';

/// A staff login, without going near the keychain.
class _StaffAuth extends AuthService {
  _StaffAuth(super.api);
  @override
  bool get isStaff => true;
}

/// Exactly what `DogSerializer` emits for a staff request, generated from the
/// real serializer rather than hand-written so the shape cannot drift from the
/// server's by wishful thinking. A dog with nothing filled in on purpose: that
/// is the state a newly added dog is in, and the emptiest this screen renders.
const _dogJson = r'''
{"id":1,"client":1,
 "client_detail":{"id":1,"uid":"MOJO-001","first_name":"Hannah","last_name":"Reid",
  "full_name":"Hannah Reid","email":"h@example.com","phone":"07700900001","address":"",
  "postcode":"RG1 1AA","emergency_contact_name":"","emergency_contact_phone":"",
  "chatty":false,"leaflet_received":false,"notes":"","photo_consent":null,"consents":[],
  "dog_count":1,"has_login":false,
  "created_at":"2026-08-02T15:55:09.622729+01:00","updated_at":"2026-08-02T15:55:09.622729+01:00"},
 "name":"Biscuit","breed":1,"breed_other":"","breed_label":"Cockapoo (small)",
 "date_of_birth":null,"sex":"","is_neutered":null,"colour":"","microchip_number":"",
 "temperament":"CALM","temperament_display":"CALM","temperament_notes":"",
 "groom_minutes":null,"price":null,"schedule_weeks":null,
 "groom_minutes_effective":105,"price_effective":"50.00","schedule_weeks_effective":6,
 "pref_body":"","pref_feet":"","pref_tail":"","pref_face":"","pref_ears":"","pref_skirt":"",
 "default_services":[],"default_services_detail":[],
 "allergies":"","medications":"","medical_issues":"","vaccinations":"","medical_notes":"",
 "vet":"","last_vet_visit":"","owner_grooming":"","general_notes":"",
 "is_active":true,"problem_areas":[],
 "created_at":"2026-08-02T15:54:53.318178+01:00","updated_at":"2026-08-02T15:54:53.318178+01:00"}
''';

const _emptyPage = '{"count":0,"next":null,"previous":null,"results":[]}';

Future<void> _pumpProfile(WidgetTester tester) async {
  final mock = MockClient((request) async {
    const asJson = {'content-type': 'application/json'};
    if (request.url.path.endsWith('/dogs/1/')) {
      return http.Response(_dogJson, 200, headers: asJson);
    }
    if (request.url.path.contains('suggested_next_groom')) {
      return http.Response(
        jsonEncode({'due_date': null, 'basis': 'no completed grooms yet'}),
        200,
        headers: asJson,
      );
    }
    return http.Response(_emptyPage, 200, headers: asJson); // photos, docs, visits
  });

  // Tall enough for the whole profile to lay out. A ListView only builds what
  // is near the viewport, so on a stock 600pt surface the lower sections are
  // legitimately absent and asserting on them would be testing the fold.
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final api = ApiClient(baseUrl: 'http://test/api', httpClient: mock);
  getIt.registerSingleton<ApiClient>(api);
  getIt.registerSingleton<AuthService>(_StaffAuth(api));
  getIt.registerSingleton<DataService>(DataService(api));
  // The timer FAB reads this. Its constructor tries the keystore, which is
  // absent under test — the service swallows that and starts empty, which is
  // exactly the state this screen should render.
  getIt.registerSingleton<GroomTimerService>(GroomTimerService());

  await tester.pumpWidget(MaterialApp(
    theme: AppColors.lightTheme(),
    home: const DogProfileScreen(dogId: 1),
  ));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(getIt.reset);

  group('a dog profile', () {
    testWidgets('gives the body a real height', (tester) async {
      // The regression this file exists for. `_bookBar` used an `Align` with
      // no heightFactor. `Align` expands to its incoming constraints, and
      // Scaffold measures bottomNavigationBar against the full screen height,
      // so the bar grew to 600pt on a 600pt viewport and the body was laid out
      // at Size(800, 0) — every section still built, none of them ever
      // painted. Nothing threw, so only a measurement catches it.
      await _pumpProfile(tester);

      final body = tester.renderObject<RenderBox>(find.byType(ListView));
      expect(body.size.height, greaterThan(0),
          reason: 'the profile body was squeezed to nothing by the bottom bar');

      final bar = tester.renderObject<RenderBox>(
        find.ancestor(
          of: find.text('BOOK A GROOM'),
          matching: find.byType(SafeArea),
        ),
      );
      expect(bar.size.height, lessThan(200),
          reason: 'the book bar should be a bar, not the whole screen');
    });

    testWidgets('shows the dog, not just the book button', (tester) async {
      await _pumpProfile(tester);
      expect(tester.takeException(), isNull);

      for (final expected in ['Groom', 'Grooming preferences', 'Photos', 'Paperwork']) {
        expect(find.text(expected), findsOneWidget, reason: '"$expected" is missing');
      }
      expect(find.text('BOOK A GROOM'), findsOneWidget);
    });

    testWidgets('keeps the staff-only sections for a staff login', (tester) async {
      await _pumpProfile(tester);
      // Gated on `dog.temperament != null` rather than on the login — a client
      // gets null here because the serializer strips it.
      expect(find.text('Temperament'), findsOneWidget);
      expect(find.text('Visit records'), findsOneWidget);
    });
  });
}
