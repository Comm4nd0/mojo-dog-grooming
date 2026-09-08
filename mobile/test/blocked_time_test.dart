/// Blocked-out time: the model, its place on the axis, and who sees what.
///
/// Two rules carry it. For Jess a block is a hatched band that warns; for a
/// client it is the one refusal in the booking flow. The tests here pin the
/// half the app owns — the notes are *withheld* rather than empty for a
/// client, a block that runs across midnight still paints the whole of the
/// next day, and the band is drawn under the bookings, not in a lane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/widgets/calendar/appointment_block.dart';
import 'package:mojo_app/widgets/calendar/blocked_band.dart';
import 'package:mojo_app/widgets/calendar/day_timeline.dart';
import 'package:mojo_app/widgets/calendar/timeline_layout.dart';
import 'package:mojo_app/widgets/calendar/timeline_metrics.dart';

BlockedTime _block(DateTime start, DateTime end, {int id = 1, String? notes}) =>
    BlockedTime(id: id, startAt: start, endAt: end, notes: notes);

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

void main() {
  final monday = DateTime(2026, 8, 3);

  group('the model', () {
    test('a client login has the notes withheld, not blank', () {
      // No `notes` key at all is what a client gets — the serializer drops
      // the field. That is null: "the server did not say", never "no note".
      final withheld = BlockedTime.fromJson({
        'id': 1,
        'start_at': '2026-08-03T11:00:00Z',
        'end_at': '2026-08-03T12:00:00Z',
      });
      expect(withheld.notes, isNull);
      expect(withheld.headline, '');

      final blank = BlockedTime.fromJson({
        'id': 1,
        'start_at': '2026-08-03T11:00:00Z',
        'end_at': '2026-08-03T12:00:00Z',
        'notes': '',
      });
      expect(blank.notes, '');

      final noted = BlockedTime.fromJson({
        'id': 1,
        'start_at': '2026-08-03T11:00:00Z',
        'end_at': '2026-08-03T12:00:00Z',
        'notes': 'Vet with Mojo\nBack by two',
      });
      expect(noted.headline, 'Vet with Mojo');
    });

    test('covers is half-open, like the server', () {
      final lunch = _block(monday.add(const Duration(hours: 12)), monday.add(const Duration(hours: 13)));
      expect(lunch.covers(monday.add(const Duration(hours: 12))), isTrue);
      expect(lunch.covers(monday.add(const Duration(hours: 12, minutes: 59))), isTrue);
      expect(lunch.covers(monday.add(const Duration(hours: 13))), isFalse);
      expect(lunch.covers(monday.add(const Duration(hours: 11, minutes: 59))), isFalse);
    });

    test('minutesOn clips a multi-day block to each day it touches', () {
      // Friday 15:00 to Monday 09:00.
      final friday = DateTime(2026, 8, 7, 15);
      final nextMonday = DateTime(2026, 8, 10, 9);
      final weekend = _block(friday, nextMonday);

      expect(weekend.minutesOn(DateTime(2026, 8, 7)), (15 * 60, 24 * 60));
      expect(weekend.minutesOn(DateTime(2026, 8, 8)), (0, 24 * 60));
      expect(weekend.minutesOn(DateTime(2026, 8, 9)), (0, 24 * 60));
      expect(weekend.minutesOn(DateTime(2026, 8, 10)), (0, 9 * 60));
      expect(weekend.minutesOn(DateTime(2026, 8, 11)), isNull);
      expect(weekend.minutesOn(DateTime(2026, 8, 6)), isNull);
    });

    test('a block ending exactly at midnight is not on the next day', () {
      final evening = _block(DateTime(2026, 8, 3, 18), DateTime(2026, 8, 4));
      expect(evening.minutesOn(DateTime(2026, 8, 3)), (18 * 60, 24 * 60));
      expect(evening.coversDay(DateTime(2026, 8, 4)), isFalse);
      expect(evening.minutesOn(DateTime(2026, 8, 4)), isNull);
    });
  });

  group('on the axis', () {
    const metrics = TimelineMetrics();

    test('the window stretches to cover a block, the same as a booking', () {
      // 06:00 is before the default 07:00 top; 20:30 is past the 19:00 foot.
      final window = dayWindowFor(const [], spans: const [(6 * 60, 6 * 60 + 30), (20 * 60, 20 * 60 + 30)]);
      expect(window.startMinutes, 6 * 60);
      expect(window.endMinutes, 21 * 60);
    });

    test('a block is placed relative to the window and clipped to it', () {
      final window = dayWindowFor(const []);
      final lunch = _block(monday.add(const Duration(hours: 12)), monday.add(const Duration(hours: 13)));
      final placed = layoutBlocks([lunch], monday, window);
      expect(placed, hasLength(1));
      expect(placed.single.startMinutes, 5 * 60); // 12:00 in a window from 07:00
      expect(placed.single.durationMinutes, 60);
      expect(placed.single.top(metrics), 5 * 60 * TimelineMetrics.baseMinuteHeight);

      // Touches a different day only: nothing to place.
      expect(layoutBlocks([lunch], monday.add(const Duration(days: 1)), window), isEmpty);
    });
  });

  group('in the day view', () {
    Future<void> pumpTimeline(WidgetTester tester, Widget timeline) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox(height: 900, child: timeline))),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a block draws as a band, and tapping it opens the block', (tester) async {
      final opened = <int>[];
      final created = <DateTime>[];
      final lunch = _block(
        monday.add(const Duration(hours: 12)),
        monday.add(const Duration(hours: 13)),
        notes: 'Vet with Mojo',
      );

      await pumpTimeline(tester, DayTimeline(
        day: monday,
        appointments: const [],
        blocks: [lunch],
        onOpenBlock: (block) => opened.add(block.id),
        metrics: const TimelineMetrics(),
        onOpen: (_) {},
        onCreateAt: created.add,
        onMove: (_, _) {},
      ));

      expect(find.byType(BlockedBand), findsOneWidget);
      expect(find.textContaining('Blocked'), findsOneWidget);
      expect(find.textContaining('Vet with Mojo'), findsOneWidget);

      // Tapping the band opens the block — it must not fall through to the
      // tap-to-create layer underneath and start a booking on top of it.
      await tester.tap(find.byType(BlockedBand));
      await tester.pumpAndSettle();
      expect(opened, [1]);
      expect(created, isEmpty);
    });

    testWidgets('a booking on top of a block stays on top', (tester) async {
      final openedAppointments = <int>[];
      final openedBlocks = <int>[];
      final lunch = _block(monday.add(const Duration(hours: 12)), monday.add(const Duration(hours: 13)));
      final booked = _appointment(start: monday.add(const Duration(hours: 12)));

      await pumpTimeline(tester, DayTimeline(
        day: monday,
        appointments: [booked],
        blocks: [lunch],
        onOpenBlock: (block) => openedBlocks.add(block.id),
        metrics: const TimelineMetrics(),
        onOpen: (appointment) => openedAppointments.add(appointment.id),
        onCreateAt: (_) {},
        onMove: (_, _) {},
      ));

      // Jess booked over her own lunch — a warning, never a refusal — and
      // the booking is what she needs to reach.
      await tester.tap(find.byType(AppointmentBlock));
      await tester.pumpAndSettle();
      expect(openedAppointments, [1]);
      expect(openedBlocks, isEmpty);
    });

    testWidgets('a client-shaped block with no notes still labels itself', (tester) async {
      final lunch = _block(monday.add(const Duration(hours: 12)), monday.add(const Duration(hours: 13)));
      await pumpTimeline(tester, DayTimeline(
        day: monday,
        appointments: const [],
        blocks: [lunch],
        metrics: const TimelineMetrics(),
        onOpen: (_) {},
        onCreateAt: (_) {},
        onMove: (_, _) {},
      ));
      expect(find.text('Blocked'), findsOneWidget);
    });
  });
}
