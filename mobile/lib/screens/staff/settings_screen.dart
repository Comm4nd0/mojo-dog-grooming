import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import 'services_screen.dart';

/// Business settings: client-facing invoicing, temperament limits, breeds.
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
      body: _loading
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

                    const SectionHeader(title: 'Nails, fleas and ticks'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        "These aren't in your price list — it covers grooms only — "
                        'so nothing is set until you set it. Bookings still go '
                        'through; the app just reminds you.',
                        style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
                      ),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text('How long to block out'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _settings!.nailVisitMinutes == null
                                ? 'Not set'
                                : formatDuration(_settings!.nailVisitMinutes!),
                            style: TextStyle(color: context.mojo.muted),
                          ),
                          const SizedBox(width: 10),
                          const Icon(Icons.edit_outlined, size: 18),
                        ],
                      ),
                      onTap: _editNailMinutes,
                    ),
                    ListTile(
                      dense: true,
                      title: const Text('What it costs'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _settings!.nailVisitPrice == null
                                ? 'Not set'
                                : formatMoney(_settings!.nailVisitPrice!),
                            style: TextStyle(color: context.mojo.muted),
                          ),
                          const SizedBox(width: 10),
                          const Icon(Icons.edit_outlined, size: 18),
                        ],
                      ),
                      onTap: _editNailPrice,
                    ),

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

                    const SectionHeader(title: 'Breeds'),
                    ListTile(
                      leading: Icon(Icons.list_alt_outlined, color: context.mojo.accent),
                      title: const Text('Breed times and prices'),
                      subtitle: const Text('Review the defaults new dogs inherit'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const _BreedListScreen()),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Times and prices come from your own price list. Which size and '
                        'coat band each breed was put in, and how often it needs doing, '
                        'are our guess — worth a look through.',
                        style: TextStyle(fontSize: 12, color: AppColors.warning),
                      ),
                    ),
                  ],
                ),
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

  Future<void> _editNailMinutes() async {
    final result = await promptForText(
      context,
      title: 'Nails, fleas and ticks',
      initialValue: _settings!.nailVisitMinutes?.toString() ?? '',
      labelText: 'Minutes to block out',
      helperText: 'Leave blank if you have not decided yet',
      keyboardType: TextInputType.number,
    );
    if (result == null) return;
    // Blank clears it back to "not set" rather than being ignored — she may
    // have entered a guess and want it gone again.
    final minutes = int.tryParse(result.trim());
    if (result.trim().isNotEmpty && (minutes == null || minutes <= 0)) return;
    await _data.updateSettings({'nail_visit_minutes': minutes});
    _load();
  }

  Future<void> _editNailPrice() async {
    final result = await promptForText(
      context,
      title: 'Nails, fleas and ticks',
      initialValue: _settings!.nailVisitPrice?.toString() ?? '',
      labelText: 'Price',
      helperText: 'Leave blank if you have not decided yet',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    if (result == null) return;
    final price = double.tryParse(result.trim());
    if (result.trim().isNotEmpty && (price == null || price < 0)) return;
    await _data.updateSettings({
      'nail_visit_price': price?.toStringAsFixed(2),
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

/// Breed reference table, editable in place.
class _BreedListScreen extends StatefulWidget {
  const _BreedListScreen();

  @override
  State<_BreedListScreen> createState() => _BreedListScreenState();
}

class _BreedListScreenState extends State<_BreedListScreen> {
  final _data = getIt<DataService>();
  List<Breed> _breeds = const [];
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final breeds = await _data.getBreeds();
    if (!mounted) return;
    setState(() {
      _breeds = breeds;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _breeds
        .where((b) => b.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Breeds')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Search breeds',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final breed = visible[index];
                      return ListTile(
                        title: Text(breed.name),
                        subtitle: Text(
                          '${formatDuration(breed.avgGroomMinutes)} · '
                          '${formatMoney(breed.avgPrice)} · '
                          'every ${breed.avgScheduleWeeks}w',
                        ),
                        trailing: const Icon(Icons.edit_outlined, size: 18),
                        onTap: () => _edit(breed),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(Breed breed) async {
    final minutes = TextEditingController(text: breed.avgGroomMinutes.toString());
    final price = TextEditingController(text: breed.avgPrice.toStringAsFixed(2));
    final weeks = TextEditingController(text: breed.avgScheduleWeeks.toString());

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(breed.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MojoTextField(
              controller: minutes,
              decoration: const InputDecoration(labelText: 'Groom time (minutes)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            MojoTextField(
              controller: price,
              decoration: const InputDecoration(labelText: 'Price (£)'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            MojoTextField(
              controller: weeks,
              decoration: const InputDecoration(labelText: 'Groom every (weeks)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('SAVE')),
        ],
      ),
    );

    if (saved == true) {
      await _data.updateBreed(breed.id, {
        'avg_groom_minutes': int.tryParse(minutes.text) ?? breed.avgGroomMinutes,
        'avg_price': price.text.trim(),
        'avg_schedule_weeks': int.tryParse(weeks.text) ?? breed.avgScheduleWeeks,
      });
      _load();
    }
    minutes.dispose();
    price.dispose();
    weeks.dispose();
  }
}
