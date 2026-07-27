import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/widgets/common.dart';
import 'package:mojo_app/widgets/dog_silhouette.dart';

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
    Widget harness(Set<String> selected, ValueChanged<Set<String>> onChanged,
        {bool readOnly = false}) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 320,
            child: DogSilhouettePicker(
              selectedCells: selected,
              onChanged: onChanged,
              readOnly: readOnly,
            ),
          ),
        ),
      );
    }

    testWidgets('tapping a cell selects it, tapping again clears it', (tester) async {
      Set<String> selected = {};
      Future<void> rebuild() async {
        await tester.pumpWidget(harness(selected, (cells) => selected = cells));
      }

      await rebuild();
      // The grid is 12x8 over 480x320, so each cell is 40x40. Tap row 3, col 5.
      await tester.tapAt(const Offset(5 * 40 + 20, 3 * 40 + 20));
      expect(selected, {'r3c5'});

      await rebuild();
      await tester.tapAt(const Offset(5 * 40 + 20, 3 * 40 + 20));
      expect(selected, isEmpty);
    });

    testWidgets('multiple cells can be selected', (tester) async {
      Set<String> selected = {};
      for (final (row, col) in [(2, 4), (2, 5), (3, 4)]) {
        await tester.pumpWidget(harness(selected, (cells) => selected = cells));
        await tester.tapAt(Offset(col * 40 + 20, row * 40 + 20));
      }
      expect(selected, {'r2c4', 'r2c5', 'r3c4'});
    });

    testWidgets('read-only mode ignores taps', (tester) async {
      Set<String> selected = {};
      await tester.pumpWidget(
        harness(selected, (cells) => selected = cells, readOnly: true),
      );
      await tester.tapAt(const Offset(100, 100));
      expect(selected, isEmpty);
    });

    test('cell references match the format the API validates', () {
      expect(cellRef(0, 0), 'r0c0');
      expect(cellRef(7, 11), 'r7c11');
      expect(kGridColumns, 12);
      expect(kGridRows, 8);
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
