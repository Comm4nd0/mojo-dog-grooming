import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/duration_picker.dart';

/// What Jess does, and what she charges for it.
///
/// Everything except Full Groom ships with **no price and no length**. Her
/// price list of 28 July covers full grooms only, so there is no figure
/// anywhere for the other twelve — and an invented one is indistinguishable
/// from a real one once it is in the database. This screen is where she fills
/// them in; until she does, a booking carrying an unpriced service quotes
/// nothing and the booking check says which one.
class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key});

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  final _data = getIt<DataService>();

  List<ServiceItem> _services = const [];
  AppSettings? _settings;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final services = await _data.getServices();
      final settings = await _data.getSettings();
      if (!mounted) return;
      setState(() {
        _services = services;
        _settings = settings;
        _loading = false;
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
    final unpriced = _services.where((s) => !s.isPriced).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Services')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _services.isEmpty
              ? ErrorRetry(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          unpriced == 0
                              ? 'Everything has a price. Tap one to change it.'
                              : "$unpriced ${unpriced == 1 ? 'service has' : 'services have'} "
                                  'no price yet. Your price list only covered full '
                                  'grooms, so nothing has been guessed — a booking '
                                  'with one of these on it just stays unquoted until '
                                  'you fill it in.',
                          style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
                        ),
                      ),
                      for (final service in _services)
                        ListTile(
                          title: Text(service.name),
                          subtitle: Text(service.summary),
                          trailing: service.isPriced
                              ? const Icon(Icons.edit_outlined, size: 18)
                              : Icon(Icons.error_outline,
                                  size: 18, color: AppColors.warning),
                          onTap: () => _edit(service),
                        ),
                      if (_settings != null) ..._nailFallback(),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
    );
  }

  /// The figures a nails booking falls back on when **no service is ticked**.
  ///
  /// These used to be a "Nails, fleas and ticks" section at the top level of
  /// Settings, which read as a second answer to the question this whole screen
  /// asks — two places to set one thing, and no way to tell which a booking had
  /// used. They belong here, next to Nail Clipping and Tick / Flea Removal.
  ///
  /// Not merged into those rows, though, and not deleted: a nails appointment
  /// with no services on it resolves from these and only these. That is the
  /// compatibility guarantee that let the service catalogue ship ahead of the
  /// app build — a booking made before services existed still resolves
  /// identically — and there is a test on it in `resolve_slot`.
  List<Widget> _nailFallback() {
    final settings = _settings!;
    return [
      const Divider(height: 32),
      const SectionHeader(title: 'When no service is ticked'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'A nails, fleas or ticks booking with nothing ticked above falls back '
          'to these. Your price list covers grooms only, so nothing is set until '
          'you set it — the booking still goes through either way.',
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
              settings.nailVisitMinutes == null
                  ? 'Not set'
                  : formatDuration(settings.nailVisitMinutes!),
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
              settings.nailVisitPrice == null
                  ? 'Not set'
                  : formatMoney(settings.nailVisitPrice!),
              style: TextStyle(color: context.mojo.muted),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.edit_outlined, size: 18),
          ],
        ),
        onTap: _editNailPrice,
      ),
    ];
  }

  Future<void> _editNailMinutes() async {
    final result = await promptForText(
      context,
      title: 'When no service is ticked',
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
      title: 'When no service is ticked',
      initialValue: _settings!.nailVisitPrice?.toString() ?? '',
      labelText: 'Price',
      helperText: 'Leave blank if you have not decided yet',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    if (result == null) return;
    final price = double.tryParse(result.trim());
    if (result.trim().isNotEmpty && (price == null || price < 0)) return;
    await _data.updateSettings({'nail_visit_price': price?.toStringAsFixed(2)});
    _load();
  }

  Future<void> _edit(ServiceItem service) async {
    if (service.takesDogDefaults) {
      // Full Groom is priced off the dog, i.e. off the breed grid. Letting a
      // figure be typed here would create a second, silently-losing answer.
      showSnack(
        context,
        '${service.name} uses each dog\'s own time and price — change those on '
        'the dog, or in Settings, Breeds.',
      );
      return;
    }

    final price = TextEditingController(text: service.price?.toString() ?? '');
    var minutes = service.minutes;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(service.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MojoTextField(
                controller: price,
                decoration: const InputDecoration(
                  labelText: 'Price (£)',
                  helperText: 'Leave blank if you have not decided',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () async {
                  final picked = await showDurationPicker(
                    dialogContext,
                    initialMinutes: minutes ?? 30,
                    title: 'How long does ${service.name} take?',
                  );
                  if (picked != null) setDialogState(() => minutes = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'How long it takes'),
                  child: Text(minutes == null ? 'Not set' : formatDuration(minutes!)),
                ),
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
      ),
    );

    if (saved == true) {
      final typed = price.text.trim();
      try {
        await _data.updateService(service.id, {
          // Explicit null, so clearing a price actually clears it rather than
          // leaving the old figure behind.
          'default_price': typed.isEmpty ? null : typed,
          'default_minutes': minutes,
        });
      } catch (error) {
        if (mounted) showSnack(context, error.toString(), isError: true);
      }
      _load();
    }
    price.dispose();
  }
}
