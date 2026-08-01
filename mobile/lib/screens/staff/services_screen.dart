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
      if (!mounted) return;
      setState(() {
        _services = services;
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
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
    );
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
