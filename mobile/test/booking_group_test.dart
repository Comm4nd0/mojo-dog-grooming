/// A household booked in as one visit.
///
/// Jess grooms a family's dogs interleaved, so the visit has a length of its
/// own. On the axis that visit is **one band with every name on it** — but
/// only for the dogs that genuinely share its start and end. A dog she has
/// made a different length keeps its own block, because a diary that folds
/// a twenty-minute nail trim into a four-hour band is lying about the trim.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/widgets/calendar/appointment_block.dart';
import 'package:mojo_app/widgets/calendar/day_timeline.dart';
import 'package:mojo_app/widgets/calendar/timeline_layout.dart';
import 'package:mojo_app/widgets/calendar/timeline_metrics.dart';

Appointment _at(
  String start,
  int minutes, {
  required int id,
  String dog = 'Biscuit',
  int? group,
  List<String>? companions,
}) {
  final parts = start.split(':');
  final from = DateTime(2026, 8, 3, int.parse(parts[0]), int.parse(parts[1]));
  return Appointment(
    id: id,
    dogId: id,
    dogName: dog,
    clientId: 1,
    clientName: 'Bob Brown',
    clientPhone: '07700900002',
    startAt: from,
    endAt: from.add(Duration(minutes: minutes)),
    durationMinutes: minutes,
    bookingType: 'ADHOC',
    serviceType: ServiceType.groom,
    status: 'BOOKED',
    notes: '',
    groupId: group,
    groupDogNames: companions,
  );
}

void main() {
  final window = dayWindowFor(const []);

  test('the group fields come off the wire, and null means withheld', () {
    final staff = Appointment.fromJson({
      'id': 1, 'dog': 1, 'start_at': '2026-08-03T09:00:00Z', 'end_at': '2026-08-03T13:00:00Z',
      'group': 7, 'group_dog_names': ['Tank', 'Pip'],
    });
    expect(staff.groupId, 7);
    expect(staff.companionNames, ['Tank', 'Pip']);
    expect(staff.isSharedVisit, isTrue);

    // A client sees the group id and not the names — the key is dropped.
    final client = Appointment.fromJson({
      'id': 1, 'dog': 1, 'start_at': '2026-08-03T09:00:00Z', 'end_at': '2026-08-03T13:00:00Z',
      'group': 7,
    });
    expect(client.groupDogNames, isNull);
    expect(client.companionNames, isEmpty);
    expect(client.isSharedVisit, isFalse);

    // Booked alone.
    final alone = Appointment.fromJson({
      'id': 1, 'dog': 1, 'start_at': '2026-08-03T09:00:00Z', 'end_at': '2026-08-03T13:00:00Z',
      'group': null, 'group_dog_names': [],
    });
    expect(alone.groupId, isNull);
    expect(alone.isSharedVisit, isFalse);
  });

  test('a visit with one shape is one block, led by the lowest id', () {
    final placed = layoutDay([
      _at('10:00', 240, id: 12, dog: 'Tank', group: 1),
      _at('10:00', 240, id: 11, dog: 'Rolo', group: 1),
      _at('10:00', 240, id: 13, dog: 'Pip', group: 1),
    ], window);
    expect(placed, hasLength(1));
    expect(placed.single.appointment.id, 11);
    expect(placed.single.companions.map((a) => a.dogName), ['Tank', 'Pip']);
    expect(placed.single.all.map((a) => a.dogName), ['Rolo', 'Tank', 'Pip']);
    // One lane — five dogs must not read as five-deep.
    expect(placed.single.columnCount, 1);
  });

  test('a member with its own shape keeps its own block', () {
    final placed = layoutDay([
      _at('10:00', 240, id: 11, dog: 'Rolo', group: 1),
      _at('10:00', 240, id: 12, dog: 'Tank', group: 1),
      _at('10:00', 20, id: 13, dog: 'Pip', group: 1),
    ], window);
    expect(placed, hasLength(2));
    final band = placed.firstWhere((p) => p.companions.isNotEmpty);
    final trim = placed.firstWhere((p) => p.companions.isEmpty);
    expect(band.all.map((a) => a.dogName), ['Rolo', 'Tank']);
    expect(trim.appointment.dogName, 'Pip');
    expect(trim.durationMinutes, 20);
    // They overlap, so they share a cluster and take two lanes.
    expect(band.columnCount, 2);
  });

  test('a household booked separately is spotted, and only when loose', () {
    final found = householdsBookedSeparately([
      _at('10:00', 120, id: 1, dog: 'Rolo'),
      _at('12:00', 60, id: 2, dog: 'Tank'),
      // Already in a visit: not offered again.
      _at('14:00', 60, id: 3, dog: 'Pip', group: 9, companions: const []),
      // A request is not booked yet.
      Appointment(
        id: 4, dogId: 4, dogName: 'Milo', clientId: 1, clientName: 'Bob Brown',
        clientPhone: '', startAt: DateTime(2026, 8, 3, 15), endAt: DateTime(2026, 8, 3, 16),
        durationMinutes: 60, bookingType: 'ADHOC', status: 'REQUESTED', notes: '',
      ),
    ]);
    expect(found, hasLength(1));
    expect(found.single.map((a) => a.dogName), ['Rolo', 'Tank']);

    // One dog alone is not a household booked separately.
    expect(householdsBookedSeparately([_at('10:00', 120, id: 1)]), isEmpty);

    // Two owners, one dog each: nothing to link.
    final other = Appointment(
      id: 5, dogId: 5, dogName: 'Biscuit', clientId: 2, clientName: 'Alice Adams',
      clientPhone: '', startAt: DateTime(2026, 8, 3, 10), endAt: DateTime(2026, 8, 3, 11),
      durationMinutes: 60, bookingType: 'ADHOC', status: 'BOOKED', notes: '',
    );
    expect(householdsBookedSeparately([_at('10:00', 120, id: 1), other]), isEmpty);
  });

  test('two visits and a stranger do not fold into each other', () {
    final placed = layoutDay([
      _at('10:00', 120, id: 1, dog: 'Rolo', group: 1),
      _at('10:00', 120, id: 2, dog: 'Tank', group: 1),
      _at('10:00', 120, id: 3, dog: 'Milo', group: 2),
      _at('10:00', 120, id: 4, dog: 'Biscuit'),
    ], window);
    expect(placed, hasLength(3));
    expect(placed.map((p) => p.all.length).toList()..sort(), [1, 1, 2]);
  });

  group('tapping a shared band', () {
    Future<void> pump(WidgetTester tester, Widget timeline) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox(height: 900, child: timeline))),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('asks which dog, with every dog on the band', (tester) async {
      final opened = <int>[];
      final asked = <List<String>>[];
      await pump(tester, DayTimeline(
        day: DateTime(2026, 8, 3),
        appointments: [
          _at('10:00', 120, id: 12, dog: 'Tank', group: 1),
          _at('10:00', 120, id: 11, dog: 'Rolo', group: 1),
        ],
        metrics: const TimelineMetrics(),
        onOpen: (a) => opened.add(a.id),
        onOpenVisit: (dogs) => asked.add([for (final a in dogs) a.dogName]),
        onCreateAt: (_) {},
        onMove: (_, _) {},
      ));
      expect(find.byType(AppointmentBlock), findsOneWidget);
      await tester.tap(find.byType(AppointmentBlock));
      await tester.pumpAndSettle();
      expect(asked, [['Rolo', 'Tank']]);
      expect(opened, isEmpty);
    });

    testWidgets('a dog booked alone opens straight away', (tester) async {
      final opened = <int>[];
      final asked = <List<String>>[];
      await pump(tester, DayTimeline(
        day: DateTime(2026, 8, 3),
        appointments: [_at('10:00', 120, id: 11, dog: 'Rolo', group: 1)],
        metrics: const TimelineMetrics(),
        onOpen: (a) => opened.add(a.id),
        onOpenVisit: (dogs) => asked.add([for (final a in dogs) a.dogName]),
        onCreateAt: (_) {},
        onMove: (_, _) {},
      ));
      await tester.tap(find.byType(AppointmentBlock));
      await tester.pumpAndSettle();
      expect(opened, [11]);
      expect(asked, isEmpty);
    });
  });
}
