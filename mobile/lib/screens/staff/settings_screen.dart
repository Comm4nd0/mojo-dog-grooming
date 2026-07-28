import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

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
  List<Map<String, dynamic>> _limits = const [];
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
      final limits = ApiClient.resultsOf(await _api.get('/temperament-limits/'));
      final hours = ApiClient.resultsOf(await _api.get('/opening-hours/'));
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _limits = limits;
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

                    const SectionHeader(title: 'Temperament limits'),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'How many of each type you will take in a day. Going over only '
                        'warns you — it never stops the booking.',
                        style: TextStyle(fontSize: 12.5, color: AppColors.inkSecondary),
                      ),
                    ),
                    for (final limit in _limits)
                      ListTile(
                        leading: TemperamentChip(
                          temperament: limit['temperament']?.toString(),
                          label: limit['temperament_display']?.toString(),
                        ),
                        title: Text(
                          limit['max_per_day'] == null
                              ? 'No limit'
                              : 'Max ${limit['max_per_day']} per day',
                        ),
                        trailing: const Icon(Icons.edit_outlined, size: 18),
                        onTap: () => _editLimit(limit),
                      ),

                    const SectionHeader(title: 'Opening hours'),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'You can still book outside these — the app just warns you.',
                        style: TextStyle(fontSize: 12.5, color: AppColors.inkSecondary),
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
                              style: const TextStyle(color: AppColors.inkSecondary),
                            ),
                            const SizedBox(width: 10),
                            const Icon(Icons.edit_outlined, size: 18),
                          ],
                        ),
                        onTap: () => _editHours(day),
                      ),

                    const SectionHeader(title: 'Breeds'),
                    ListTile(
                      leading: const Icon(Icons.list_alt_outlined, color: AppColors.primary),
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
                        'The seeded breed times, prices and intervals are general industry '
                        'estimates, not Mojo and Co figures. Worth going through them once '
                        'and setting your own.',
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

  Future<void> _editLimit(Map<String, dynamic> limit) async {
    final result = await promptForText(
      context,
      title: limit['temperament_display']?.toString() ?? 'Limit',
      initialValue: limit['max_per_day']?.toString() ?? '',
      labelText: 'Maximum per day',
      helperText: 'Leave blank for no limit',
      keyboardType: TextInputType.number,
    );
    if (result == null) return;

    await _api.patch('/temperament-limits/${limit['id']}/', {
      'max_per_day': result.isEmpty ? null : int.tryParse(result),
    });
    _load();
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
            TextField(
              controller: minutes,
              decoration: const InputDecoration(labelText: 'Groom time (minutes)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: price,
              decoration: const InputDecoration(labelText: 'Price (£)'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextField(
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
