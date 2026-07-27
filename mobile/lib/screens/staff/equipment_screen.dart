import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// The equipment register: name, UID, last sharpened, PAT tested, notes.
class EquipmentScreen extends StatefulWidget {
  const EquipmentScreen({super.key});

  @override
  State<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends State<EquipmentScreen> {
  final _data = getIt<DataService>();
  List<Equipment> _items = const [];
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
      final items = await _data.getEquipment();
      if (!mounted) return;
      setState(() {
        _items = items;
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

  Future<void> _edit([Equipment? item]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EquipmentForm(item: item),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Equipment')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : _items.isEmpty
                  ? EmptyState(
                      icon: Icons.content_cut_outlined,
                      title: 'Nothing registered',
                      message: 'Add blades, clippers and dryers to track sharpening and PAT tests.',
                      action: ElevatedButton(
                        onPressed: () => _edit(),
                        child: const Text('ADD EQUIPMENT'),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return ListTile(
                          onTap: () => _edit(item),
                          title: Text(item.name),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.uid),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  InfoTag(
                                    label: item.lastSharpened == null
                                        ? 'Never sharpened'
                                        : 'Sharpened ${formatDate(item.lastSharpened!)}',
                                    icon: Icons.content_cut,
                                    color: item.lastSharpened == null
                                        ? AppColors.warning
                                        : AppColors.primary,
                                  ),
                                  InfoTag(
                                    label: item.patTested ? 'PAT tested' : 'Not PAT tested',
                                    icon: item.patTested ? Icons.verified_outlined : Icons.error_outline,
                                    color: item.patTested ? AppColors.success : AppColors.warning,
                                  ),
                                  if (!item.isActive)
                                    const InfoTag(label: 'Retired', color: AppColors.inkSecondary),
                                ],
                              ),
                            ],
                          ),
                          isThreeLine: true,
                          trailing: const Icon(Icons.chevron_right),
                        );
                      },
                    ),
    );
  }
}

class _EquipmentForm extends StatefulWidget {
  const _EquipmentForm({this.item});

  final Equipment? item;

  @override
  State<_EquipmentForm> createState() => _EquipmentFormState();
}

class _EquipmentFormState extends State<_EquipmentForm> {
  final _data = getIt<DataService>();
  late final TextEditingController _name;
  late final TextEditingController _uid;
  late final TextEditingController _notes;

  DateTime? _lastSharpened;
  DateTime? _patTestedDate;
  late bool _patTested;
  late bool _isActive;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _name = TextEditingController(text: item?.name ?? '');
    _uid = TextEditingController(text: item?.uid ?? '');
    _notes = TextEditingController(text: item?.notes ?? '');
    _lastSharpened = item?.lastSharpened;
    _patTestedDate = item?.patTestedDate;
    _patTested = item?.patTested ?? false;
    _isActive = item?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _uid.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _uid.text.trim().isEmpty) {
      showSnack(context, 'Name and UID are both needed.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _data.saveEquipment(Equipment(
        id: widget.item?.id ?? 0,
        name: _name.text.trim(),
        uid: _uid.text.trim(),
        lastSharpened: _lastSharpened,
        patTested: _patTested,
        patTestedDate: _patTestedDate,
        notes: _notes.text.trim(),
        isActive: _isActive,
      ));
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.item == null ? 'Add equipment' : 'Edit equipment',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name *'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _uid,
              decoration: const InputDecoration(
                labelText: 'UID *',
                helperText: 'Asset reference, e.g. BLADE-07',
              ),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 14),
            _dateField(
              label: 'Last sharpened',
              value: _lastSharpened,
              onPick: (value) => setState(() => _lastSharpened = value),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _patTested,
              onChanged: (value) => setState(() => _patTested = value),
              title: const Text('PAT tested'),
            ),
            if (_patTested)
              _dateField(
                label: 'PAT test date',
                value: _patTestedDate,
                onPick: (value) => setState(() => _patTestedDate = value),
              ),
            const SizedBox(height: 14),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes'),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isActive,
              onChanged: (value) => setState(() => _isActive = value),
              title: const Text('In use'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'SAVING…' : 'SAVE'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateField({
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime?> onPick,
  }) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2015),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: value == null
              ? const Icon(Icons.calendar_today_outlined, size: 18)
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => onPick(null),
                ),
        ),
        child: Text(value == null ? 'Not set' : formatDate(value)),
      ),
    );
  }
}
