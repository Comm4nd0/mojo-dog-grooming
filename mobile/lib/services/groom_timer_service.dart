import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart' as models;

/// One dog's timing: its phases, the phase running now, and where it came
/// from. Held by [GroomTimerService], which owns several of these at once.
///
/// Elapsed time is always derived from wall-clock stamps rather than counted
/// ticks. A backgrounded app stops getting timer callbacks; a `DateTime`
/// difference does not care.
class GroomTimerSession {
  GroomTimerSession({
    required this.dogId,
    required this.dogName,
    this.appointmentId,
    this.usualMinutes = 0,
  });

  final int dogId;
  String dogName;
  int? appointmentId;
  int usualMinutes;

  final Map<String, int> elapsed = {};
  final Set<String> manual = {};
  String? runningPhase;
  DateTime? runningSince;

  bool get isRunning => runningPhase != null;

  int secondsFor(String phase) {
    final banked = elapsed[phase] ?? 0;
    if (runningPhase != phase || runningSince == null) return banked;
    return banked + DateTime.now().difference(runningSince!).inSeconds;
  }

  int get totalSeconds => models.PhaseTiming.phaseOrder
      .fold(0, (sum, phase) => sum + secondsFor(phase));

  int get totalMinutes => (totalSeconds / 60).round();

  bool wasEnteredManually(String phase) => manual.contains(phase);

  /// Whether there is anything worth going back to — time on the clock, or a
  /// phase still running.
  bool get hasTime => totalSeconds > 0 || isRunning;

  /// The phase that has been running implausibly long, if any. See
  /// [GroomTimerService.implausibleRun].
  String? get leftRunningPhase {
    final since = runningSince;
    if (runningPhase == null || since == null) return null;
    return DateTime.now().difference(since) > GroomTimerService.implausibleRun
        ? runningPhase
        : null;
  }

  /// Bank the running phase, if any.
  void bank() {
    final phase = runningPhase;
    final since = runningSince;
    if (phase == null || since == null) return;
    elapsed[phase] = (elapsed[phase] ?? 0) + DateTime.now().difference(since).inSeconds;
    runningPhase = null;
    runningSince = null;
  }

  Map<String, dynamic> toJson() => {
        'dogId': dogId,
        'dogName': dogName,
        'appointmentId': appointmentId,
        'usualMinutes': usualMinutes,
        'elapsed': elapsed,
        'manual': manual.toList(),
        'runningPhase': runningPhase,
        'runningSince': runningSince?.toIso8601String(),
      };

  /// Null when the blob has no usable dog in it.
  static GroomTimerSession? fromJson(Map<String, dynamic> data) {
    final dogId = (data['dogId'] as num?)?.toInt();
    if (dogId == null) return null;
    final session = GroomTimerSession(
      dogId: dogId,
      dogName: data['dogName']?.toString() ?? '',
      appointmentId: (data['appointmentId'] as num?)?.toInt(),
      usualMinutes: (data['usualMinutes'] as num?)?.toInt() ?? 0,
    );
    session.elapsed.addAll({
      for (final entry in ((data['elapsed'] as Map?) ?? const {}).entries)
        if (entry.value is num) entry.key.toString(): (entry.value as num).toInt(),
    });
    session.manual
        .addAll(((data['manual'] as List?) ?? const []).map((e) => e.toString()));
    session.runningPhase = data['runningPhase']?.toString();
    session.runningSince = DateTime.tryParse(data['runningSince']?.toString() ?? '');
    if (session.runningPhase == null || session.runningSince == null) {
      // Half a record is no record — a phase without its start stamp would
      // count from zero and read as though it had only just begun.
      session.runningPhase = null;
      session.runningSince = null;
    }
    return session;
  }
}

/// The groom timers, held outside the screens that draw them.
///
/// Jess: *"is it not possible to have the timer running in the background,
/// mostly whilst prep, clipping or stripping just need to be able to check
/// notes as I figured out today whilst doing bunny"*. It could not: every
/// count lived in `_GroomTimerScreenState`, so backing out to read the dog's
/// handling notes threw the whole groom away with no warning. A timer you
/// cannot leave is a timer that has to be right first time.
///
/// **Timers, plural.** Her follow-up: *"can it be 'paused' so once all the
/// 'prep' done on one, the 'prep' for the other can be added? Like I will
/// bath one and they can 'dry' in the crate for a bit and I will get on with
/// 'bathing' the other dog"*. Dogs from one household are groomed
/// interleaved, so the service holds one session per dog, each with at most
/// one phase running — Bunny's dry counts on while Teddy is in the bath. What
/// it must never do is merge them: a phase belongs to exactly one dog.
///
/// Two things make this survive:
///
/// * it is a singleton, so navigating away only disposes the *view*;
/// * it writes itself to disk on every change, so an OS that kills the app
///   mid-groom — which iOS will do while the camera is open — does not take
///   two hours of timing with it.
///
/// Elapsed time is always derived from wall-clock stamps rather than counted
/// ticks. Storage is [FlutterSecureStorage] because it is already a
/// dependency, not because a running timer is a secret.
class GroomTimerService extends ChangeNotifier {
  GroomTimerService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage() {
    // Started here rather than awaited: listeners are notified if anything was
    // found, and the app is usable in the meantime either way. The future is
    // kept so a caller that *does* care can wait — see [ready].
    _restoring = restore();
  }

  static const _storageKey = 'mojo_groom_timer';

  /// Past this, a running phase is far more likely to have been left on than
  /// to be real work. Nothing is discarded or capped on the strength of it —
  /// the screen says so and Jess types the real figure in, because a number
  /// this code invented would be indistinguishable from one she measured.
  static const implausibleRun = Duration(hours: 4);

  final FlutterSecureStorage _storage;

  Future<void>? _restoring;

  /// Completes once the sessions on disk have been read back, if there were
  /// any.
  ///
  /// Anything that decides *which dogs* the timer is on has to wait for this.
  /// The read is a keystore round trip and the constructor does not block on
  /// it, so without this a screen could open the timer for the dog in front of
  /// Jess and have the restore land a moment later and put the previous dog
  /// back — the timer showing Teddy on Bunny's groom.
  Future<void> get ready => _restoring ?? Future<void>.value();

  final List<GroomTimerSession> _sessions = [];
  Timer? _ticker;

  /// Every open session, in the order the dogs were opened.
  List<GroomTimerSession> get sessions => List.unmodifiable(_sessions);

  GroomTimerSession? sessionFor(int dogId) {
    for (final session in _sessions) {
      if (session.dogId == dogId) return session;
    }
    return null;
  }

  /// The sessions worth showing — time on the clock, or a phase running.
  List<GroomTimerSession> get liveSessions =>
      [for (final session in _sessions) if (session.hasTime) session];

  /// Whether anything at all is worth going back to.
  bool get hasAnySession => liveSessions.isNotEmpty;

  /// Point the timer at a dog, keeping anything already recorded for it —
  /// and keeping every *other* dog's session running untouched.
  ///
  /// Re-opening the screen mid-groom lands here, which is the whole point —
  /// a matching [dogId] leaves every count alone. A dog not yet timed gets a
  /// fresh session alongside the others; nothing is cleared, because
  /// switching dogs mid-morning is how Jess works a shared visit.
  GroomTimerSession openFor({
    required int dogId,
    required String dogName,
    int? appointmentId,
    int usualMinutes = 0,
  }) {
    var session = sessionFor(dogId);
    if (session == null) {
      session = GroomTimerSession(dogId: dogId, dogName: dogName);
      _sessions.add(session);
    }
    session.dogName = dogName;
    if (usualMinutes > 0) session.usualMinutes = usualMinutes;
    // Only ever fill a blank: the server resolves the booking when nothing is
    // named, and a null arriving later must not wipe an id that was.
    session.appointmentId ??= appointmentId;
    _persist();
    notifyListeners();
    return session;
  }

  /// Start a phase for [dogId], or pause it if it is the one running.
  ///
  /// One phase at a time *per dog* — starting another banks the current one.
  /// Other dogs' phases keep counting: a dog drying in the crate is genuinely
  /// drying while Jess baths the next one, and that is the request this
  /// carries.
  void toggle(int dogId, String phase) {
    final session = sessionFor(dogId);
    if (session == null) return;
    if (session.runningPhase == phase) {
      session.bank();
    } else {
      session.bank();
      session.runningPhase = phase;
      session.runningSince = DateTime.now();
      session.manual.remove(phase);
    }
    _syncTicker();
    _persist();
    notifyListeners();
  }

  /// Pause every running phase, across every dog.
  void pauseAll() {
    for (final session in _sessions) {
      session.bank();
    }
    _syncTicker();
    _persist();
    notifyListeners();
  }

  /// Type a phase in, for a groom that was not timed live.
  void setMinutes(int dogId, String phase, int minutes) {
    final session = sessionFor(dogId);
    if (session == null) return;
    if (session.runningPhase == phase) session.bank();
    session.elapsed[phase] = minutes * 60;
    if (minutes > 0) {
      session.manual.add(phase);
    } else {
      session.manual.remove(phase);
      session.elapsed.remove(phase);
    }
    _syncTicker();
    _persist();
    notifyListeners();
  }

  /// The phases that were actually used for [dogId]. Empty when nothing has
  /// been timed. Banks the running phase first, so the figure handed to the
  /// record card is settled.
  List<models.PhaseTiming> timingsNow(int dogId) {
    final session = sessionFor(dogId);
    if (session == null) return const [];
    session.bank();
    _syncTicker();
    _persist();
    notifyListeners();
    return [
      for (final phase in models.PhaseTiming.phaseOrder)
        if ((session.elapsed[phase] ?? 0) > 0)
          models.PhaseTiming(
            phase: phase,
            durationSeconds: session.elapsed[phase]!,
            enteredManually: session.manual.contains(phase),
          ),
    ];
  }

  /// Throw one dog's session away — after saving it, or when Jess says so.
  /// Every other dog's clock is untouched.
  Future<void> clearSession(int dogId) async {
    _sessions.removeWhere((session) => session.dogId == dogId);
    _syncTicker();
    if (_sessions.isEmpty) {
      try {
        await _storage.delete(key: _storageKey);
      } catch (_) {
        // Nothing to do about it, and the in-memory session is already gone.
      }
    } else {
      await _persist();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    final anyRunning = _sessions.any((session) => session.isRunning);
    if (anyRunning && _ticker == null) {
      // Only so the clocks on screen move. The figures themselves come from
      // `runningSince`, so a missed tick costs nothing.
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    } else if (!anyRunning) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  // ── Disk ─────────────────────────────────────────────────────────────

  Future<void> _persist() async {
    if (_sessions.isEmpty) return;
    try {
      await _storage.write(
        key: _storageKey,
        value: jsonEncode({
          'sessions': [for (final session in _sessions) session.toJson()],
        }),
      );
    } catch (_) {
      // The timer still works from memory, which is the half Jess actually
      // asked for. A keystore that will not take a write is not a reason to
      // throw the groom away.
    }
  }

  /// Read back the grooms that were in progress when the app last stopped.
  ///
  /// A phase left running keeps running — the stamp is absolute, so the count
  /// carries on from when it started rather than from now. If that turns out
  /// to be implausibly long, [GroomTimerSession.leftRunningPhase] says so and
  /// the screen warns rather than this quietly deciding what the real figure
  /// was.
  ///
  /// Understands both the multi-session blob and the single-session shape
  /// written before this build — the phone updates with a groom on the clock,
  /// and losing it to a format change would be exactly the loss persistence
  /// exists to prevent.
  Future<void> restore() async {
    String? raw;
    try {
      raw = await _storage.read(key: _storageKey);
    } catch (_) {
      // A locked or wiped keystore is not worth failing to start over.
      return;
    }
    if (raw == null || raw.isEmpty) return;

    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;

      // Something opened the timer while this read was in flight. Memory is
      // the live state and disk is a snapshot of an older one, so disk
      // loses — restoring over the top is how the previous dog's name and
      // clock end up on the groom Jess is standing over.
      if (_sessions.isNotEmpty) return;

      final rows = data['sessions'] is List
          ? (data['sessions'] as List).whereType<Map>().toList()
          // The pre-multi-dog format: one session's fields at the top level.
          : [data];
      for (final row in rows) {
        final session =
            GroomTimerSession.fromJson(Map<String, dynamic>.from(row));
        if (session != null && sessionFor(session.dogId) == null) {
          _sessions.add(session);
        }
      }
      _syncTicker();
      notifyListeners();
    } catch (_) {
      // Unreadable is the same as absent, and a corrupt blob must not wedge
      // the timer for good.
      await _storage.delete(key: _storageKey);
    }
  }
}
