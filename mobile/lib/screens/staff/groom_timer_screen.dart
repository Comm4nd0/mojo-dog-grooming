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

  @override
  void initState() {
    super.initState();
    // After the first frame, so a dialog has a Navigator to sit in.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (!mounted) return;
    if (_timer.holdsAnotherDog(widget.dogId)) {
      // Never silently roll one dog's time into another's, and never throw the
      // first one away without asking — neither is a guess worth making.
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${_timer.dogName} is still being timed'),
          content: Text(
            '${formatClock(_timer.totalSeconds)} recorded so far. '
            'Starting ${widget.dogName} throws it away.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('GO BACK'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('DISCARD AND START'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (discard != true) {
        Navigator.of(context).pop();
        return;
      }
      await _timer.clear();
      if (!mounted) return;
    }
    _timer.openFor(
      dogId: widget.dogId,
      dogName: widget.dogName,
      appointmentId: widget.appointmentId,
      usualMinutes: widget.usualMinutes,
    );
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
            ? "Saved. ${widget.dogName}'s groom time is now "
                '${models.formatDuration(session.totalMinutes)}.'
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
          '${formatClock(_timer.totalSeconds)} recorded for ${widget.dogName}, '
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
                    Text(formatClock(_timer.totalSeconds), style: AppColors.display(44)),
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
                      '${formatClock(_timer.secondsFor(leftRunning))}. If it was left on, '
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
                      : 'SAVE & SET AS DEFAULT (${models.formatDuration(totalMinutes)})',
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
                "Setting the default changes how much diary time this dog's future "
                'bookings block out.',
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
              formatClock(seconds),
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

/// `1:04:09`, or `04:09` under the hour.
String formatClock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
