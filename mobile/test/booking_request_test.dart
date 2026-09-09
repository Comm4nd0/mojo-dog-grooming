import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/widgets/booking_request.dart';

/// Booking a client's request in at a time other than the one they asked for.
///
/// Jess: *"when a request for a booking comes I want to be able to change the
/// date and time if needed."* Before this the decision sheet booked at the
/// time asked or nothing, and the only route to a different time was the
/// edit form — where the status dropdown stayed on Requested unless she
/// moved it too, so the request came out with a new time and still not in
/// the diary.
void main() {
  final request = Appointment(
    id: 7,
    dogId: 3,
    dogName: 'Bunny',
    clientId: 2,
    clientName: 'Sam Field',
    clientPhone: '07700 900000',
    startAt: DateTime(2026, 9, 8, 9, 10),
    endAt: DateTime(2026, 9, 8, 10, 40),
    durationMinutes: 90,
    bookingType: 'ADHOC',
    status: 'REQUESTED',
    notes: 'Any time that week is fine',
  );

  group('a moved slot keeps its length', () {
    test('the end moves with the start', () {
      final at = DateTime(2026, 9, 10, 14, 0);
      expect(request.length, const Duration(minutes: 90));
      expect(request.endIfStartedAt(at), DateTime(2026, 9, 10, 15, 30));
    });

    test('and it is the booked length, not the server figure', () {
      // A slot Jess has adjusted by hand: duration_minutes says one thing,
      // the times say another. The times are what is in the diary.
      final adjusted = Appointment(
        id: 8,
        dogId: 3,
        dogName: 'Bunny',
        clientId: 2,
        clientName: 'Sam Field',
        clientPhone: '',
        startAt: DateTime(2026, 9, 8, 9, 0),
        endAt: DateTime(2026, 9, 8, 11, 0),
        durationMinutes: 90,
        bookingType: 'ADHOC',
        status: 'REQUESTED',
        notes: '',
      );
      expect(adjusted.endIfStartedAt(DateTime(2026, 9, 9, 13, 0)),
          DateTime(2026, 9, 9, 15, 0));
    });
  });

  group('the decision sheet', () {
    late List<RequestDecision?> outcomes;

    Future<void> openSheet(WidgetTester tester, Appointment appointment) async {
      outcomes = [];
      // An iPhone SE. A modal sheet gets 9/16 of the height, which is less
      // than six rows and a header — the sheet has to scroll, not overflow.
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppColors.lightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                outcomes.add(await showRequestDecisionSheet(context, appointment));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('offers a different time and says the length stays', (tester) async {
      await openSheet(tester, request);
      expect(find.text('Book it in'), findsOneWidget);
      expect(find.text('Book it in at a different time'), findsOneWidget);
      expect(find.textContaining('it stays 1h 30m'), findsOneWidget);
      expect(find.text('Turn it down'), findsOneWidget);
      expect(find.text('Open the booking'), findsOneWidget);
      expect(find.text('Ring Sam Field'), findsOneWidget);

      await tester.tap(find.text('Book it in at a different time'));
      await tester.pumpAndSettle();
      expect(outcomes, [RequestDecision.acceptElsewhen]);
    });

    testWidgets('books at the time asked from the first row', (tester) async {
      await openSheet(tester, request);
      await tester.tap(find.text('Book it in'));
      await tester.pumpAndSettle();
      expect(outcomes, [RequestDecision.accept]);
    });

    testWidgets('has no ring row without a number', (tester) async {
      await openSheet(
        tester,
        Appointment(
          id: 9,
          dogId: 3,
          dogName: 'Bunny',
          clientId: 2,
          clientName: 'Sam Field',
          clientPhone: '',
          startAt: request.startAt,
          endAt: request.endAt,
          durationMinutes: 90,
          bookingType: 'ADHOC',
          status: 'REQUESTED',
          notes: '',
        ),
      );
      expect(find.textContaining('Ring '), findsNothing);
    });

    testWidgets('names every dog of a household asked for together',
        (tester) async {
      // Jess: "usually people book all their dogs together for a groom".
      // A family's request is one request: the sheet says who is in it and
      // every answer applies to all of them, bar opening one dog's form.
      await openSheet(
        tester,
        Appointment(
          id: 21,
          dogId: 3,
          dogName: 'Rolo',
          clientId: 2,
          clientName: 'Bob Brown',
          clientPhone: '',
          startAt: request.startAt,
          endAt: request.endAt,
          durationMinutes: 90,
          bookingType: 'ADHOC',
          status: 'REQUESTED',
          notes: '',
          groupId: 7,
          groupDogNames: const ['Tank', 'Pip'],
        ),
      );
      expect(find.text('Rolo, Tank and Pip — requested by Bob Brown'), findsOneWidget);
      expect(find.textContaining('one visit, 3 dogs'), findsOneWidget);
      expect(find.text('Book them all in'), findsOneWidget);
      expect(find.text('Book them all in at a different time'), findsOneWidget);
      expect(find.text('Turn them all down'), findsOneWidget);
      expect(find.text("Open Rolo's booking"), findsOneWidget);
    });
  });

  group('a household asked for together', () {
    test('is named as one — "Rolo", "Rolo and Tank", "Rolo, Tank and Pip"', () {
      expect(joinNames(const []), '');
      expect(joinNames(const ['Rolo']), 'Rolo');
      expect(joinNames(const ['Rolo', 'Tank']), 'Rolo and Tank');
      expect(joinNames(const ['Rolo', 'Tank', 'Pip']), 'Rolo, Tank and Pip');
    });

    Appointment member(int id, String dog, {int? group, List<String>? companions,
        DateTime? end}) {
      return Appointment(
        id: id,
        dogId: id,
        dogName: dog,
        clientId: 2,
        clientName: 'Bob Brown',
        clientPhone: '',
        startAt: DateTime(2026, 9, 8, 9),
        endAt: end ?? DateTime(2026, 9, 8, 13),
        durationMinutes: 240,
        bookingType: 'ADHOC',
        status: 'REQUESTED',
        notes: '',
        groupId: group,
        groupDogNames: companions,
      );
    }

    test('is one row in the queue, led by the lowest id', () {
      final folded = foldVisits([
        member(12, 'Tank', group: 7, companions: const ['Rolo', 'Pip']),
        member(1, 'Bunny'),
        member(11, 'Rolo', group: 7, companions: const ['Tank', 'Pip']),
        member(13, 'Pip', group: 7, companions: const ['Rolo', 'Tank']),
        // Same visit, but Jess has since given this one its own length —
        // its own row, the same rule the diary draws by.
        member(14, 'Milo', group: 7, companions: const ['Rolo'],
            end: DateTime(2026, 9, 8, 9, 20)),
      ]);
      expect(folded.map((a) => a.dogName), ['Rolo', 'Bunny', 'Milo']);
      expect(folded.first.visitDogNames, 'Rolo, Tank and Pip');
    });

    test('is left alone when the companions are withheld', () {
      // A client login: the names are gated, so there is nothing to fold
      // into and every booking stays its own row.
      final rows = [
        member(11, 'Rolo', group: 7),
        member(12, 'Tank', group: 7),
      ];
      expect(foldVisits(rows), rows);
      expect(rows.first.visitDogNames, 'Rolo');
    });

    testWidgets('is booked in and turned down as one call to the visit',
        (tester) async {
      final calls = <(String, String, Map<String, dynamic>)>[];
      final api = ApiClient(
        baseUrl: 'https://example.test/api',
        httpClient: MockClient((request) async {
          const asJson = {'content-type': 'application/json'};
          final body = request.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(request.body) as Map<String, dynamic>;
          calls.add((request.method, request.url.path, body));
          if (request.url.path.endsWith('/booking-groups/7/') && request.method == 'GET') {
            return http.Response(jsonEncode({
              'id': 7,
              'appointments': [
                {'id': 11, 'dog': 3, 'dog_name': 'Rolo', 'status': 'REQUESTED',
                 'start_at': '2026-09-08T09:00:00Z', 'end_at': '2026-09-08T13:00:00Z',
                 'group': 7, 'group_dog_names': ['Tank']},
                {'id': 12, 'dog': 4, 'dog_name': 'Tank', 'status': 'REQUESTED',
                 'start_at': '2026-09-08T09:00:00Z', 'end_at': '2026-09-08T13:00:00Z',
                 'group': 7, 'group_dog_names': ['Rolo']},
              ],
            }), 200, headers: asJson);
          }
          if (request.url.path.endsWith('/appointments/check/')) {
            return http.Response(jsonEncode({'warnings': []}), 200, headers: asJson);
          }
          return http.Response(jsonEncode({'id': 7, 'appointments': [], 'warnings': []}),
              200, headers: asJson);
        }),
      );
      final data = DataService(api);
      final request = member(11, 'Rolo', group: 7, companions: const ['Tank']);
      final outcomes = <bool>[];

      await tester.pumpWidget(MaterialApp(
        theme: AppColors.lightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () async {
                    outcomes.add(await bookRequestIn(context, data, request,
                        at: DateTime.utc(2026, 9, 10, 14)));
                  },
                  child: const Text('book'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    outcomes.add(await turnRequestDown(context, data, request));
                  },
                  child: const Text('decline'),
                ),
              ],
            ),
          ),
        ),
      ));

      await tester.tap(find.text('book'));
      await tester.pumpAndSettle();
      expect(outcomes, [true]);
      // Every dog checked, with the visit left out of its own overlap
      // warning, then one PATCH to the group rather than one per dog.
      final checks = calls.where((c) => c.$2.endsWith('/appointments/check/')).toList();
      expect(checks.map((c) => c.$3['dog']), [3, 4]);
      expect(checks.map((c) => c.$3['exclude_group']), [7, 7]);
      final patches = calls.where((c) => c.$1 == 'PATCH').toList();
      expect(patches, hasLength(1));
      expect(patches.single.$2, endsWith('/booking-groups/7/'));
      expect(patches.single.$3['status'], 'BOOKED');
      expect(patches.single.$3['start_at'], '2026-09-10T14:00:00.000Z');
      expect(patches.single.$3.containsKey('end_at'), isFalse);
      expect(find.textContaining('Booked Rolo and Tank in for'), findsOneWidget);

      calls.clear();
      await tester.tap(find.text('decline'));
      await tester.pumpAndSettle();
      expect(find.text('Turn down Rolo and Tank?'), findsOneWidget);
      await tester.tap(find.text('TURN THEM DOWN'));
      await tester.pumpAndSettle();
      expect(outcomes, [true, true]);
      final declines = calls.where((c) => c.$1 == 'PATCH').toList();
      expect(declines, hasLength(1));
      expect(declines.single.$2, endsWith('/booking-groups/7/'));
      expect(declines.single.$3, {'status': 'CANCELLED'});
    });
  });

  group('pickDateAndTime', () {
    late List<DateTime?> outcomes;

    Future<void> openPicker(WidgetTester tester) async {
      outcomes = [];
      await tester.pumpWidget(MaterialApp(
        theme: AppColors.lightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                outcomes.add(await pickDateAndTime(
                  context,
                  initial: DateTime(2026, 9, 8, 9, 10),
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('cancelling the date asks for no time and returns null',
        (tester) async {
      await openPicker(tester);
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(outcomes, [null]);
    });

    testWidgets('accepting both gives the picked day at the picked time',
        (tester) async {
      await openPicker(tester);
      // Keep the date, change the time on the keypad: 10:30. The test app
      // has no locale set, so the picker is 12-hour and the AM half stays.
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.at(0), '10');
      await tester.enterText(fields.at(1), '30');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(outcomes, [DateTime(2026, 9, 8, 10, 30)]);
    });

    testWidgets('cancelling the time returns null even after a date',
        (tester) async {
      await openPicker(tester);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(outcomes, [null]);
    });
  });
}
