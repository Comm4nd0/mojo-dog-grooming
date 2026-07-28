import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/widgets/common.dart';
import 'package:mojo_app/widgets/dog_silhouette.dart';

/// Mutable holder so a StatefulBuilder harness can own the selection the way
/// ProblemAreaEditor does.
class _Selection {
  _Selection([Set<String>? initial]) : cells = initial ?? <String>{};
  Set<String> cells;
}

DogSummary _dog({
  int id = 1,
  String name = 'Biscuit',
  String clientFullName = 'Alice Adams',
  String clientPhone = '07700900001',
  String clientUid = 'MOJO-001',
  String? temperament,
}) {
  return DogSummary(
    id: id,
    name: name,
    clientId: 1,
    clientUid: clientUid,
    clientFirstName: clientFullName.split(' ').first,
    clientFullName: clientFullName,
    clientPhone: clientPhone,
    breedLabel: 'Cockapoo (small)',
    groomMinutes: 105,
    price: 50,
    scheduleWeeks: 6,
    isActive: true,
    temperament: temperament,
  );
}

void main() {
  group('Doguments search', () {
    test('matches on dog name, case-insensitively', () {
      expect(_dog().matchesSearch('biscuit'), isTrue);
      expect(_dog().matchesSearch('BISC'), isTrue);
      expect(_dog().matchesSearch('rolo'), isFalse);
    });

    test('matches on client name', () {
      expect(_dog().matchesSearch('adams'), isTrue);
      expect(_dog().matchesSearch('Alice'), isTrue);
    });

    test('matches on client UID', () {
      expect(_dog().matchesSearch('MOJO-001'), isTrue);
    });

    test('matches a phone number regardless of spacing', () {
      expect(_dog(clientPhone: '07700 900 001').matchesSearch('07700900001'), isTrue);
      expect(_dog(clientPhone: '07700900001').matchesSearch('07700 900 001'), isTrue);
    });

    test('an empty query matches everything', () {
      expect(_dog().matchesSearch(''), isTrue);
      expect(_dog().matchesSearch('   '), isTrue);
    });

    test('summary line carries the whole-profile figures', () {
      expect(_dog().summaryLine, 'Alice · MOJO-001 · 1h 45m · £50.00 · every 6w');
    });
  });

  group('Temperament chip', () {
    testWidgets('renders nothing when temperament is null', (tester) async {
      // Null means the server withheld it from a client login — the badge must
      // not appear at all, rather than defaulting to "Easy".
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TemperamentChip(temperament: null))),
      );
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('renders the label for staff', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TemperamentChip(temperament: 'FEISTY'))),
      );
      expect(find.text('Feisty'), findsOneWidget);
    });
  });

  group('Silhouette picker', () {
    // Size the harness to the artwork's own aspect so the picker fills it
    // exactly. Deriving the geometry from the constants keeps these tests
    // honest if the grid or the silhouette is ever swapped.
    const harnessWidth = 480.0;
    final harnessHeight = harnessWidth / kSilhouetteAspect;
    final cellWidth = harnessWidth / kGridColumns;
    final cellHeight = harnessHeight / kGridRows;

    Offset centreOf(int row, int col) => Offset(
          col * cellWidth + cellWidth / 2,
          row * cellHeight + cellHeight / 2,
        );

    /// Mirrors how ProblemAreaEditor drives the picker: it owns the selection
    /// and rebuilds on every change. A harness that merely captured the
    /// callback without rebuilding would not exercise the controlled-widget
    /// path the app actually uses.
    Widget harness(_Selection state, {bool readOnly = false}) {
      return MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: harnessWidth,
              height: harnessHeight,
              child: DogSilhouettePicker(
                selectedCells: state.cells,
                onChanged: (cells) => setState(() => state.cells = cells),
                readOnly: readOnly,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('tapping a cell selects it, tapping again clears it', (tester) async {
      final state = _Selection();
      await tester.pumpWidget(harness(state));

      await tester.tapAt(centreOf(3, 5));
      await tester.pump();
      expect(state.cells, {'r3c5'});

      await tester.tapAt(centreOf(3, 5));
      await tester.pump();
      expect(state.cells, isEmpty);
    });

    testWidgets('multiple cells can be selected', (tester) async {
      final state = _Selection();
      await tester.pumpWidget(harness(state));
      for (final (row, col) in [(2, 4), (2, 5), (3, 4)]) {
        await tester.tapAt(centreOf(row, col));
        await tester.pump();
      }
      expect(state.cells, {'r2c4', 'r2c5', 'r3c4'});
    });

    testWidgets('every cell in the grid is reachable', (tester) async {
      // Guards the corners: an off-by-one in the layout maths would leave the
      // last row or column untappable, and nobody would notice until an owner
      // tried to mark a paw or the tail tip.
      final state = _Selection();
      await tester.pumpWidget(harness(state));
      for (int row = 0; row < kGridRows; row++) {
        for (int col = 0; col < kGridColumns; col++) {
          await tester.tapAt(centreOf(row, col));
          await tester.pump();
        }
      }
      expect(state.cells.length, kGridRows * kGridColumns);
      expect(state.cells, contains('r0c0'));
      expect(state.cells, contains(cellRef(kGridRows - 1, kGridColumns - 1)));
    });

    testWidgets('dragging paints across cells', (tester) async {
      // Cells are ~26x25dp on a phone, well under the 44-48dp touch target
      // both platforms recommend, so marking an area has to work by dragging
      // rather than by a separate accurate tap per cell.
      final state = _Selection();
      await tester.pumpWidget(harness(state));

      final gesture = await tester.startGesture(centreOf(3, 4));
      for (int col = 5; col <= 7; col++) {
        await gesture.moveTo(centreOf(3, col));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();

      expect(state.cells, {'r3c4', 'r3c5', 'r3c6', 'r3c7'});
    });

    testWidgets('a fast drag does not drop cells between frames', (tester) async {
      // Several pointer moves can land in one frame. If the widget recomputed
      // from the parent's selection each time, every move but the last would
      // be computed from the same stale set and thrown away.
      final state = _Selection();
      await tester.pumpWidget(harness(state));

      final gesture = await tester.startGesture(centreOf(5, 1));
      for (int col = 2; col <= 9; col++) {
        await gesture.moveTo(centreOf(5, col)); // no pump: same frame
      }
      await gesture.up();
      await tester.pump();

      expect(state.cells, {
        'r5c1', 'r5c2', 'r5c3', 'r5c4', 'r5c5', 'r5c6', 'r5c7', 'r5c8', 'r5c9',
      });
    });

    testWidgets('a drag begun on a marked cell erases instead', (tester) async {
      final state = _Selection({'r2c3', 'r2c4', 'r2c5'});
      await tester.pumpWidget(harness(state));

      final gesture = await tester.startGesture(centreOf(2, 3));
      for (int col = 4; col <= 5; col++) {
        await gesture.moveTo(centreOf(2, col));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();

      expect(state.cells, isEmpty);
    });

    testWidgets('one drag never both paints and erases', (tester) async {
      // Mode is fixed by the first cell. Starting on an empty cell and
      // crossing a marked one must not rub the marked one out.
      final state = _Selection({'r4c6'});
      await tester.pumpWidget(harness(state));

      final gesture = await tester.startGesture(centreOf(4, 5));
      await gesture.moveTo(centreOf(4, 6));
      await tester.pump();
      await gesture.moveTo(centreOf(4, 7));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(state.cells, {'r4c5', 'r4c6', 'r4c7'});
    });

    testWidgets('dragging off the edge stops rather than smearing', (tester) async {
      final state = _Selection();
      await tester.pumpWidget(harness(state));

      final gesture = await tester.startGesture(centreOf(0, 0));
      await gesture.moveTo(const Offset(-50, -50));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(state.cells, {'r0c0'});
    });

    testWidgets('read-only mode ignores taps and drags', (tester) async {
      final state = _Selection();
      await tester.pumpWidget(harness(state, readOnly: true));

      await tester.tapAt(centreOf(4, 6));
      await tester.pump();
      expect(state.cells, isEmpty);

      final gesture = await tester.startGesture(centreOf(2, 2));
      await gesture.moveTo(centreOf(2, 4));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(state.cells, isEmpty);
    });

    testWidgets('the thumbnail keeps the artwork aspect', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: DogSilhouetteThumbnail(cells: ['r2c4'], size: 120)),
          ),
        ),
      );
      final box = tester.getSize(find.byType(DogSilhouetteThumbnail));
      expect(box.width, 120);
      expect(box.height, closeTo(120 / kSilhouetteAspect, 0.01));
    });

    test('cell references match the format the API validates', () {
      expect(cellRef(0, 0), 'r0c0');
      expect(cellRef(7, 11), 'r7c11');
      // Changing either would invalidate every problem area already stored and
      // desync this from ProblemArea.GRID_COLUMNS / GRID_ROWS on the server.
      expect(kGridColumns, 12);
      expect(kGridRows, 8);
    });

    test('the asset exists, is declared in pubspec, and matches the aspect constant', () {
      // The previous version of this test only compared a Dart constant to a
      // string literal, so it would happily pass with the asset deleted and
      // the pubspec entry removed — a check whose name promised more than it
      // did. These assertions read the real files.
      final asset = File('assets/dog_silhouette.svg');
      expect(asset.existsSync(), isTrue, reason: '$kSilhouetteAsset is missing');

      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec.contains('- $kSilhouetteAsset'),
        isTrue,
        reason: 'the asset is not listed under flutter/assets, so it will not '
            'be bundled and the picker renders an empty grid',
      );

      // kSilhouetteAspect is hand-transcribed from the artwork's viewBox.
      // Swapping in an SVG of a different shape without updating it would
      // stretch the dog, since the picker draws with BoxFit.fill.
      final viewBox = RegExp(r'viewBox="([\d.\s-]+)"')
          .firstMatch(asset.readAsStringSync())!
          .group(1)!
          .trim()
          .split(RegExp(r'[\s,]+'));
      final width = double.parse(viewBox[2]);
      final height = double.parse(viewBox[3]);
      expect(
        kSilhouetteAspect,
        closeTo(width / height, 0.001),
        reason: 'kSilhouetteAspect does not match the asset viewBox '
            '($width x $height); the artwork will be drawn distorted',
      );
    });

    test('the grid matches the dimensions the server validates against', () {
      // ProblemArea.GRID_COLUMNS / GRID_ROWS in api/models.py reject any cell
      // reference outside the grid. If the two drift, either the app sends
      // references the API rejects, or saved areas render in the wrong place.
      final models = File('../api/models.py').readAsStringSync();
      final columns = RegExp(r'GRID_COLUMNS\s*=\s*(\d+)').firstMatch(models)!.group(1);
      final rows = RegExp(r'GRID_ROWS\s*=\s*(\d+)').firstMatch(models)!.group(1);
      expect(int.parse(columns!), kGridColumns, reason: 'client/server grid columns differ');
      expect(int.parse(rows!), kGridRows, reason: 'client/server grid rows differ');
    });

    test('cells carry a description a screen reader can act on', () {
      expect(describeCell(0, 0), 'top of head, row 1 column 1');
      expect(describeCell(3, 6), 'upper body, row 4 column 7');
      expect(describeCell(2, 10), 'upper hindquarters, row 3 column 11');
      expect(describeCell(0, 10), 'top of tail, row 1 column 11');
      expect(describeCell(6, 3), 'front leg, row 7 column 4');
      expect(describeCell(7, 8), 'hind paw, row 8 column 9');

      // Every cell must produce a label that names a body part, not just a
      // grid position — otherwise the announcement is unusable.
      for (int row = 0; row < kGridRows; row++) {
        for (int col = 0; col < kGridColumns; col++) {
          final label = describeCell(row, col);
          expect(label, contains('row ${row + 1} column ${col + 1}'));
          expect(
            label.split(',').first.trim(),
            isNotEmpty,
            reason: 'cell r${row}c$col has no anatomical description',
          );
        }
      }
    });
  });

  group('Formatting', () {
    test('durations read naturally', () {
      expect(formatDuration(45), '45m');
      expect(formatDuration(60), '1h');
      expect(formatDuration(105), '1h 45m');
      expect(formatDuration(180), '3h');
    });

    test('money is in sterling', () {
      expect(formatMoney(50), '£50.00');
      expect(formatMoney(7.5), '£7.50');
    });
  });

  group('Staff-only fields', () {
    test('an absent field is null, not false', () {
      // A client login gets no 'chatty' key at all. Reading a missing key as
      // `false` would silently assert the owner is not chatty.
      final asClient = ClientRecord.fromJson({
        'id': 1, 'uid': 'MOJO-001', 'first_name': 'Alice', 'last_name': 'Adams',
        'full_name': 'Alice Adams', 'email': '', 'phone': '', 'address': '',
        'postcode': '', 'dog_count': 1, 'has_login': true,
      });
      expect(asClient.chatty, isNull);
      expect(asClient.leafletReceived, isNull);
      expect(asClient.notes, isNull);

      final asStaff = ClientRecord.fromJson({
        'id': 1, 'uid': 'MOJO-001', 'first_name': 'Alice', 'last_name': 'Adams',
        'full_name': 'Alice Adams', 'email': '', 'phone': '', 'address': '',
        'postcode': '', 'dog_count': 1, 'has_login': true,
        'chatty': false, 'leaflet_received': true, 'notes': 'Always late.',
      });
      expect(asStaff.chatty, isFalse);
      expect(asStaff.leafletReceived, isTrue);
      expect(asStaff.notes, 'Always late.');
    });

    test('a dog with no problem_areas key reports null, not an empty list', () {
      final asClient = Dog.fromJson({
        'id': 1, 'client': 1, 'name': 'Biscuit', 'breed_label': 'Cockapoo',
        'breed_other': '', 'sex': '', 'is_neutered': false,
        'groom_minutes_effective': 105, 'price_effective': '50.00',
        'schedule_weeks_effective': 6, 'pref_body': '', 'pref_feet': '',
        'pref_tail': '', 'pref_face': '', 'pref_ears': '', 'pref_skirt': '',
        'medical_notes': '', 'vet': '', 'general_notes': '', 'is_active': true,
      });
      expect(asClient.problemAreas, isNull);
      expect(asClient.temperament, isNull);
    });
  });

  group('Booking warnings', () {
    test('an empty warning list means the slot is unremarkable', () {
      expect(BookingCheck.fromJson({'warnings': []}).hasWarnings, isFalse);
    });

    test('warnings are parsed with their codes', () {
      final check = BookingCheck.fromJson({
        'warnings': [
          {'code': 'temperament_limit', 'message': 'That would be 2 feisty dogs.'},
          {'code': 'overlap', 'message': 'This overlaps Rolo at 10:00.'},
        ],
      });
      expect(check.hasWarnings, isTrue);
      expect(check.warnings.map((w) => w.code), ['temperament_limit', 'overlap']);
    });
  });

  group('Role routing', () {
    test('a client with no linked record is sent to the claim flow', () {
      final unlinked = CurrentUser.fromJson({
        'id': 2, 'username': 'dana', 'email': 'dana@example.com',
        'is_staff': false, 'client_id': null,
      });
      expect(unlinked.needsToClaimProfile, isTrue);

      final linked = CurrentUser.fromJson({
        'id': 2, 'username': 'dana', 'email': 'dana@example.com',
        'is_staff': false, 'client_id': 7,
      });
      expect(linked.needsToClaimProfile, isFalse);

      final staff = CurrentUser.fromJson({
        'id': 1, 'username': 'jess', 'email': 'jess@example.com',
        'is_staff': true, 'client_id': null,
      });
      expect(staff.needsToClaimProfile, isFalse);
    });
  });
}
