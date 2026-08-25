import 'dart:async';

import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart' as models;
import '../../services/data_service.dart';
import '../../services/groom_timer_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import 'visit_record_screen.dart';

/// Time a groom phase by phase.
///
/// Not every groom uses every phase — a wash and blow-dry records no clip or
/// strip — so each timer is independent and a phase with no time simply isn't
/// saved. Any phase can also be typed in, for a groom that wasn't timed live.
///
/// **The counts do not live here.** They live in [GroomTimerService], because
/// Jess asked to be able to leave: *"just need to be able to check notes as I
/// figured out today whilst doing bunny"*. This screen is a view over that —
/// closing it pauses nothing and loses nothing, and the running clock stays on
/// the staff shell until the groom is written up.
///
/// The total can be written back to the dog as its default groom time, which
/// then sizes the diary block for future bookings.
class GroomTimerScreen extends StatefulWidget {
  const GroomTimerScreen({
    super.key,
    required this.dogId,
    required this.dogName,
    this.usualMinutes = 0,
    this.appointmentId,
  });

  /// From a dog record, which is how a profile opens it.
  GroomTimerScreen.forDog(models.Dog dog, {super.key, this.appointmentId})
      : dogId = dog.id,
        dogName = dog.name,
        usualMinutes = dog.groomMinutes;

  final int dogId;
  final String dogName;
  final int usualMinutes;

  /// Usually null. The server matches a visit to the day's booking itself —
  /// this is for opening the timer from a booking, where the answer is known.
  final int? appointmentId;

  @override
  State<GroomTimerScreen> createState() => _GroomTimerScreenState();
}

class _GroomTimerScreenState extends State<GroomTimerScreen> {
  final _data = getIt<DataService>();
  final _timer = getIt<GroomTimerService>();

  bool _busy = false;

  /// Jess's own figure for what the timer never sees — nails, ears, the health
  /// check, drop-off and collection. Null until she sets it in Settings, and
  /// nothing is guessed: until then a timed groom books at exactly what it
  /// timed, which is what it has always done.
  int? _bookingBuffer;

  @override
  void initState() {
    super.initState();
    // After the first frame, so a dialog has a Navigator to sit in.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    unawaited(_loadBuffer());
  }

  Future<void> _loadBuffer() async {
    try {
      final settings = await _data.getSettings();
      if (mounted) setState(() => _bookingBuffer = settings.groomTimeBufferMinutes);
    } catch (_) {
      // The timer works without it, and a null buffer adds nothing — which is
      // the same answer as not having read the setting.
    }
  }

  /// How long this groom says to book the dog in for.
  ///
  /// Jess: the groom time was *"nowhere near the appointment time (which would
  /// be how long to book them in for)"*. It could not be — the timer counts
  /// five phases and this figure has to cover a whole visit. The server does
  /// the same sum when it writes the dog's default; this is so the button says
  /// which number it is about to write rather than quoting the stopwatch back.
  int get _bookableMinutes => _timer.totalMinutes + (_bookingBuffer ?? 0);

  Future<void> _open() async {
    // Before anything reads which dog the timer is on. The session on disk is
    // read back asynchronously, and a restore landing after this would put the
    // previous dog back — the timer stuck on Teddy while Jess grooms Bunny.
    await _timer.ready;
    if (!mounted) return;

    if (_timer.holdsAnotherDog(widget.dogId)) {
      final held = _timer.dogName;
      // Never silently roll one dog's time into another's, and never throw the
      // first one away without asking — neither is a guess worth making.
      //
      // The way out used to be discard or nothing, which is why an unfinished
      // session could sit in front of every other dog: the only button that
      // moved things on destroyed an hour of timing, so the honest answer was
      // to back out, and then the timer said Teddy for good. Writing the other
      // dog up is the third way, and it is the one Jess actually wants —
      // that time belongs on a record card, not in a dialog.
      final choice = await showDialog<_HeldSession>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$held is still being timed'),
          content: Text(
            '${models.formatClock(_timer.totalSeconds)} recorded so far. '
            "Write it up to keep it, or discard it to start ${widget.dogName}.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _HeldSession.goBack),
              child: const Text('GO BACK'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _HeldSession.discard),
              child: const Text('DISCARD IT'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, _HeldSession.writeUp),
              child: Text('WRITE UP ${held.toUpperCase()}'),
            ),
          ],
        ),
      );
      if (!mounted) return;

      switch (choice) {
        case null:
        case _HeldSession.goBack:
          Navigator.of(context).pop();
          return;
        case _HeldSession.writeUp:
          final wroteUp = await _writeUpHeldSession();
          if (!mounted) return;
          if (!wroteUp) {
            // The card was backed out of, so nothing was saved and the held
            // session is still the held session. Leaving this screen open on
            // the new dog would show the other one's clock.
            Navigator.of(context).pop();
            return;
          }
        case _HeldSession.discard:
          await _timer.clear();
          if (!mounted) return;
      }
    }
    _timer.openFor(
      dogId: widget.dogId,
      dogName: widget.dogName,
      appointmentId: widget.appointmentId,
      usualMinutes: widget.usualMinutes,
    );
  }

  /// Send the *other* dog's timing to a record card, so switching dogs never
  /// costs a groom.
  ///
  /// Returns whether it was saved. The timer is only cleared on a save — a
  /// card Jess backed out of has not recorded anything, and clearing anyway
  /// would throw the session away by a quieter route than the button that says
  /// so.
  Future<bool> _writeUpHeldSession() async {
    final heldDogId = _timer.dogId;
    if (heldDogId == null) return true;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => VisitRecordScreen(
          dogId: heldDogId,
          dogName: _timer.dogName,
          appointmentId: _timer.appointmentId,
          timings: _timer.timingsNow,
        ),
      ),
    );
    if (saved != true) return false;
    await _timer.clear();
    return true;
  }

  Future<void> _editManually(String phase) async {
    final entered = await promptForText(
      context,
      title: '${models.PhaseTiming.labelFor(phase)} — enter minutes',
      initialValue: (_timer.secondsFor(phase) ~/ 60).toString(),
      suffixText: 'minutes',
      keyboardType: TextInputType.number,
      confirmLabel: 'SET',
    );
    if (entered == null) return;
    _timer.setMinutes(phase, int.tryParse(entered) ?? 0);
  }

  /// Hand the timings to the record card rather than saving here, so the
  /// session is created once with the whole groom written up — matting,
  /// shampoo, equipment and all.
  Future<void> _writeUp() async {
    final timings = _timer.timingsNow;
    if (timings.isEmpty) {
      showSnack(context, 'No time recorded yet.', isError: true);
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => VisitRecordScreen(
          dogId: widget.dogId,
          dogName: widget.dogName,
          appointmentId: _timer.appointmentId,
          timings: timings,
        ),
      ),
    );
    if (saved != true || !mounted) return;
    // The card saved the session, so this timing is spent. Leaving it running
    // is how the next dog inherits this one's clip time.
    await _timer.clear();
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _save({required bool applyToDog}) async {
    final timings = _timer.timingsNow;
    if (timings.isEmpty) {
      showSnack(context, 'No time recorded yet.', isError: true);
      return;
    }
    setState(() => _busy = true);

    try {
      final session = await _data.createGroomSession(
        dogId: widget.dogId,
        appointmentId: _timer.appointmentId,
        timings: timings,
      );
      if (applyToDog) {
        await _data.applySessionToDog(session.id);
      }
      await _timer.clear();
      if (!mounted) return;
      // One bar carrying both halves, and the undo if a booking was closed.
      reportSavedVisit(
        context,
        session,
        saved: applyToDog
            // The server's own figure for what it wrote, not the stopwatch —
            // they differ by the booking buffer, and saying the wrong one is
            // how the number on the dog becomes a surprise.
            ? "Saved. ${widget.dogName}'s groom time is now "
                '${models.formatDuration(session.bookableMinutes)}.'
            : 'Groom session saved.',
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  Future<void> _discard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this timing?'),
        content: Text(
          '${models.formatClock(_timer.totalSeconds)} recorded for ${widget.dogName}, '
          'and not saved to a visit record.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('KEEP')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DISCARD'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _timer.clear();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Timing ${widget.dogName}')),
      body: ListenableBuilder(
        listenable: _timer,
        builder: (context, _) {
          final totalMinutes = _timer.totalMinutes;
          final leftRunning = _timer.leftRunningPhase;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 20),
                color: context.mojo.tintWash,
                alignment: Alignment.center,
                child: Column(
                  children: [
                    Text(models.formatClock(_timer.totalSeconds), style: AppColors.display(44)),
                    const SizedBox(height: 4),
                    Text(
                      'Usual: ${models.formatDuration(widget.usualMinutes)}',
                      style: TextStyle(fontSize: 12, color: context.mojo.muted),
                    ),
                  ],
                ),
              ),
              if (leftRunning != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    color: AppColors.warning.withValues(alpha: 0.12),
                    child: Text(
                      '${models.PhaseTiming.labelFor(leftRunning)} has been running for '
                      '${models.formatClock(_timer.secondsFor(leftRunning))}. If it was left on, '
                      'pause it and type the real time in.',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.warning),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Tap a phase to start or pause it. Skip any you did not do. '
                  'The clock keeps going if you leave this screen.',
                  style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
                ),
              ),
              for (final phase in models.PhaseTiming.phaseOrder) _phaseTile(phase),
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: _busy || totalMinutes == 0 ? null : () => _save(applyToDog: true),
                child: Text(
                  _busy
                      ? 'SAVING…'
                      // The bookable figure, not the timed one. Quoting the
                      // stopwatch here is what made the default land "nowhere
                      // near the appointment time".
                      : 'SAVE & SET AS DEFAULT '
                          '(${models.formatDuration(_bookableMinutes)})',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _busy || totalMinutes == 0 ? null : () => _save(applyToDog: false),
                child: const Text('SAVE WITHOUT CHANGING DEFAULT'),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _busy || totalMinutes == 0 ? null : _writeUp,
                child: const Text('WRITE UP THE GROOM CARD'),
              ),
              if (totalMinutes > 0) ...[
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _busy ? null : _discard,
                  child: const Text('DISCARD THIS TIMING'),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                _bookingBuffer == null
                    // Said plainly rather than silently booking the raw timing.
                    // Nothing is added until Jess sets a figure, and a groom
                    // is more than the five phases this screen counts.
                    ? "Setting the default changes how much diary time this dog's "
                        'future bookings block out. It will use the '
                        '${models.formatDuration(totalMinutes)} timed here — the timer '
                        'does not count the nails, ears, health check or handover, so '
                        'if that is short, set "Add to a timed groom" in Settings.'
                    : "Setting the default changes how much diary time this dog's "
                        'future bookings block out: '
                        '${models.formatDuration(totalMinutes)} timed + '
                        '${models.formatDuration(_bookingBuffer!)} for the nails, ears, '
                        'health check and handover = '
                        '${models.formatDuration(_bookableMinutes)}.',
                style: TextStyle(fontSize: 12, color: context.mojo.muted),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _phaseTile(String phase) {
    final seconds = _timer.secondsFor(phase);
    final isRunning = _timer.runningPhase == phase;
    final used = seconds > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _timer.toggle(phase),
        leading: Container(
          width: 44,
          height: 44,
          color: isRunning ? AppColors.primaryBright : context.mojo.tint,
          alignment: Alignment.center,
          child: Icon(
            isRunning ? Icons.pause : Icons.play_arrow,
            color: isRunning ? Colors.black : context.mojo.onTint,
          ),
        ),
        title: Text(
          models.PhaseTiming.labelFor(phase),
          style: TextStyle(fontWeight: used ? FontWeight.w700 : FontWeight.w400),
        ),
        subtitle: _timer.wasEnteredManually(phase) ? const Text('Entered by hand') : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              models.formatClock(seconds),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: used ? null : context.mojo.muted,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: 'Enter by hand',
              onPressed: () => _editManually(phase),
            ),
          ],
        ),
      ),
    );
  }
}

/// What to do with a timing that belongs to a different dog.
enum _HeldSession { goBack, writeUp, discard }
