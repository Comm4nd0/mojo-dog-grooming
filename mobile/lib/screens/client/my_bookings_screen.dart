import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// A client's own bookings — read-only, plus the ability to request one.
///
/// Requests land as REQUESTED for Jess to confirm; only she can actually book,
/// move or cancel.
class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  final _data = getIt<DataService>();

  List<Appointment> _appointments = const [];
  bool _loading = true;
  Object? _error;

  /// Opening hours and closure days, for the out-of-hours note on a request.
  /// Null until fetched; a failed fetch just means the sheet doesn't warn —
  /// the server still shows Jess the same thing when she reviews it.
  Map<int, (int, int)>? _hours;
  Set<DateTime>? _closures;

  /// Time Jess has blocked out. Unlike the hours, this one *does* stop a
  /// request: the server refuses it, and the sheet says so first rather
  /// than letting it be sent and bounced. Fetched for a year ahead, which
  /// is as far as the date picker goes. Null until fetched; a failed fetch
  /// leaves the server as the only check, which is still a check.
  List<BlockedTime>? _blocks;

  Future<void> _loadHoursIfNeeded() async {
    if (_hours == null || _closures == null) {
      try {
        _hours = await _data.getOpeningHoursByWeekday();
        _closures = await _data.getClosureDates();
      } catch (_) {
        // Advisory only. Nothing here blocks a request.
      }
    }
    if (_blocks == null) {
      try {
        _blocks = await _data.getBlockedTimes(
          from: DateTime.now(),
          to: DateTime.now().add(const Duration(days: 366)),
        );
      } catch (_) {
        // The server still refuses; the sheet just cannot warn first.
      }
    }
  }

  /// Whether [when] is inside time Jess has blocked out.
  ///
  /// Checks the start only: the length of the slot is the server's to
  /// resolve (breed, services), and it checks the whole span. This is the
  /// early answer, not the last word.
  bool _isBlocked(DateTime when) =>
      _blocks?.any((block) => block.covers(when)) ?? false;

  /// The one message in this flow that is not "ask anyway".
  static const _blockedMessage =
      'That time is not available. Please choose another.';

  /// Whether [when] falls outside normal grooming hours.
  ///
  /// Jess: *"if it's 'out of hours' can it come up with a message letting
  /// them know"*. False when the hours are unknown or none are set up at all
  /// — a salon with no hours configured must not tell every client their
  /// request is out of hours.
  bool _isOutOfHours(DateTime when) {
    final hours = _hours;
    final closures = _closures;
    if (hours == null || closures == null || hours.isEmpty) return false;
    if (closures.contains(DateTime.utc(when.year, when.month, when.day))) {
      return true;
    }
    final day = hours[when.weekday];
    if (day == null) return true;
    final minutes = when.hour * 60 + when.minute;
    return minutes < day.$1 || minutes >= day.$2;
  }

  /// Her wording, near enough: it warns, it never stops the request going in.
  static const _outOfHoursMessage =
      'Please note this is out of normal hours for grooming — '
      'it is likely to be moved or turned down.';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final appointments = await _data.getAppointments(
        from: DateTime.now().subtract(const Duration(days: 180)),
        to: DateTime.now().add(const Duration(days: 365)),
      );
      if (!mounted) return;
      setState(() {
        _appointments = appointments;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<Appointment> get _upcoming {
    final now = DateTime.now();
    return _appointments.where((a) => a.startAt.isAfter(now) && !a.isCancelled).toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
  }

  List<Appointment> get _past {
    final now = DateTime.now();
    return _appointments.where((a) => !a.startAt.isAfter(now) || a.isCancelled).toList()
      ..sort((a, b) => b.startAt.compareTo(a.startAt));
  }

  Future<void> _request() async {
    final dogs = await _data.getDogs();
    await _loadHoursIfNeeded();
    if (!mounted) return;
    if (dogs.isEmpty) {
      showSnack(context, 'No dogs on your account yet.', isError: true);
      return;
    }

    int dogId = dogs.first.id;
    DateTime date = DateTime.now().add(const Duration(days: 7));
    TimeOfDay time = const TimeOfDay(hour: 10, minute: 0);
    final notes = TextEditingController();

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Request an appointment',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                'Mojo and Co will confirm a time with you.',
                style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: dogId,
                decoration: const InputDecoration(labelText: 'Dog'),
                items: [
                  for (final dog in dogs)
                    DropdownMenuItem(value: dog.id, child: Text(dog.name)),
                ],
                onChanged: (value) => setSheetState(() => dogId = value ?? dogId),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(const Duration(days: 365)),
                        );
                        if (picked != null) setSheetState(() => date = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'Preferred date'),
                        child: Text(formatDate(date)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: time,
                          initialEntryMode: TimePickerEntryMode.input,
                        );
                        if (picked != null) setSheetState(() => time = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'Preferred time'),
                        child: Text(time.format(context)),
                      ),
                    ),
                  ),
                ],
              ),
              if (_isBlocked(DateTime(
                date.year, date.month, date.day, time.hour, time.minute,
              )))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    color: AppColors.error.withValues(alpha: 0.10),
                    child: const Text(
                      _blockedMessage,
                      style: TextStyle(fontSize: 12.5, color: AppColors.error),
                    ),
                  ),
                )
              else if (_isOutOfHours(DateTime(
                date.year, date.month, date.day, time.hour, time.minute,
              )))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    color: AppColors.warning.withValues(alpha: 0.12),
                    child: const Text(
                      _outOfHoursMessage,
                      style: TextStyle(fontSize: 12.5, color: AppColors.warning),
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Anything to mention?'),
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                // Disabled, not hidden, for a blocked time: the button still
                // says what the sheet is for, and the box above says why it
                // cannot be pressed yet.
                onPressed: _isBlocked(DateTime(
                  date.year, date.month, date.day, time.hour, time.minute,
                ))
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('SEND REQUEST'),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await _data.createAppointment(
          dogId: dogId,
          startAt: DateTime(date.year, date.month, date.day, time.hour, time.minute),
          notes: notes.text.trim(),
        );
        if (!mounted) return;
        showSnack(context, 'Request sent. Mojo and Co will be in touch.');
        _load();
      } catch (error) {
        if (mounted) showSnack(context, error.toString(), isError: true);
      }
    }
    notes.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My bookings')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _request,
        icon: const Icon(Icons.add),
        label: const Text('REQUEST'),
      ),
      body: PageBody(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      const SectionHeader(title: 'Upcoming'),
                      if (_upcoming.isEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Text(
                            'Nothing booked in.',
                            style: TextStyle(color: context.mojo.muted, fontSize: 13),
                          ),
                        )
                      else
                        for (final appointment in _upcoming) _row(appointment),
                      if (_past.isNotEmpty) ...[
                        const SectionHeader(title: 'Past'),
                        for (final appointment in _past.take(20)) _row(appointment, past: true),
                      ],
                    ],
                  ),
                )),
    );
  }

  /// Whether this booking can still be asked about.
  ///
  /// Mirrors what the server will accept, so the sheet is never offered for a
  /// request that is about to be refused. The server is still the authority —
  /// this only keeps the UI honest.
  bool _canAskAbout(Appointment appointment) =>
      appointment.startAt.isAfter(DateTime.now()) &&
      !appointment.isCancelled &&
      appointment.status != 'COMPLETED';

  Future<void> _askAbout(Appointment appointment) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                '${appointment.dogName} — ${formatDate(appointment.startAt)}',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'We will confirm before anything changes.',
                style: TextStyle(fontSize: 12.5, color: sheetContext.mojo.muted),
              ),
            ),
            ListTile(
              leading: Icon(Icons.edit_calendar_outlined, color: sheetContext.mojo.accent),
              title: const Text('Ask to move it'),
              subtitle: const Text('Suggest another day or time'),
              onTap: () => Navigator.pop(sheetContext, 'RESCHEDULE'),
            ),
            ListTile(
              leading: const Icon(Icons.event_busy_outlined, color: AppColors.error),
              title: const Text('Ask to cancel it'),
              onTap: () => Navigator.pop(sheetContext, 'CANCEL'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;
    if (choice == 'CANCEL') {
      await _sendCancellation(appointment);
    } else {
      await _sendReschedule(appointment);
    }
  }

  Future<void> _sendCancellation(Appointment appointment) async {
    final note = await promptForText(
      context,
      title: 'Ask to cancel',
      labelText: 'Anything you would like us to know?',
      helperText: 'Optional',
      confirmLabel: 'SEND REQUEST',
    );
    if (note == null || !mounted) return;
    await _send(appointmentId: appointment.id, kind: 'CANCEL', note: note);
  }

  Future<void> _sendReschedule(Appointment appointment) async {
    final date = await showDatePicker(
      context: context,
      initialDate: appointment.startAt.add(const Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'When would suit instead?',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(appointment.startAt),
      initialEntryMode: TimePickerEntryMode.input,
    );
    if (time == null || !mounted) return;

    await _loadHoursIfNeeded();
    if (!mounted) return;
    final preferred =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (_isBlocked(preferred)) {
      // A refusal — the one in this flow. No "ask anyway": the server would
      // turn it down, and offering the button would be offering nothing.
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Not available'),
          content: const Text(_blockedMessage),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('PICK ANOTHER TIME'),
            ),
          ],
        ),
      );
      return;
    }
    if (_isOutOfHours(preferred)) {
      // A message, not a refusal — same rule as every warning in the diary.
      final goOn = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Out of normal hours'),
          content: const Text(_outOfHoursMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('GO BACK'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('ASK ANYWAY'),
            ),
          ],
        ),
      );
      if (goOn != true || !mounted) return;
    }

    final note = await promptForText(
      context,
      title: 'Ask to move it',
      labelText: 'Anything you would like us to know?',
      helperText: 'Optional',
      confirmLabel: 'SEND REQUEST',
    );
    if (note == null || !mounted) return;

    await _send(
      appointmentId: appointment.id,
      kind: 'RESCHEDULE',
      preferredStartAt: preferred,
      note: note,
    );
  }

  Future<void> _send({
    required int appointmentId,
    required String kind,
    DateTime? preferredStartAt,
    String note = '',
  }) async {
    try {
      await _data.requestAppointmentChange(
        appointmentId: appointmentId,
        kind: kind,
        preferredStartAt: preferredStartAt,
        note: note,
      );
      if (!mounted) return;
      // Deliberately not "cancelled" or "moved": nothing has changed yet, and
      // saying otherwise would have people not turning up.
      showSnack(context, 'Request sent. Mojo and Co will confirm with you.');
      await _load();
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    }
  }

  Widget _row(Appointment appointment, {bool past = false}) {
    final askable = !past && _canAskAbout(appointment);

    return ListTile(
      leading: Icon(
        appointment.status == 'REQUESTED' ? Icons.hourglass_empty : Icons.event,
        color: past ? context.mojo.muted : context.mojo.accent,
      ),
      title: Text(
        appointment.dogName,
        style: TextStyle(
          decoration: appointment.isCancelled ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Text(
        '${formatDate(appointment.startAt)} · ${appointment.timeRange}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (appointment.status != 'BOOKED')
            InfoTag(
              label: appointment.statusLabel,
              color: switch (appointment.status) {
                'REQUESTED' => AppColors.warning,
                'CONFIRMED' => AppColors.success,
                'CANCELLED' || 'NO_SHOW' => AppColors.error,
                _ => context.mojo.muted,
              },
            ),
          if (askable)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'Change this booking',
              onPressed: () => _askAbout(appointment),
            ),
        ],
      ),
      onTap: askable ? () => _askAbout(appointment) : null,
    );
  }
}
