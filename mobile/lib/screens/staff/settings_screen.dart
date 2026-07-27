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
                        trailing: Text(
                          day['is_closed'] == true || day['open_time'] == null
                              ? 'Closed'
                              : '${_shortTime(day['open_time'])} – ${_shortTime(day['close_time'])}',
                          style: const TextStyle(color: AppColors.inkSecondary),
                        ),
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

  Future<void> _editLimit(Map<String, dynamic> limit) async {
    final controller = TextEditingController(
      text: limit['max_per_day']?.toString() ?? '',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(limit['temperament_display']?.toString() ?? 'Limit'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Maximum per day',
            helperText: 'Leave blank for no limit',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
    controller.dispose();
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
