import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/services/groom_timer_service.dart';

/// The groom timer, which now has to survive things it used to die of.
///
/// Jess asked to be able to leave the screen mid-clip to read a dog's notes.
/// Every count used to live in the screen's State, so backing out threw the
/// groom away without a word. Then she asked for the shared-visit workflow —
/// *"I will bath one and they can 'dry' in the crate for a bit and I will get
/// on with 'bathing' the other dog"* — so the service holds a session per dog
/// and two clocks genuinely run at once.
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

  /// A stored session **in the pre-multi-dog format** — one session's fields
  /// at the top level, exactly as the previous build wrote it. The phone
  /// updates with a groom on the clock, so this shape must keep restoring.
  void storeLegacySession({
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
      timer.setMinutes(1, 'CLIP', 25);

      final session = timer.sessionFor(1)!;
      expect(session.secondsFor('CLIP'), 25 * 60);
      expect(session.wasEnteredManually('CLIP'), isTrue);
      expect(session.totalMinutes, 25);

      final timings = timer.timingsNow(1);
      expect(timings, hasLength(1));
      expect(timings.single.phase, 'CLIP');
      expect(timings.single.enteredManually, isTrue);
    });

    test('a phase set back to zero drops out entirely', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes(1, 'CLIP', 25);
      timer.setMinutes(1, 'CLIP', 0);

      expect(timer.timingsNow(1), isEmpty);
      expect(timer.sessionFor(1)!.wasEnteredManually('CLIP'), isFalse);
    });

    test('re-opening the same dog keeps every count', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes(1, 'PREP', 10);

      // What happens when Jess goes off to read the notes and comes back.
      timer.openFor(dogId: 1, dogName: 'Teddy');
      expect(timer.sessionFor(1)!.secondsFor('PREP'), 10 * 60);
    });

    test('opening a second dog keeps the first, and never merges them', () async {
      // The shared visit: Teddy's time stays Teddy's while Bunny starts from
      // nothing beside it. The one thing this must never do is quietly add
      // one dog's clip time to the other's groom.
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes(1, 'PREP', 10);

      timer.openFor(dogId: 2, dogName: 'Bunny');
      expect(timer.sessionFor(1)!.secondsFor('PREP'), 10 * 60);
      expect(timer.sessionFor(2)!.secondsFor('PREP'), 0);
      expect(timer.sessionFor(2)!.totalSeconds, 0);
      expect(timer.liveSessions.map((s) => s.dogName), ['Teddy']);
    });

    test('two dogs can run a phase each at the same time', () async {
      // Jess: "I will bath one and they can 'dry' in the crate for a bit and
      // I will get on with 'bathing' the other dog."
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.openFor(dogId: 2, dogName: 'Bunny');
      timer.toggle(1, 'DRY');
      timer.toggle(2, 'WASH');

      expect(timer.sessionFor(1)!.runningPhase, 'DRY');
      expect(timer.sessionFor(2)!.runningPhase, 'WASH');

      // Pausing one leaves the other counting.
      timer.toggle(1, 'DRY');
      expect(timer.sessionFor(1)!.isRunning, isFalse);
      expect(timer.sessionFor(2)!.runningPhase, 'WASH');
      timer.pauseAll();
    });

    test('an empty session is not one worth going back to', () async {
      final timer = await service();
      expect(timer.hasAnySession, isFalse);
      timer.openFor(dogId: 1, dogName: 'Teddy');
      // Opened but nothing timed: the shell bar has nothing to show.
      expect(timer.hasAnySession, isFalse);
      timer.toggle(1, 'PREP');
      expect(timer.hasAnySession, isTrue);
      timer.pauseAll();
    });

    test('only one phase runs at a time per dog', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.toggle(1, 'PREP');
      expect(timer.sessionFor(1)!.runningPhase, 'PREP');
      timer.toggle(1, 'CLIP');
      expect(timer.sessionFor(1)!.runningPhase, 'CLIP');
      timer.toggle(1, 'CLIP');
      expect(timer.sessionFor(1)!.runningPhase, isNull);
      expect(timer.sessionFor(1)!.isRunning, isFalse);
    });

    test('clearing one dog leaves the other on the clock', () async {
      final timer = await service();
      timer.openFor(dogId: 1, dogName: 'Teddy');
      timer.setMinutes(1, 'PREP', 10);
      timer.openFor(dogId: 2, dogName: 'Bunny');
      timer.setMinutes(2, 'WASH', 5);

      await timer.clearSession(1);
      expect(timer.sessionFor(1), isNull);
      expect(timer.sessionFor(2)!.secondsFor('WASH'), 5 * 60);
      expect(stored.containsKey('mojo_groom_timer'), isTrue);

      await timer.clearSession(2);
      expect(timer.hasAnySession, isFalse);
      expect(stored.containsKey('mojo_groom_timer'), isFalse);
    });
  });

  group('Surviving the app closing', () {
    test('sessions written up survive a restart, both dogs', () async {
      final first = await service();
      first.openFor(dogId: 4, dogName: 'Bunny', usualMinutes: 105);
      first.setMinutes(4, 'STRIP', 40);
      first.openFor(dogId: 5, dogName: 'Teddy', usualMinutes: 60);
      first.setMinutes(5, 'WASH', 15);

      final second = await service();
      final bunny = second.sessionFor(4)!;
      expect(bunny.dogName, 'Bunny');
      expect(bunny.usualMinutes, 105);
      expect(bunny.secondsFor('STRIP'), 40 * 60);
      expect(bunny.wasEnteredManually('STRIP'), isTrue);
      expect(second.sessionFor(5)!.secondsFor('WASH'), 15 * 60);
    });

    test('the previous build\'s single-session blob still restores', () async {
      // The format changed under a phone that may have a groom on the clock.
      // Losing that to a shape change is exactly what persistence is for.
      storeLegacySession(dogId: 4, dogName: 'Bunny', elapsed: {'STRIP': 2400});
      final timer = await service();

      final session = timer.sessionFor(4)!;
      expect(session.dogName, 'Bunny');
      expect(session.usualMinutes, 105);
      expect(session.secondsFor('STRIP'), 2400);
    });

    test('a phase left running carries on from when it started', () async {
      // Not from now — restarting the count at zero would lose the groom that
      // has actually happened, which is the whole thing this guards.
      storeLegacySession(
        runningPhase: 'DRY',
        runningSince: DateTime.now().subtract(const Duration(minutes: 12)),
        elapsed: {'PREP': 300},
      );
      final timer = await service();

      final session = timer.sessionFor(7)!;
      expect(session.runningPhase, 'DRY');
      expect(session.secondsFor('DRY'), closeTo(12 * 60, 5));
      expect(session.secondsFor('PREP'), 300);
      timer.pauseAll();
    });

    test('a phase running implausibly long is flagged, never adjusted', () async {
      // An invented figure is indistinguishable from a measured one, so the
      // service says which phase looks wrong and leaves the number alone.
      storeLegacySession(
        runningPhase: 'CLIP',
        runningSince: DateTime.now().subtract(const Duration(hours: 14)),
      );
      final timer = await service();

      final session = timer.sessionFor(7)!;
      expect(session.leftRunningPhase, 'CLIP');
      expect(session.secondsFor('CLIP'), closeTo(14 * 3600, 5));
      timer.pauseAll();
    });

    test('a shorter run is not flagged', () async {
      storeLegacySession(
        runningPhase: 'CLIP',
        runningSince: DateTime.now().subtract(const Duration(minutes: 40)),
      );
      final timer = await service();
      expect(timer.sessionFor(7)!.leftRunningPhase, isNull);
      timer.pauseAll();
    });

    test('a running phase with no start stamp is dropped, not restarted', () async {
      // Half a record is no record: counting it from now would read as a
      // phase that had only just begun.
      storeLegacySession(runningPhase: 'WASH', elapsed: {'WASH': 120});
      final timer = await service();

      final session = timer.sessionFor(7)!;
      expect(session.isRunning, isFalse);
      expect(session.secondsFor('WASH'), 120);
    });

    test('a restore landing late never puts the previous dog back', () async {
      // Jess: the timer was "stuck on teddy instead of the actual dog it's
      // meant for". Reading the sessions back off the keystore is a round trip
      // the constructor does not block on, so a screen could open the timer
      // for the dog in front of her and have the restore land a moment later
      // and overwrite it — name, clock and all. Memory is the live state;
      // disk is a snapshot of an older one, so disk loses.
      storeLegacySession(dogId: 7, dogName: 'Teddy', elapsed: {'CLIP': 600});

      final timer = GroomTimerService(); // restore in flight, deliberately
      timer.openFor(dogId: 9, dogName: 'Bunny', usualMinutes: 60);
      await timer.ready;

      expect(timer.sessionFor(7), isNull,
          reason: "Teddy's clip time must not come back over the live state");
      final session = timer.sessionFor(9)!;
      expect(session.dogName, 'Bunny');
      expect(session.usualMinutes, 60);
      expect(session.totalSeconds, 0);
    });

    test('ready still completes when there was nothing stored', () async {
      final timer = GroomTimerService();
      await timer.ready;
      expect(timer.sessions, isEmpty);
    });

    test('an unreadable blob is cleared rather than wedging the timer', () async {
      stored['mojo_groom_timer'] = 'not json';
      final timer = await service();

      expect(timer.sessions, isEmpty);
      expect(stored.containsKey('mojo_groom_timer'), isFalse);
    });

    test('a booking already resolved is not lost to a later blank', () async {
      final timer = await service();
      timer.openFor(dogId: 4, dogName: 'Bunny', appointmentId: 88);
      // Re-opening from the shell bar, which has no appointment to offer.
      timer.openFor(dogId: 4, dogName: 'Bunny');
      expect(timer.sessionFor(4)!.appointmentId, 88);
    });
  });
}
