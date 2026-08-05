import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart' as models;

/// The groom timer, held outside the screen that draws it.
///
/// Jess: *"is it not possible to have the timer running in the background,
/// mostly whilst prep, clipping or stripping just need to be able to check
/// notes as I figured out today whilst doing bunny"*. It could not: every
/// count lived in `_GroomTimerScreenState`, so backing out to read the dog's
/// handling notes threw the whole groom away with no warning. A timer you
/// cannot leave is a timer that has to be right first time.
///
/// Two things make this survive:
///
/// * it is a singleton, so navigating away only disposes the *view*;
/// * it writes itself to disk on every change, so an OS that kills the app
///   mid-groom — which iOS will do while the camera is open — does not take
///   two hours of timing with it.
///
/// Elapsed time is always derived from wall-clock stamps rather than counted
/// ticks. A backgrounded app stops getting timer callbacks; a `DateTime`
/// difference does not care.
///
/// Storage is [FlutterSecureStorage] because it is already a dependency, not
/// because a running timer is a secret.
class GroomTimerService extends ChangeNotifier {
  GroomTimerService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage() {
    // Fire and forget: listeners are notified if anything was found, and the
    // app is usable in the meantime either way.
    unawaited(restore());
  }

  static const _storageKey = 'mojo_groom_timer';

  /// Past this, a running phase is far more likely to have been left on than
  /// to be real work. Nothing is discarded or capped on the strength of it —
  /// the screen says so and Jess types the real figure in, because a number
  /// this code invented would be indistinguishable from one she measured.
  static const implausibleRun = Duration(hours: 4);

  final FlutterSecureStorage _storage;

  int? _dogId;
  String _dogName = '';
  int? _appointmentId;
  int _usualMinutes = 0;
  final Map<String, int> _elapsed = {};
  final Set<String> _manual = {};
  String? _runningPhase;
  DateTime? _runningSince;
  Timer? _ticker;

  int? get dogId => _dogId;
  String get dogName => _dogName;
  int? get appointmentId => _appointmentId;
  int get usualMinutes => _usualMinutes;
  String? get runningPhase => _runningPhase;
  bool get isRunning => _runningPhase != null;
  bool get enteredManually => _manual.isNotEmpty;

  /// Whether there is anything worth going back to — time on the clock, or a
  /// phase still running.
  bool get hasSession => _dogId != null && (totalSeconds > 0 || isRunning);

  /// The phase that has been running implausibly long, if any. See
  /// [implausibleRun].
  String? get leftRunningPhase {
    final since = _runningSince;
    if (_runningPhase == null || since == null) return null;
    return DateTime.now().difference(since) > implausibleRun ? _runningPhase : null;
  }

  int secondsFor(String phase) {
    final banked = _elapsed[phase] ?? 0;
    if (_runningPhase != phase || _runningSince == null) return banked;
    return banked + DateTime.now().difference(_runningSince!).inSeconds;
  }

  int get totalSeconds => models.PhaseTiming.phaseOrder
      .fold(0, (sum, phase) => sum + secondsFor(phase));

  int get totalMinutes => (totalSeconds / 60).round();

  bool wasEnteredManually(String phase) => _manual.contains(phase);

  /// The phases that were actually used. Empty when nothing has been timed.
  ///
  /// Reads banked time only, so call [pause] first if a phase is still
  /// running — [timingsNow] does that for you.
  List<models.PhaseTiming> get timingsNow {
    pause();
    return [
      for (final phase in models.PhaseTiming.phaseOrder)
        if ((_elapsed[phase] ?? 0) > 0)
          models.PhaseTiming(
            phase: phase,
            durationSeconds: _elapsed[phase]!,
            enteredManually: _manual.contains(phase),
          ),
    ];
  }

  /// Whether a timer is already going for a *different* dog.
  ///
  /// The one thing this must never do is quietly add Teddy's clip time to
  /// Bunny's groom, so the screen asks before taking a session over.
  bool holdsAnotherDog(int dogId) => hasSession && _dogId != dogId;

  /// Point the timer at a dog, keeping anything already recorded for it.
  ///
  /// Re-opening the screen mid-groom lands here, which is the whole point —
  /// so a matching [dogId] leaves every count alone. A different dog is a
  /// fresh session and clears the board; callers check [holdsAnotherDog]
  /// first and ask.
  void openFor({
    required int dogId,
    required String dogName,
    int? appointmentId,
    int usualMinutes = 0,
  }) {
    if (_dogId != dogId) {
      _reset();
      _dogId = dogId;
    }
    _dogName = dogName;
    _usualMinutes = usualMinutes;
    // Only ever fill a blank: the server resolves the booking when nothing is
    // named, and a null arriving later must not wipe an id that was.
    _appointmentId ??= appointmentId;
    _persist();
    notifyListeners();
  }

  /// Start a phase, or pause it if it is the one running.
  ///
  /// One at a time — starting another banks the current one. A groom is one
  /// pair of hands.
  void toggle(String phase) {
    if (_runningPhase == phase) {
      pause();
      return;
    }
    _bank();
    _runningPhase = phase;
    _runningSince = DateTime.now();
    _manual.remove(phase);
    _startTicking();
    _persist();
    notifyListeners();
  }

  void pause() {
    if (_runningPhase == null) return;
    _bank();
    _persist();
    notifyListeners();
  }

  /// Type a phase in, for a groom that was not timed live.
  void setMinutes(String phase, int minutes) {
    if (_runningPhase == phase) _bank();
    _elapsed[phase] = minutes * 60;
    if (minutes > 0) {
      _manual.add(phase);
    } else {
      _manual.remove(phase);
      _elapsed.remove(phase);
    }
    _persist();
    notifyListeners();
  }

  /// Throw the session away — after saving it, or when Jess says so.
  Future<void> clear() async {
    _reset();
    _dogId = null;
    _dogName = '';
    try {
      await _storage.delete(key: _storageKey);
    } catch (_) {
      // Nothing to do about it, and the in-memory session is already gone.
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _reset() {
    _ticker?.cancel();
    _ticker = null;
    _elapsed.clear();
    _manual.clear();
    _runningPhase = null;
    _runningSince = null;
    _appointmentId = null;
    _usualMinutes = 0;
  }

  void _bank() {
    final phase = _runningPhase;
    final since = _runningSince;
    if (phase == null || since == null) return;
    _elapsed[phase] = (_elapsed[phase] ?? 0) + DateTime.now().difference(since).inSeconds;
    _runningPhase = null;
    _runningSince = null;
    _ticker?.cancel();
    _ticker = null;
  }

  void _startTicking() {
    _ticker?.cancel();
    // Only so the clock on screen moves. The figure itself comes from
    // `_runningSince`, so a missed tick costs nothing.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
  }

  // ── Disk ─────────────────────────────────────────────────────────────

  Future<void> _persist() async {
    if (_dogId == null) return;
    try {
      await _storage.write(
        key: _storageKey,
        value: jsonEncode({
        'dogId': _dogId,
        'dogName': _dogName,
        'appointmentId': _appointmentId,
        'usualMinutes': _usualMinutes,
        'elapsed': _elapsed,
        'manual': _manual.toList(),
        'runningPhase': _runningPhase,
          'runningSince': _runningSince?.toIso8601String(),
        }),
      );
    } catch (_) {
      // The timer still works from memory, which is the half Jess actually
      // asked for. A keystore that will not take a write is not a reason to
      // throw the groom away.
    }
  }

  /// Read back a groom that was in progress when the app last stopped.
  ///
  /// A phase left running keeps running — the stamp is absolute, so the count
  /// carries on from when it started rather than from now. If that turns out
  /// to be implausibly long, [leftRunningPhase] says so and the screen warns
  /// rather than this quietly deciding what the real figure was.
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
      final dogId = (data['dogId'] as num?)?.toInt();
      if (dogId == null) return;

      _dogId = dogId;
      _dogName = data['dogName']?.toString() ?? '';
      _appointmentId = (data['appointmentId'] as num?)?.toInt();
      _usualMinutes = (data['usualMinutes'] as num?)?.toInt() ?? 0;
      _elapsed
        ..clear()
        ..addAll({
          for (final entry in ((data['elapsed'] as Map?) ?? const {}).entries)
            if (entry.value is num) entry.key.toString(): (entry.value as num).toInt(),
        });
      _manual
        ..clear()
        ..addAll(((data['manual'] as List?) ?? const []).map((e) => e.toString()));
      _runningPhase = data['runningPhase']?.toString();
      _runningSince = DateTime.tryParse(data['runningSince']?.toString() ?? '');
      if (_runningPhase != null && _runningSince != null) {
        _startTicking();
      } else {
        // Half a record is no record — a phase without its start stamp would
        // count from zero and read as though it had only just begun.
        _runningPhase = null;
        _runningSince = null;
      }
      notifyListeners();
    } catch (_) {
      // Unreadable is the same as absent, and a corrupt blob must not wedge
      // the timer for good.
      await _storage.delete(key: _storageKey);
    }
  }
}
