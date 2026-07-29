import 'dart:async';

import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart' as models;
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Time a groom phase by phase.
///
/// Not every groom uses every phase — a wash and blow-dry records no clip or
/// strip — so each timer is independent and a phase with no time simply isn't
/// saved. Any phase can also be typed in, for a groom that wasn't timed live.
///
/// The total can be written back to the dog as its default groom time, which
/// then sizes the diary block for future bookings.
class GroomTimerScreen extends StatefulWidget {
  const GroomTimerScreen({super.key, required this.dog, this.appointmentId});

  final models.Dog dog;
  final int? appointmentId;

  @override
  State<GroomTimerScreen> createState() => _GroomTimerScreenState();
}

class _GroomTimerScreenState extends State<GroomTimerScreen> {
  final _data = getIt<DataService>();

  /// Accumulated seconds per phase.
  final Map<String, int> _elapsed = {
    for (final phase in models.PhaseTiming.phaseOrder) phase: 0,
  };
  final Set<String> _manual = {};

  String? _running;
  DateTime? _runningSince;
  Timer? _ticker;
  bool _busy = false;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  int _displaySeconds(String phase) {
    final base = _elapsed[phase] ?? 0;
    if (_running != phase || _runningSince == null) return base;
    return base + DateTime.now().difference(_runningSince!).inSeconds;
  }

  void _toggle(String phase) {
    setState(() {
      if (_running == phase) {
        _bankRunning();
        return;
      }
      // Only one phase runs at a time — starting another banks the current one.
      if (_running != null) _bankRunning();
      _running = phase;
      _runningSince = DateTime.now();
      _manual.remove(phase);
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    });
  }

  void _bankRunning() {
    final phase = _running;
    if (phase == null || _runningSince == null) return;
    _elapsed[phase] =
        (_elapsed[phase] ?? 0) + DateTime.now().difference(_runningSince!).inSeconds;
    _running = null;
    _runningSince = null;
    _ticker?.cancel();
  }

  Future<void> _editManually(String phase) async {
    final entered = await promptForText(
      context,
      title: '${models.PhaseTiming.labelFor(phase)} — enter minutes',
      initialValue: ((_elapsed[phase] ?? 0) ~/ 60).toString(),
      suffixText: 'minutes',
      keyboardType: TextInputType.number,
      confirmLabel: 'SET',
    );
    if (entered == null) return;
    final minutes = int.tryParse(entered) ?? 0;
    setState(() {
      if (_running == phase) _bankRunning();
      _elapsed[phase] = minutes * 60;
      if (minutes > 0) {
        _manual.add(phase);
      } else {
        _manual.remove(phase);
      }
    });
  }

  int get _totalSeconds => models.PhaseTiming.phaseOrder
      .fold(0, (sum, phase) => sum + _displaySeconds(phase));

  Future<void> _save({required bool applyToDog}) async {
    setState(() {
      _bankRunning();
      _busy = true;
    });

    // Only phases that were actually used get recorded.
    final timings = [
      for (final phase in models.PhaseTiming.phaseOrder)
        if ((_elapsed[phase] ?? 0) > 0)
          models.PhaseTiming(
            phase: phase,
            durationSeconds: _elapsed[phase]!,
            enteredManually: _manual.contains(phase),
          ),
    ];

    if (timings.isEmpty) {
      setState(() => _busy = false);
      showSnack(context, 'No time recorded yet.', isError: true);
      return;
    }

    try {
      final session = await _data.createGroomSession(
        dogId: widget.dog.id,
        appointmentId: widget.appointmentId,
        timings: timings,
      );
      if (applyToDog) {
        await _data.applySessionToDog(session.id);
      }
      if (!mounted) return;
      showSnack(
        context,
        applyToDog
            ? "Saved. ${widget.dog.name}'s groom time is now ${models.formatDuration(session.totalMinutes)}."
            : 'Groom session saved.',
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalMinutes = (_totalSeconds / 60).round();
    return Scaffold(
      appBar: AppBar(title: Text('Timing ${widget.dog.name}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            color: context.mojo.tintWash,
            alignment: Alignment.center,
            child: Column(
              children: [
                Text(_formatClock(_totalSeconds), style: AppColors.display(44)),
                const SizedBox(height: 4),
                Text(
                  'Usual: ${models.formatDuration(widget.dog.groomMinutes)}',
                  style: TextStyle(fontSize: 12, color: context.mojo.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Tap a phase to start or pause it. Skip any you did not do.',
              style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
            ),
          ),
          for (final phase in models.PhaseTiming.phaseOrder) _phaseTile(phase),
          const SizedBox(height: 28),
          ElevatedButton(
            onPressed: _busy || totalMinutes == 0 ? null : () => _save(applyToDog: true),
            child: Text(
              _busy ? 'SAVING…' : 'SAVE & SET AS DEFAULT (${models.formatDuration(totalMinutes)})',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _busy || totalMinutes == 0 ? null : () => _save(applyToDog: false),
            child: const Text('SAVE WITHOUT CHANGING DEFAULT'),
          ),
          const SizedBox(height: 12),
          Text(
            "Setting the default changes how much diary time this dog's future "
            'bookings block out.',
            style: TextStyle(fontSize: 12, color: context.mojo.muted),
          ),
        ],
      ),
    );
  }

  Widget _phaseTile(String phase) {
    final seconds = _displaySeconds(phase);
    final isRunning = _running == phase;
    final used = seconds > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _toggle(phase),
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
        subtitle: _manual.contains(phase) ? const Text('Entered by hand') : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _formatClock(seconds),
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

  static String _formatClock(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
