import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/services/groom_timer_service.dart';

/// The groom timer, which now has to survive things it used to die of.
///
/// Jess asked to be able to leave the screen mid-clip to read a dog's notes.
/// Every count used to live in the screen's State, so backing out threw the
/// groom away without a word. These cover the two things that replaced it:
/// state that outlives the view, and a session that outlives the process.
///
/// Elapsed time is never asserted by waiting — it comes from wall-clock
/// stamps, so a restore with a stamp hours in the past exercises the same
/// arithmetic in a millisecond.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> stored;

  /// Stands in for the Keychain / EncryptedSharedPreferences.
  void installStorage() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final arguments = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'read':
          return stored[arguments['key']];
        case 'write':
          stored[arguments['key'] as String] = arguments['value'] as String;
          return null;
        case 'delete':
          stored.remove(arguments['key']);
          return null;
        case 'deleteAll':
          stored.clear();
          return null;
        case 'readAll':
          return stored;
        case 'containsKey':
          return stored.containsKey(arguments['key']);
      }
      return null;
    });
  }

  /// A stored session, as the service writes one.
  void storeSession({
    int dogId = 7,
    String dogName = 'Bunny',
    int? appointmentId,
    Map<String, int> elapsed = const {},
    List<String> manual = const [],
    String? runningPhase,
    DateTime? runningSince,
  }) {
    stored['mojo_groom_timer'] = jsonEncode({
      'dogId': dogId,
      'dogName': dogName,
      'appointmentId': appointmentId,
      'usualMinutes': 105,
      'elapsed': elapsed,
      'manual': manual,
      'runningPhase': runningPhase,
      'runningSince': runningSince?.toIso8601String(),
    });
  }

  setUp(() {
    stored = {};
    installStorage();
  });

  Future<GroomTimerService> service() async {
    final timer = GroomTimerService();
    // The constructor starts a restore; wait for a settled one rather than
    // racing it.
    await timer.restore();
    return timer;
  }

  group('Timing a groom', () {
    test('a phase typed in by hand is kept, and marked as such', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes('CLIP', 25);

      expect(timer.secondsFor('CLIP'), 25 * 60);
      expect(timer.wasEnteredManually('CLIP'), isTrue);
      expect(timer.totalMinutes, 25);

      final timings = timer.timingsNow;
      expect(timings, hasLength(1));
      expect(timings.single.phase, 'CLIP');
      expect(timings.single.enteredManually, isTrue);
    });

    test('a phase set back to zero drops out entirely', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes('CLIP', 25);
      timer.setMinutes('CLIP', 0);

      expect(timer.timingsNow, isEmpty);
      expect(timer.wasEnteredManually('CLIP'), isFalse);
    });

    test('re-opening the same dog keeps every count', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes('PREP', 10);

      // What happens when Jess goes off to read the notes and comes back.
      timer.openFor(dogId: 1, dogName: 'Teddy');
      expect(timer.secondsFor('PREP'), 10 * 60);
    });

    test('another dog is flagged rather than merged into this one', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes('PREP', 10);

      // The screen asks before doing anything with this.
      expect(timer.holdsAnotherDog(2), isTrue);
      expect(timer.holdsAnotherDog(1), isFalse);

      // And taking it over starts from nothing — Teddy's ten minutes must not
      // become part of Bunny's groom.
      timer.openFor(dogId: 2, dogName: 'Bunny');
      expect(timer.secondsFor('PREP'), 0);
      expect(timer.totalSeconds, 0);
    });

    test('an empty session is not one worth going back to', () async {
      final timer = await service();
      expect(timer.hasSession, isFalse);
      timer.openFor(dogId: 1, dogName: 'Teddy');
      // Opened but nothing timed: the shell bar has nothing to show.
      expect(timer.hasSession, isFalse);
      timer.toggle('PREP');
      expect(timer.hasSession, isTrue);
    });

    test('only one phase runs at a time', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.toggle('PREP');
      expect(timer.runningPhase, 'PREP');
      timer.toggle('CLIP');
      expect(timer.runningPhase, 'CLIP');
      timer.toggle('CLIP');
      expect(timer.runningPhase, isNull);
      expect(timer.isRunning, isFalse);
    });
  });

  group('Surviving the app closing', () {
    test('a session written up survives a restart', () async {
      final first = await service();
      first.openFor(dogId: 4, dogName: 'Bunny', usualMinutes: 105);
      first.setMinutes('STRIP', 40);

      final second = await service();
      expect(second.dogId, 4);
      expect(second.dogName, 'Bunny');
      expect(second.usualMinutes, 105);
      expect(second.secondsFor('STRIP'), 40 * 60);
      expect(second.wasEnteredManually('STRIP'), isTrue);
    });

    test('a phase left running carries on from when it started', () async {
      // Not from now — restarting the count at zero would lose the groom that
      // has actually happened, which is the whole thing this guards.
      storeSession(
        runningPhase: 'DRY',
        runningSince: DateTime.now().subtract(const Duration(minutes: 12)),
        elapsed: {'PREP': 300},
      );
      final timer = await service();

      expect(timer.runningPhase, 'DRY');
      expect(timer.secondsFor('DRY'), closeTo(12 * 60, 5));
      expect(timer.secondsFor('PREP'), 300);
    });

    test('a phase running implausibly long is flagged, never adjusted', () async {
      // An invented figure is indistinguishable from a measured one, so the
      // service says which phase looks wrong and leaves the number alone.
      storeSession(
        runningPhase: 'CLIP',
        runningSince: DateTime.now().subtract(const Duration(hours: 14)),
      );
      final timer = await service();

      expect(timer.leftRunningPhase, 'CLIP');
      expect(timer.secondsFor('CLIP'), closeTo(14 * 3600, 5));
    });

    test('a shorter run is not flagged', () async {
      storeSession(
        runningPhase: 'CLIP',
        runningSince: DateTime.now().subtract(const Duration(minutes: 40)),
      );
      final timer = await service();
      expect(timer.leftRunningPhase, isNull);
    });

    test('a running phase with no start stamp is dropped, not restarted', () async {
      // Half a record is no record: counting it from now would read as a
      // phase that had only just begun.
      storeSession(runningPhase: 'WASH', elapsed: {'WASH': 120});
      final timer = await service();

      expect(timer.isRunning, isFalse);
      expect(timer.secondsFor('WASH'), 120);
    });

    test('an unreadable blob is cleared rather than wedging the timer', () async {
      stored['mojo_groom_timer'] = 'not json';
      final timer = await service();

      expect(timer.dogId, isNull);
      expect(stored.containsKey('mojo_groom_timer'), isFalse);
    });

    test('clearing it takes it off the disk too', () async {
      final timer = await service();
      timer.openFor(dogId: 4, dogName: 'Bunny');
      timer.setMinutes('PREP', 5);
      expect(stored.containsKey('mojo_groom_timer'), isTrue);

      await timer.clear();
      expect(timer.dogId, isNull);
      expect(timer.hasSession, isFalse);
      expect(stored.containsKey('mojo_groom_timer'), isFalse);
    });

    test('a booking already resolved is not lost to a later blank', () async {
      final timer = await service();
      timer.openFor(dogId: 4, dogName: 'Bunny', appointmentId: 88);
      // Re-opening from the shell bar, which has no appointment to offer.
      timer.openFor(dogId: 4, dogName: 'Bunny');
      expect(timer.appointmentId, 88);
    });
  });
}
