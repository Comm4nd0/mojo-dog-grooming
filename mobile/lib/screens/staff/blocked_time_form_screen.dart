import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Block a stretch of the diary out, or change one already there.
///
/// A start and an end, each with its own date, so a lunch and a fortnight
/// away are the same form. The notes are Jess's own: a client sees that the
/// time is taken and nothing about why, and the form says so beside the box
/// so the boundary is on the screen rather than in her memory.
class BlockedTimeFormScreen extends StatefulWidget {
  const BlockedTimeFormScreen({super.key, this.block, this.initialStart});

  /// Editing this one. Null creates.
  final BlockedTime? block;

  /// Where the diary was when she tapped "block out time". A date with no
  /// time of its own starts the block at the top of the working morning.
  final DateTime? initialStart;

  @override
  State<BlockedTimeFormScreen> createState() => _BlockedTimeFormScreenState();
}

class _BlockedTimeFormScreenState extends State<BlockedTimeFormScreen> {
  final _data = getIt<DataService>();
  final _notes = TextEditingController();

  late DateTime _start;
  late DateTime _end;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.block;
    if (existing != null) {
      _start = existing.startAt;
      _end = existing.endAt;
      _notes.text = existing.notes ?? '';
    } else {
      final at = widget.initialStart ?? DateTime.now();
      // A bare date means "this day", not midnight: start where her morning
      // does. A date carrying a time — tapped on the axis — keeps it.
      final hasTime = at.hour != 0 || at.minute != 0;
      _start = DateTime(at.year, at.month, at.day, hasTime ? at.hour : 9, hasTime ? at.minute : 0);
      _end = _start.add(const Duration(hours: 1));
    }
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  bool get _editing => widget.block != null;

  bool get _valid => _end.isAfter(_start);

  Future<void> _pickDate({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final replaced = DateTime(picked.year, picked.month, picked.day, current.hour, current.minute);
      if (start) {
        // Keep the length when the start moves — the common edit is "same
        // lunch, different day", not "a lunch that now lasts a week".
        final length = _end.difference(_start);
        _start = replaced;
        _end = replaced.add(length);
      } else {
        _end = replaced;
      }
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      initialEntryMode: TimePickerEntryMode.input,
    );
    if (picked == null || !mounted) return;
    setState(() {
      final replaced = DateTime(current.year, current.month, current.day, picked.hour, picked.minute);
      if (start) {
        final length = _end.difference(_start);
        _start = replaced;
        _end = replaced.add(length);
      } else {
        _end = replaced;
      }
    });
  }

  /// The whole of the start's day, midnight to midnight.
  void _wholeDay() {
    setState(() {
      _start = DateTime(_start.year, _start.month, _start.day);
      _end = _start.add(const Duration(days: 1));
    });
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    setState(() => _saving = true);
    try {
      final existing = widget.block;
      if (existing == null) {
        await _data.createBlockedTime(
          startAt: _start,
          endAt: _end,
          notes: _notes.text.trim(),
        );
      } else {
        await _data.updateBlockedTime(existing.id, {
          'start_at': _start.toUtc().toIso8601String(),
          'end_at': _end.toUtc().toIso8601String(),
          'notes': _notes.text.trim(),
        });
      }
      if (!mounted) return;
      showSnack(context, _editing ? 'Block updated.' : 'Time blocked out.');
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  Future<void> _delete() async {
    final existing = widget.block;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unblock this time?'),
        content: const Text('Clients will be able to ask for it again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('KEEP IT'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('UNBLOCK', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _data.deleteBlockedTime(existing.id);
      if (!mounted) return;
      showSnack(context, 'Time unblocked.');
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sameDay = _start.year == _end.year &&
        _start.month == _end.month &&
        _start.day == _end.day;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Blocked out time' : 'Block out time'),
        actions: [
          if (_editing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Unblock',
              onPressed: _saving ? null : _delete,
            ),
        ],
      ),
      body: PageBody(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Nothing can be requested for this time. You can still book '
              'into it yourself — the diary will warn you.',
              style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
            ),
            const SectionHeader(title: 'From'),
            _whenRow(start: true),
            const SectionHeader(title: 'Until'),
            _whenRow(start: false),
            if (!_valid)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'The end has to be after the start.',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _wholeDay,
                  icon: const Icon(Icons.today_outlined, size: 18),
                  label: Text(sameDay ? 'WHOLE DAY' : 'JUST THE FIRST DAY'),
                ),
              ),
            ),
            const SectionHeader(title: 'Notes'),
            MojoTextField(
              controller: _notes,
              maxLines: 4,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Why, if you want to remember',
                helperText: 'Only you see this. Clients just see the time is taken.',
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _valid && !_saving ? _save : null,
              child: Text(_editing ? 'SAVE' : 'BLOCK IT OUT'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _whenRow({required bool start}) {
    final value = start ? _start : _end;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => _pickDate(start: start),
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Date'),
              child: Text(formatDate(value)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: () => _pickTime(start: start),
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Time'),
              child: Text(formatTime(value)),
            ),
          ),
        ),
      ],
    );
  }
}
