/// The arithmetic behind the time-axis diary.
///
/// Pure functions, so these run in milliseconds and assert the things a
/// screenshot cannot: that a 20-minute nail trim is still tappable, that two
/// overlapping grooms cascade rather than hide each other, and — the one that
/// bites every hand-rolled diary — that a booking which does not actually
/// overlap the first one goes back in lane 0 rather than inventing a third
/// lane and making the day look busier than it is.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/widgets/calendar/timeline_layout.dart';
import 'package:mojo_app/widgets/calendar/timeline_metrics.dart';

Appointment _at(String start, int minutes, {int id = 0, String dog = 'Biscuit'}) {
  final parts = start.split(':');
  final from = DateTime(2026, 8, 3, int.parse(parts[0]), int.parse(parts[1]));
  return Appointment(
    id: id,
    dogId: id,
    dogName: dog,
    clientId: 1,
    clientName: 'Alice Adams',
    clientPhone: '07700900001',
    startAt: from,
    endAt: from.add(Duration(minutes: minutes)),
    durationMinutes: minutes,
    bookingType: 'ADHOC',
    serviceType: ServiceType.groom,
    status: 'BOOKED',
    notes: '',
  );
}

void main() {
  const metrics = TimelineMetrics();
  // 07:00–19:00 by default, so 09:00 is 120 minutes in.
  final window = dayWindowFor(const []);

  group('Metrics', () {
    test('an hour is 72dp at scale 1', () {
      expect(metrics.yForMinutes(60), 72);
    });

    test('a block is as tall as its duration', () {
      expect(metrics.heightForDuration(105), 126);
    });

    test('a short visit is clamped so it stays tappable', () {
      // 20 minutes is 24dp, under the floor.
      expect(metrics.heightForDuration(20), TimelineMetrics.minBlockHeight);
      expect(metrics.heightForDuration(5), TimelineMetrics.minBlockHeight);
    });

    test('y and minutes round-trip', () {
      expect(metrics.minutesForY(metrics.yForMinutes(135)), 135);
    });

    test('snapping lands on five-minute detents', () {
      expect(TimelineMetrics.snap(0), 0);
      expect(TimelineMetrics.snap(2), 0);
      expect(TimelineMetrics.snap(3), 5);
      expect(TimelineMetrics.snap(97), 95);
      expect(TimelineMetrics.snap(-3), -5);
    });

    test('scale is clamped both ways', () {
      expect(metrics.withScale(99).scale, TimelineMetrics.maxScale);
      expect(metrics.withScale(0).scale, TimelineMetrics.minScale);
    });
  });

  group('Day window', () {
    test('an empty day still shows a working day', () {
      expect(window.startMinutes, 7 * 60);
      expect(window.endMinutes, 19 * 60);
    });

    test('it widens for a booking before opening', () {
      // Jess works outside her hours often enough that the check only warns —
      // a fixed window would clip a real booking off the top.
      final early = dayWindowFor([_at('06:15', 60)]);
      expect(early.startMinutes, 6 * 60);
    });

    test('it widens for a booking after closing', () {
      final late = dayWindowFor([_at('19:30', 90)]);
      expect(late.endMinutes, 21 * 60);
    });

    test('it never narrows below the default', () {
      final midday = dayWindowFor([_at('12:00', 30)]);
      expect(midday.startMinutes, 7 * 60);
      expect(midday.endMinutes, 19 * 60);
    });
  });

  group('Placing bookings', () {
    test('an empty day places nothing', () {
      expect(layoutDay(const [], window), isEmpty);
    });

    test('a single booking takes the full width', () {
      final placed = layoutDay([_at('09:00', 60, id: 1)], window);
      expect(placed.single.column, 0);
      expect(placed.single.columnCount, 1);
      expect(placed.single.width(300), 300);
    });

    test('the top is measured from the start of the window', () {
      final placed = layoutDay([_at('09:00', 60, id: 1)], window);
      expect(placed.single.startMinutes, 120);
      expect(placed.single.top(metrics), 144);
    });

    test('bookings that do not overlap both sit in lane 0', () {
      final placed = layoutDay(
        [_at('09:00', 60, id: 1), _at('11:00', 60, id: 2)],
        window,
      );
      expect(placed.map((p) => p.column), [0, 0]);
      expect(placed.map((p) => p.columnCount), [1, 1]);
    });

    test('two overlapping bookings cascade rather than hide each other', () {
      final placed = layoutDay(
        [_at('09:00', 60, id: 1), _at('09:30', 60, id: 2)],
        window,
      );
      expect(placed.map((p) => p.column), [0, 1]);
      expect(placed.every((p) => p.cascades), isTrue);
      // The earlier block's leading edge stays visible — that edge carries its
      // time and the dog's name, and is Jess's "still able to overlap a bit".
      expect(placed[1].left(300), TimelineMetrics.overlapInset);
      expect(placed[0].left(300), 0);
    });

    test('a third booking reuses the first lane once it is free', () {
      // The classic hand-rolled-diary bug. C does not overlap A, so it belongs
      // back in lane 0; a naive pass gives it lane 2 and makes the day look
      // three-deep when it is only ever two.
      final placed = layoutDay(
        [
          _at('09:00', 60, id: 1), // 09:00–10:00
          _at('09:30', 60, id: 2), // 09:30–10:30
          _at('10:15', 45, id: 3), // 10:15–11:00
        ],
        window,
      );
      expect(placed.map((p) => p.column), [0, 1, 0]);
      expect(placed.every((p) => p.columnCount == 2), isTrue);
    });

    test('four deep splits the width evenly instead of cascading', () {
      final placed = layoutDay(
        [
          _at('09:00', 120, id: 1),
          _at('09:10', 120, id: 2),
          _at('09:20', 120, id: 3),
          _at('09:30', 120, id: 4),
        ],
        window,
      );
      expect(placed.every((p) => p.columnCount == 4), isTrue);
      expect(placed.every((p) => !p.cascades), isTrue);
      expect(placed.first.width(400), 100);
      expect(placed.last.left(400), 300);
    });

    test('separate clusters are counted separately', () {
      // A busy morning must not make a quiet afternoon look narrow.
      final placed = layoutDay(
        [
          _at('09:00', 60, id: 1),
          _at('09:30', 60, id: 2),
          _at('15:00', 60, id: 3),
        ],
        window,
      );
      expect(placed[0].columnCount, 2);
      expect(placed[1].columnCount, 2);
      expect(placed[2].columnCount, 1);
    });

    test('an out-of-order list is still placed by time', () {
      final placed = layoutDay(
        [_at('11:00', 60, id: 2), _at('09:00', 60, id: 1)],
        window,
      );
      expect(placed.map((p) => p.appointment.id), [1, 2]);
    });

    test('a zero-length booking does not produce a negative height', () {
      final broken = _at('09:00', 0, id: 1);
      final placed = layoutDay([broken], window);
      expect(placed.single.durationMinutes, greaterThan(0));
      expect(placed.single.height(metrics), greaterThan(0));
    });

    test('a negative duration does not throw or paint upside down', () {
      final start = DateTime(2026, 8, 3, 10, 0);
      final backwards = Appointment(
        id: 1,
        dogId: 1,
        dogName: 'Rolo',
        clientId: 1,
        clientName: 'Bob Brown',
        clientPhone: '07700900002',
        startAt: start,
        endAt: start.subtract(const Duration(hours: 1)),
        durationMinutes: -60,
        bookingType: 'ADHOC',
        serviceType: ServiceType.groom,
        status: 'BOOKED',
        notes: '',
      );
      expect(() => layoutDay([backwards], window), returnsNormally);
      expect(layoutDay([backwards], window).single.height(metrics), greaterThan(0));
    });
  });
}
