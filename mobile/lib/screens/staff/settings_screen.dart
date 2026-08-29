import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import 'services_screen.dart';

/// Business settings: client-facing invoicing, temperament limits, hours.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _data = getIt<DataService>();
  final _api = getIt<ApiClient>();

  AppSettings? _settings;
  List<TemperamentGrade> _grades = const [];
  List<Map<String, dynamic>> _hours = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final settings = await _data.getSettings();
      final grades = await _data.getTemperamentGrades();
      final hours = ApiClient.resultsOf(await _api.get('/opening-hours/'));
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _grades = grades;
        _hours = hours;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: PageBody(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.only(bottom: 40),
                  children: [
                    const SectionHeader(title: 'Clients'),
                    SwitchListTile(
                      value: _settings!.invoicingVisibleToClients,
                      onChanged: (value) async {
                        await _data.updateSettings({'invoicing_visible_to_clients': value});
                        _load();
                      },
                      title: const Text('Show invoices to clients'),
                      subtitle: const Text(
                        'Off by default. When on, each client sees only their own invoices.',
                      ),
                    ),

                    const SectionHeader(title: 'How dogs handle'),
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'Five grades, easiest first. Call them whatever you '
                        'like — tap one to rename it or set how many of that '
                        'kind you will take in a day. Going over the number '
                        'only warns you; it never stops the booking.',
                        style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
                      ),
                    ),
                    for (final grade in _grades)
                      ListTile(
                        leading: TemperamentChip(
                          temperament: grade.code,
                          label: grade.label,
                        ),
                        title: Text(grade.capLabel),
                        trailing: const Icon(Icons.edit_outlined, size: 18),
                        onTap: () => _editGrade(grade),
                      ),

                    const SectionHeader(title: 'Gaps between bookings'),
                    ListTile(
                      dense: true,
                      title: const Text('Leave a gap either side'),
                      subtitle: const Text(
                        'Used when the app suggests the next free slot',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _settings!.bookingSlotBufferMinutes == 0
                                ? 'None'
                                : formatDuration(_settings!.bookingSlotBufferMinutes),
                            style: TextStyle(color: context.mojo.muted),
                          ),
                          const SizedBox(width: 10),
                          const Icon(Icons.edit_outlined, size: 18),
                        ],
                      ),
                      onTap: _editBuffer,
                    ),

                    const SectionHeader(title: 'Groom times'),
                    ListTile(
                      dense: true,
                      title: const Text('Add to a timed groom'),
                      // Not "nails, ears, the health check" — Jess does those
                      // inside the prep and health-check phases, so the timer
                      // does see them. What it genuinely never counts is the
                      // handover at both ends and anything done off the clock.
                      subtitle: const Text(
                        'What the phases never cover — drop-off, collection '
                        'and anything done off the clock',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            // "Not set" rather than "None": nothing has been
                            // guessed, and the two are different statements.
                            _settings!.groomTimeBufferMinutes == null
                                ? 'Not set'
                                : formatDuration(_settings!.groomTimeBufferMinutes!),
                            style: TextStyle(color: context.mojo.muted),
                          ),
                          const SizedBox(width: 10),
                          const Icon(Icons.edit_outlined, size: 18),
                        ],
                      ),
                      onTap: _editGroomTimeBuffer,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'A groom timed at 55 minutes is not a 55-minute slot. This is '
                        'the difference, and it is added whenever a timed groom sets a '
                        "dog's booking length. Blank adds nothing.",
                        style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
                      ),
                    ),

                    // "Nails, fleas and ticks" used to sit here as well, asking
                    // how long to block out and what it costs. It is the same
                    // question the Services screen asks per service, so having
                    // both meant two places to set one thing and no way to tell
                    // which one a booking had used. It now lives only in
                    // Services, at the foot, where the nails services are.

                    const SectionHeader(title: 'Opening hours'),
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'You can still book outside these — the app just warns you.',
                        style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
                      ),
                    ),
                    for (final day in _hours)
                      ListTile(
                        dense: true,
                        title: Text(day['weekday_display']?.toString() ?? ''),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _hoursLabel(day),
                              style: TextStyle(color: context.mojo.muted),
                            ),
                            const SizedBox(width: 10),
                            const Icon(Icons.edit_outlined, size: 18),
                          ],
                        ),
                        onTap: () => _editHours(day),
                      ),

                    const SectionHeader(title: 'Services'),
                    ListTile(
                      leading: Icon(Icons.content_cut_outlined, color: context.mojo.accent),
                      title: const Text('What you do, and what it costs'),
                      subtitle: const Text(
                        'Full groom, nail clipping, hand stripping and the rest',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ServicesScreen()),
                      ),
                    ),

                    // Medical notes and the breed standards used to close this
                    // screen out under "Reference" and "Breeds". They are under
                    // More → Medical and Breed Standards now, at Jess's request
                    // — neither is a setting.
                  ],
                )),
    );
  }

  static String _shortTime(dynamic value) =>
      value == null ? '' : value.toString().substring(0, 5);

  static String _hoursLabel(Map<String, dynamic> day) =>
      day['is_closed'] == true || day['open_time'] == null
          ? 'Closed'
          : '${_shortTime(day['open_time'])} – ${_shortTime(day['close_time'])}';

  /// "09:00:00" (the API's format) or "09:00" into a TimeOfDay. Null for a day
  /// that has never had hours set.
  static TimeOfDay? _parseTime(dynamic value) {
    if (value == null) return null;
    final parts = value.toString().split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  static String _apiTime(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  static int _minutes(TimeOfDay time) => time.hour * 60 + time.minute;

  Future<void> _editHours(Map<String, dynamic> day) async {
    // A day that has never been set opens on a plain 9–5 rather than empty
    // fields, so setting one is two taps rather than four.
    var isOpen = day['is_closed'] != true && day['open_time'] != null;
    var open = _parseTime(day['open_time']) ?? const TimeOfDay(hour: 9, minute: 0);
    var close = _parseTime(day['close_time']) ?? const TimeOfDay(hour: 17, minute: 0);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Open and close are times on one day, so closing at or before
          // opening is a typo rather than an overnight shift.
          final invalid = isOpen && _minutes(close) <= _minutes(open);

          Future<void> pick({required bool opening}) async {
            final picked = await showTimePicker(
              context: context,
              initialTime: opening ? open : close,
              // Typing 09:00 beats dialling it. The clock face is still one
              // tap away, same as on the booking form.
              initialEntryMode: TimePickerEntryMode.input,
            );
            if (picked == null) return;
            setDialogState(() {
              if (opening) {
                open = picked;
              } else {
                close = picked;
              }
            });
          }

          return AlertDialog(
            title: Text(day['weekday_display']?.toString() ?? 'Opening hours'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isOpen,
                  onChanged: (value) => setDialogState(() => isOpen = value),
                  title: Text(isOpen ? 'Open this day' : 'Closed this day'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: isOpen,
                  title: const Text('Opens'),
                  trailing: Text(_apiTime(open)),
                  onTap: isOpen ? () => pick(opening: true) : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: isOpen,
                  title: const Text('Closes'),
                  trailing: Text(_apiTime(close)),
                  onTap: isOpen ? () => pick(opening: false) : null,
                ),
                if (invalid)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Closing time must be after opening time.',
                      style: TextStyle(color: AppColors.error, fontSize: 12.5),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('CANCEL'),
              ),
              ElevatedButton(
                onPressed: invalid ? null : () => Navigator.pop(context, true),
                child: const Text('SAVE'),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true) return;

    // The times go up even when the day is closed, so re-opening it restores
    // what was there rather than snapping back to the 9–5 default. Both the
    // list above and opening_hours_warning() on the server read is_closed
    // first, so the kept times stay invisible until the day reopens.
    await _api.patch('/opening-hours/${day['id']}/', {
      'is_closed': !isOpen,
      'open_time': _apiTime(open),
      'close_time': _apiTime(close),
    });
    _load();
  }

  /// Rename a grade, or change how many of them Jess will take in a day.
  ///
  /// The five names shipped are our reading of a one-line note from her, so
  /// renaming has to be hers to do. Only the label and the cap are editable —
  /// the code underneath is what every dog stores, and repointing it would
  /// silently regrade a dog.
  /// The gap either side of a booking when hunting for a free slot.
  ///
  /// This setting has existed since the first version and until now was read
  /// by nothing at all — there was no screen for it and no code that used it.
  /// It drives "next available" now, which is why it finally has one.
  Future<void> _editBuffer() async {
    final result = await promptForText(
      context,
      title: 'Gap between bookings',
      initialValue: _settings!.bookingSlotBufferMinutes == 0
          ? ''
          : _settings!.bookingSlotBufferMinutes.toString(),
      labelText: 'Minutes',
      helperText: 'Leave blank for none — time to clean up between dogs',
      keyboardType: TextInputType.number,
    );
    if (result == null) return;
    await _data.updateSettings({
      'booking_slot_buffer_minutes': result.isEmpty ? 0 : int.tryParse(result) ?? 0,
    });
    _load();
  }

  /// What to add to a timed groom to get how long to book.
  ///
  /// Jess: the groom time is *"nowhere near the appointment time (which would
  /// be how long to book them in for)"*. It never could be — the timer counts
  /// five phases and a visit is more than five phases. This is the distance,
  /// and it is hers to measure: blank stays blank, and nothing is guessed.
  ///
  /// Changing it re-derives every dog's average groom time on the server,
  /// because those are stored with the buffer already in them.
  Future<void> _editGroomTimeBuffer() async {
    final result = await promptForText(
      context,
      title: 'Add to a timed groom',
      initialValue: _settings!.groomTimeBufferMinutes?.toString() ?? '',
      labelText: 'Minutes',
      helperText: 'Leave blank to book exactly what the timer measured',
      keyboardType: TextInputType.number,
    );
    if (result == null) return;
    await _data.updateSettings({
      'groom_time_buffer_minutes': result.trim().isEmpty ? null : int.tryParse(result.trim()),
    });
    _load();
  }

  Future<void> _editGrade(TemperamentGrade grade) async {
    final label = TextEditingController(text: grade.label);
    final cap = TextEditingController(text: grade.maxPerDay?.toString() ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(grade.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MojoTextField(
              controller: label,
              decoration: const InputDecoration(
                labelText: 'What you call it',
                helperText: 'Shown on every dog and booking',
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            MojoTextField(
              controller: cap,
              decoration: const InputDecoration(
                labelText: 'Maximum per day',
                helperText: 'Leave blank for no limit',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );

    if (saved == true) {
      final trimmedCap = cap.text.trim();
      try {
        await _data.updateTemperamentGrade(grade.id, {
          'label': label.text.trim(),
          'max_per_day': trimmedCap.isEmpty ? null : int.tryParse(trimmedCap),
        });
      } catch (error) {
        if (mounted) showSnack(context, error.toString(), isError: true);
      }
      _load();
    }
    label.dispose();
    cap.dispose();
  }
}
