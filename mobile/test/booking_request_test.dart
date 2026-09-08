import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
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
