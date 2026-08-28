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
/// figured out today whilst doing bunny"*. This screen is a view over one
/// dog's session — closing it pauses nothing and loses nothing, and the
/// running clocks stay on the staff shell until each groom is written up.
///
/// **Opening a second dog no longer asks what to do with the first.** Jess:
/// *"I will bath one and they can 'dry' in the crate for a bit and I will get
/// on with 'bathing' the other dog"* — dogs from one household are groomed
/// interleaved, so the service keeps a session per dog and this screen offers
/// the others as one-tap switches. The old dialog made her choose between
/// discarding Teddy's hour and backing out; now Teddy's dry simply keeps
/// counting while Bunny is on screen.
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

  /// Jess's own figure for what the phases never cover — the handover at both
  /// ends and anything done off the clock. Null until she sets it in
  /// Settings, and nothing is guessed: until then a timed groom books at
  /// exactly what it timed, which is what it has always done.
  int? _bookingBuffer;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
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

  Future<void> _open() async {
    // Before anything reads which dogs the timer is on. The sessions on disk
    // are read back asynchronously, and opening before the restore lands is
    // handled by the service — memory wins, disk loses.
    await _timer.ready;
    if (!mounted) return;
    _timer.openFor(
      dogId: widget.dogId,
      dogName: widget.dogName,
      appointmentId: widget.appointmentId,
      usualMinutes: widget.usualMinutes,
    );
  }

  GroomTimerSession? get _session => _timer.sessionFor(widget.dogId);

  int get _totalSeconds => _session?.totalSeconds ?? 0;
  int get _totalMinutes => _session?.totalMinutes ?? 0;

  /// How long this groom says to book the dog in for.
  ///
  /// Jess: the groom time was *"nowhere near the appointment time (which would
  /// be how long to book them in for)"*. It could not be — the timer counts
  /// five phases and this figure has to cover a whole visit. The server does
  /// the same sum when it writes the dog's default; this is so the button says
  /// which number it is about to write rather than quoting the stopwatch back.
  int get _bookableMinutes => _totalMinutes + (_bookingBuffer ?? 0);

  Future<void> _editManually(String phase) async {
    final entered = await promptForText(
      context,
      title: '${models.PhaseTiming.labelFor(phase)} — enter minutes',
      initialValue: ((_session?.secondsFor(phase) ?? 0) ~/ 60).toString(),
      suffixText: 'minutes',
      keyboardType: TextInputType.number,
      confirmLabel: 'SET',
    );
    if (entered == null) return;
    _timer.setMinutes(widget.dogId, phase, int.tryParse(entered) ?? 0);
  }

  /// Hand the timings to the record card rather than saving here, so the
  /// session is created once with the whole groom written up — matting,
  /// checklist, equipment and all.
  Future<void> _writeUp() async {
    final timings = _timer.timingsNow(widget.dogId);
    if (timings.isEmpty) {
      showSnack(context, 'No time recorded yet.', isError: true);
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => VisitRecordScreen(
          dogId: widget.dogId,
          dogName: widget.dogName,
          appointmentId: _session?.appointmentId,
          timings: timings,
        ),
      ),
    );
    if (saved != true || !mounted) return;
    // The card saved the session, so this timing is spent. Leaving it running
    // is how the next dog inherits this one's clip time. Only this dog's —
    // any other dog still drying keeps its clock.
    await _timer.clearSession(widget.dogId);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _save({required bool applyToDog}) async {
    final timings = _timer.timingsNow(widget.dogId);
    if (timings.isEmpty) {
      showSnack(context, 'No time recorded yet.', isError: true);
      return;
    }
    setState(() => _busy = true);

    try {
      final session = await _data.createGroomSession(
        dogId: widget.dogId,
        appointmentId: _session?.appointmentId,
        timings: timings,
      );
      if (applyToDog) {
        await _data.applySessionToDog(session.id);
      }
      await _timer.clearSession(widget.dogId);
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
          '${models.formatClock(_totalSeconds)} recorded for ${widget.dogName}, '
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
    await _timer.clearSession(widget.dogId);
    if (mounted) Navigator.of(context).pop();
  }

  /// Swap the screen over to another dog already on the clock — one tap, and
  /// this dog's phases keep doing whatever they were doing.
  void _switchTo(GroomTimerSession other) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => GroomTimerScreen(
          dogId: other.dogId,
          dogName: other.dogName,
          usualMinutes: other.usualMinutes,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Timing ${widget.dogName}')),
      body: ListenableBuilder(
        listenable: _timer,
        builder: (context, _) {
          final totalMinutes = _totalMinutes;
          final leftRunning = _session?.leftRunningPhase;
          final others = [
            for (final session in _timer.liveSessions)
              if (session.dogId != widget.dogId) session,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 20),
                color: context.mojo.tintWash,
                alignment: Alignment.center,
                child: Column(
                  children: [
                    Text(models.formatClock(_totalSeconds), style: AppColors.display(44)),
                    const SizedBox(height: 4),
                    Text(
                      'Usual: ${models.formatDuration(widget.usualMinutes)}',
                      style: TextStyle(fontSize: 12, color: context.mojo.muted),
                    ),
                  ],
                ),
              ),
              // The other dogs on the clock right now. This is the shared
              // visit Jess described — bath one, crate-dry it, bath the next
              // — so the switch is one tap and nothing pauses on the way.
              if (others.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final other in others)
                        ActionChip(
                          avatar: Icon(
                            other.isRunning ? Icons.timer : Icons.pause_circle_outline,
                            size: 17,
                          ),
                          label: Text(
                            '${other.dogName} · ${models.formatClock(other.totalSeconds)}'
                            '${other.isRunning ? '' : ' — paused'}',
                          ),
                          onPressed: () => _switchTo(other),
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
                      '${models.formatClock(_session?.secondsFor(leftRunning) ?? 0)}. '
                      'If it was left on, pause it and type the real time in.',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.warning),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Tap a phase to start or pause it. Skip any you did not do. '
                  'The clock keeps going if you leave this screen — and another '
                  "dog's timer keeps counting while you work on this one.",
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
              // Careful wording: not "nails, ears, health check" — Jess does
              // those inside the prep and health-check parts of the groom, so
              // the timer does see them. What the phases genuinely never
              // cover is the handover at both ends and anything off the clock.
              Text(
                _bookingBuffer == null
                    // Said plainly rather than silently booking the raw timing.
                    // Nothing is added until Jess sets a figure.
                    ? "Setting the default changes how much diary time this dog's "
                        'future bookings block out. It will use the '
                        '${models.formatDuration(totalMinutes)} timed here — if the '
                        'booking needs more for drop-off, collection and anything '
                        'done off the clock, set "Add to a timed groom" in Settings.'
                    : "Setting the default changes how much diary time this dog's "
                        'future bookings block out: '
                        '${models.formatDuration(totalMinutes)} timed + '
                        '${models.formatDuration(_bookingBuffer!)} for what happens '
                        'off the clock = '
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
    final seconds = _session?.secondsFor(phase) ?? 0;
    final isRunning = _session?.runningPhase == phase;
    final used = seconds > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _timer.toggle(widget.dogId, phase),
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
        subtitle: (_session?.wasEnteredManually(phase) ?? false)
            ? const Text('Entered by hand')
            : null,
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
