/// Dragging a booking to a new time.
///
/// Jess asked to be able to "hold to 'slide' a blocked out groom up and down",
/// and the hard rule of this codebase is that a warning never blocks. The two
/// meet on drop: the server is asked what it thinks, and whatever it says the
/// affirmative button is there and enabled.
///
/// The affirmative-button test is the one that matters. Every rule in
/// `scheduling.py` warns and none of them refuse; a future edit that disabled
/// this button on a clash would look like a sensible guard and would quietly
/// break the promise the whole booking flow rests on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/widgets/calendar/appointment_block.dart';
import 'package:mojo_app/widgets/calendar/day_timeline.dart';
import 'package:mojo_app/widgets/calendar/timeline_metrics.dart';
import 'package:mojo_app/widgets/common.dart';

Appointment _appointment({int id = 1, required DateTime start, int minutes = 60}) {
  return Appointment(
    id: id,
    dogId: 7,
    dogName: 'Biscuit',
    clientId: 1,
    clientName: 'Alice Adams',
    clientPhone: '07700900001',
    startAt: start,
    endAt: start.add(Duration(minutes: minutes)),
    durationMinutes: minutes,
    bookingType: 'ADHOC',
    serviceType: ServiceType.groom,
    status: 'BOOKED',
    notes: '',
  );
}

BookingCheck _check(List<String> codes) => BookingCheck(
      warnings: [
        for (final code in codes)
          BookingWarning(code: code, message: 'Something about $code'),
      ],
    );

void main() {
  final day = DateTime(2026, 8, 3, 0, 0);

  setUpAll(() {
    // Make a gesture that lands on nothing a failure rather than a warning.
    //
    // This file was green here and red on macOS for days, and the reason it
    // took so long to see is that "a slide that goes nowhere" *passed* on the
    // broken runner: it expects no callback, so a gesture swallowed by the
    // route-transition barrier gave exactly the right answer for entirely the
    // wrong reason. A test that cannot fail for the right reason hides the
    // ones that can.
    //
    // With this set, a pointer that misses its target stops the test where it
    // happens instead of leaving a warning in the log nobody reads.
    WidgetController.hitTestWarningShouldBeFatal = true;
  });

  testWidgets('long-pressing and sliding reports the new time', (tester) async {
    final moves = <(int, DateTime)>[];
    final appointment = _appointment(start: DateTime(2026, 8, 3, 10, 0));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayTimeline(
            day: day,
            appointments: [appointment],
            metrics: const TimelineMetrics(),
            onOpen: (_) {},
            onCreateAt: (_) {},
            onMove: (a, newStart) => moves.add((a.id, newStart)),
          ),
        ),
      ),
    );
    // Let the route transition finish before touching anything.
    //
    // MaterialApp animates its first route in, and while that runs an
    // AbsorbPointer over the Overlay swallows pointer events. Interacting
    // straight after pumpWidget is therefore a race: on this machine it
    // settled in time, on Xcode Cloud's macOS runners it did not, and the
    // gesture went to the barrier instead of the block. `flutter test` was
    // green here and red there for days.
    //
    // The tell was which test survived: "a slide that goes nowhere" expects
    // no callback, so a swallowed gesture passed it vacuously, while every
    // test that expected an action failed.
    await tester.pumpAndSettle();

    // 72dp is one hour at scale 1.0.
    // The block, not the text inside it: a block's geometry comes from
    // TimelineMetrics (72dp an hour, computed) while the Text's comes from
    // font metrics, which are not the same on every platform. Aiming at
    // the text made the gesture's landing point depend on how 'Biscuit'
    // happened to render.
    final block = find.byType(AppointmentBlock);
    final gesture = await tester.startGesture(tester.getCenter(block));
    await tester.pump(const Duration(milliseconds: 600)); // past the long press
    await gesture.moveBy(const Offset(0, 72));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moves, hasLength(1));
    expect(moves.single.$1, appointment.id);
    expect(moves.single.$2, DateTime(2026, 8, 3, 11, 0));
  });

  testWidgets('a slide that goes nowhere reports nothing', (tester) async {
    final moves = <DateTime>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayTimeline(
            day: day,
            appointments: [_appointment(start: DateTime(2026, 8, 3, 10, 0))],
            metrics: const TimelineMetrics(),
            onOpen: (_) {},
            onCreateAt: (_) {},
            onMove: (_, newStart) => moves.add(newStart),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(find.byType(AppointmentBlock)));
    await tester.pump(const Duration(milliseconds: 600));
    // Under half a snap increment, so it settles back where it started.
    await gesture.moveBy(const Offset(0, 2));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moves, isEmpty, reason: 'no PATCH for a move of nothing');
  });

  testWidgets('tapping a block opens it rather than moving it', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayTimeline(
            day: day,
            appointments: [_appointment(start: DateTime(2026, 8, 3, 10, 0))],
            metrics: const TimelineMetrics(),
            onOpen: (_) => opened++,
            onCreateAt: (_) {},
            onMove: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppointmentBlock));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('tapping empty space starts a booking at that time', (tester) async {
    final created = <DateTime>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayTimeline(
            day: day,
            appointments: const [],
            metrics: const TimelineMetrics(),
            onOpen: (_) {},
            onCreateAt: created.add,
            onMove: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The window opens at 07:00, so 144dp down is two hours in.
    final lane = tester.getTopLeft(find.byType(DayTimeline));
    await tester.tapAt(Offset(lane.dx + 200, lane.dy + 144));
    await tester.pumpAndSettle();

    expect(created, hasLength(1));
    expect(created.single.hour, 9);
    expect(created.single.minute % TimelineMetrics.snapMinutes, 0);
  });

  group('The move dialog', () {
    Future<bool?> showFor(WidgetTester tester, BookingCheck check) async {
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  answer = await showWarningsDialog(
                    context,
                    check,
                    title: 'Before you move it',
                    confirmLabel: 'MOVE ANYWAY',
                    cancelLabel: 'PUT IT BACK',
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('MOVE ANYWAY is always there and always enabled', (tester) async {
      // Every warning the server can produce, at once. None of them may take
      // the button away.
      await showFor(
        tester,
        _check([
          'overlap',
          'temperament_limit',
          'closure_day',
          'outside_opening_hours',
          'service_not_priced',
          'service_category_mismatch',
        ]),
      );

      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'MOVE ANYWAY'),
      );
      expect(button.onPressed, isNotNull, reason: 'warnings never block');
    });

    testWidgets('every warning is shown, not just the first', (tester) async {
      await showFor(tester, _check(['overlap', 'temperament_limit']));
      expect(find.textContaining('overlap'), findsOneWidget);
      expect(find.textContaining('temperament_limit'), findsOneWidget);
    });

    testWidgets('an unremarkable slot does not ask at all', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showWarningsDialog(context, _check(const [])),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('putting it back reports false', (tester) async {
      await showFor(tester, _check(['overlap']));
      await tester.tap(find.text('PUT IT BACK'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
