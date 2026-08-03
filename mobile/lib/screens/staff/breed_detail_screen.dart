import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import 'medical_notes_screen.dart';

/// Jess's breed standards record — "a little snippet of the whole dog".
///
/// Read first, edit second: this is a reference sheet she looks a breed up in
/// far more often than she fills one in, so it opens as a page to read and the
/// pencil turns it into a form.
///
/// Two things here are not merely descriptive. **Size band and coat type are
/// the two axes of the price grid**, so changing either changes what the breed
/// is worth — and three of the eight coats are not on that grid at all, which
/// the page says out loud rather than showing a price nobody set. The **groom
/// styles** pre-fill a new dog's preferences in the dog form; they are a
/// starting point per breed, never an override.
class BreedDetailScreen extends StatefulWidget {
  const BreedDetailScreen({super.key, required this.breedId});

  final int breedId;

  @override
  State<BreedDetailScreen> createState() => _BreedDetailScreenState();
}

class _BreedDetailScreenState extends State<BreedDetailScreen> {
  final _data = getIt<DataService>();

  Breed? _breed;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  Object? _error;

  // Choices come from the server's own vocabulary; these mirror it for the
  // pickers. The four fields Jess enumerated are choices, everything else she
  // is still working out is free text.
  static const _kennelClubGroups = <String, String>{
    '': '—',
    'GUNDOG': 'Gundog',
    'HOUND': 'Hound',
    'PASTORAL': 'Pastoral',
    'TERRIER': 'Terrier',
    'TOY': 'Toy',
    'UTILITY': 'Utility',
    'WORKING': 'Working',
  };
  static const _activityLevels = <String, String>{
    '': '—',
    'HIGH': 'High',
    'MEDIUM': 'Medium',
    'LOW': 'Low',
  };
  static const _sizeBands = <String, String>{
    '': '—',
    'toy': 'Toy',
    'small': 'Small',
    'medium': 'Medium',
    'large': 'Large',
    'colossal': 'Colossal (45kg+)',
  };
  // The first five are the price grid's coat axis. The last three are Jess's
  // and are not on it — see `isPricedByTheGrid`.
  static const _coatTypes = <String, String>{
    '': '—',
    'smooth': 'Smooth',
    'short double': 'Short double',
    'long double': 'Long double',
    'curly': 'Curly',
    'wire': 'Wire',
    'hairless': 'Hairless',
    'corded': 'Corded',
    'silky': 'Silky / drop',
  };

  final _fields = <String, TextEditingController>{};
  String _group = '';
  String _activity = '';
  String _size = '';
  String _coat = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final breed = await _data.getBreed(widget.breedId);
      if (!mounted) return;
      setState(() {
        _breed = breed;
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

  TextEditingController _field(String key, String initial) =>
      _fields.putIfAbsent(key, () => TextEditingController(text: initial));

  void _startEditing(Breed breed) {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    _fields.clear();
    _group = breed.kennelClubGroup;
    _activity = breed.activityLevel;
    _size = breed.sizeBand;
    _coat = breed.coatType;
    setState(() => _editing = true);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    String text(String key) => _fields[key]?.text.trim() ?? '';
    int? number(String key) {
      final raw = text(key);
      return raw.isEmpty ? null : int.tryParse(raw);
    }

    // Blank clears the figure rather than being ignored — a range typed in by
    // mistake has to be removable.
    String? decimal(String key) {
      final raw = text(key);
      return raw.isEmpty ? null : raw;
    }

    try {
      await _data.updateBreed(widget.breedId, {
        'kennel_club_group': _group,
        'activity_level': _activity,
        'size_band': _size,
        'coat_type': _coat,
        'avg_groom_minutes': number('minutes') ?? _breed!.avgGroomMinutes,
        'avg_price': decimal('price') ?? _breed!.avgPrice.toString(),
        'avg_schedule_weeks': number('weeks') ?? _breed!.avgScheduleWeeks,
        'life_span_min_years': number('lifeMin'),
        'life_span_max_years': number('lifeMax'),
        'height_min_cm': number('heightMin'),
        'height_max_cm': number('heightMax'),
        'weight_min_kg': decimal('weightMin'),
        'weight_max_kg': decimal('weightMax'),
        'original_purpose': text('purpose'),
        'chest_shape': text('chest'),
        'head_type': text('headType'),
        'head_shape': text('headShape'),
        'ear_shape': text('ear'),
        'coat_colours': text('colours'),
        'grooming_technique': text('technique'),
        'groom_style_body': text('styleBody'),
        'groom_style_head': text('styleHead'),
        'groom_style_feet': text('styleFeet'),
        'groom_style_tail': text('styleTail'),
        'groom_style_ears': text('styleEars'),
        'common_ailments': text('ailments'),
        'notes': text('notes'),
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, error.toString(), isError: true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _editing = false;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final breed = _breed;
    return Scaffold(
      appBar: AppBar(
        title: Text(breed?.name ?? 'Breed'),
        actions: [
          if (breed != null && !_editing)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () => _startEditing(breed),
            ),
          if (_editing)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('SAVE'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && breed == null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : _editing
                  ? _form(breed!)
                  : _record(breed!),
    );
  }

  // ── Reading it ─────────────────────────────────────────────────────

  Widget _record(Breed breed) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (!breed.hasStandardsRecord)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Nothing filled in yet beyond the groom figures. Tap the pencil '
                'to start this breed’s record.',
                style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
              ),
            ),

          const SectionHeader(title: 'Groom'),
          DetailRow(label: 'Time', value: formatDuration(breed.avgGroomMinutes)),
          DetailRow(
            label: 'Price',
            value: breed.isPricedByTheGrid
                ? formatMoney(breed.avgPrice)
                : '${formatMoney(breed.avgPrice)} — not on the price list',
          ),
          DetailRow(label: 'How often', value: 'Every ${breed.avgScheduleWeeks} weeks'),
          DetailRow(label: 'Size', value: breed.sizeBandDisplay),
          DetailRow(label: 'Coat', value: breed.coatTypeDisplay),
          if (!breed.isPricedByTheGrid)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your price list covers smooth, short double, long double, '
                      'curly and wire. This coat is not on it, so the price above '
                      'is whatever you set — nothing has been worked out for it.',
                      style: TextStyle(fontSize: 12, color: context.mojo.muted),
                    ),
                  ),
                ],
              ),
            ),

          const SectionHeader(title: 'The breed'),
          DetailRow(label: 'KC group', value: breed.kennelClubGroupDisplay),
          DetailRow(label: 'Activity', value: breed.activityLevelDisplay),
          DetailRow(label: 'Life span', value: breed.lifeSpanLabel),
          DetailRow(label: 'Height', value: breed.heightLabel),
          DetailRow(label: 'Weight', value: breed.weightLabel),
          DetailRow(label: 'Bred for', value: breed.originalPurpose),

          const SectionHeader(title: 'Shape'),
          DetailRow(label: 'Chest', value: breed.chestShape),
          DetailRow(label: 'Head type', value: breed.headType),
          DetailRow(label: 'Head shape', value: breed.headShape),
          DetailRow(label: 'Ears', value: breed.earShape),
          DetailRow(label: 'Colours', value: breed.coatColours),

          const SectionHeader(title: 'How it is groomed'),
          DetailRow(label: 'Technique', value: breed.groomingTechnique),
          DetailRow(label: 'Body', value: breed.groomStyleBody),
          DetailRow(label: 'Head', value: breed.groomStyleHead),
          DetailRow(label: 'Feet', value: breed.groomStyleFeet),
          DetailRow(label: 'Tail', value: breed.groomStyleTail),
          DetailRow(label: 'Ears', value: breed.groomStyleEars),
          if (breed.preferenceDefaults.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'These start off a new dog of this breed. Edit them per dog '
                'afterwards — the dog’s own always win.',
                style: TextStyle(fontSize: 12, color: context.mojo.muted),
              ),
            ),

          const SectionHeader(title: 'Health'),
          DetailRow(label: 'Common ailments', value: breed.commonAilments),
          for (final note in breed.medicalNotes)
            ListTile(
              dense: true,
              leading: Icon(Icons.medical_information_outlined,
                  size: 20, color: context.mojo.accent),
              title: Text(note.title),
              subtitle: Text(
                note.isAttributed ? note.source : 'No source recorded',
                style: TextStyle(
                  fontSize: 11.5,
                  color: note.isAttributed ? context.mojo.muted : AppColors.warning,
                ),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MedicalNotesScreen(breedId: breed.id, breedName: breed.name),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.medical_information_outlined, size: 18),
              label: const Text('MEDICAL NOTES'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MedicalNotesScreen(breedId: breed.id, breedName: breed.name),
                ),
              ),
            ),
          ),

          if (breed.notes.isNotEmpty) ...[
            const SectionHeader(title: 'Notes'),
            DetailRow(label: '', value: breed.notes),
          ],
        ],
      ),
    );
  }

  // ── Filling it in ──────────────────────────────────────────────────

  Widget _form(Breed breed) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        const SectionHeader(title: 'Groom'),
        _row([
          _number('minutes', 'Minutes', breed.avgGroomMinutes.toString()),
          _number('price', 'Price', breed.avgPrice.toStringAsFixed(2), decimal: true),
          _number('weeks', 'Every (weeks)', breed.avgScheduleWeeks.toString()),
        ]),
        const SizedBox(height: 12),
        _choice('Size band', _sizeBands, _size, (v) => setState(() => _size = v)),
        const SizedBox(height: 12),
        _choice('Coat type', _coatTypes, _coat, (v) => setState(() => _coat = v)),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Size and coat are the two halves of your price grid. Hairless, '
            'corded and silky are not on it.',
            style: TextStyle(fontSize: 12, color: context.mojo.muted),
          ),
        ),

        const SectionHeader(title: 'The breed'),
        _choice('KC group', _kennelClubGroups, _group, (v) => setState(() => _group = v)),
        const SizedBox(height: 12),
        _choice('Activity level', _activityLevels, _activity, (v) => setState(() => _activity = v)),
        const SizedBox(height: 12),
        _row([
          _number('lifeMin', 'Lives from', breed.lifeSpanMinYears?.toString() ?? ''),
          _number('lifeMax', 'to (years)', breed.lifeSpanMaxYears?.toString() ?? ''),
        ]),
        const SizedBox(height: 12),
        _row([
          _number('heightMin', 'Height from', breed.heightMinCm?.toString() ?? ''),
          _number('heightMax', 'to (cm)', breed.heightMaxCm?.toString() ?? ''),
        ]),
        const SizedBox(height: 12),
        _row([
          _number('weightMin', 'Weighs from', breed.weightMinKg?.toString() ?? '', decimal: true),
          _number('weightMax', 'to (kg)', breed.weightMaxKg?.toString() ?? '', decimal: true),
        ]),
        const SizedBox(height: 12),
        _text('purpose', 'Originally bred for', breed.originalPurpose, lines: 2),

        const SectionHeader(title: 'Shape'),
        _text('chest', 'Chest shape', breed.chestShape),
        const SizedBox(height: 12),
        _text('headType', 'Head type', breed.headType),
        const SizedBox(height: 12),
        _text('headShape', 'Head shape', breed.headShape),
        const SizedBox(height: 12),
        _text('ear', 'Ear shape', breed.earShape),
        const SizedBox(height: 12),
        _text('colours', 'Colours of coat', breed.coatColours, lines: 2),

        const SectionHeader(title: 'How it is groomed'),
        _text('technique', 'Grooming technique', breed.groomingTechnique, lines: 3),
        const SizedBox(height: 12),
        _text('styleBody', 'Groom style — body', breed.groomStyleBody, lines: 2),
        const SizedBox(height: 12),
        _text('styleHead', 'Groom style — head', breed.groomStyleHead, lines: 2),
        const SizedBox(height: 12),
        _text('styleFeet', 'Groom style — feet', breed.groomStyleFeet, lines: 2),
        const SizedBox(height: 12),
        _text('styleTail', 'Groom style — tail', breed.groomStyleTail, lines: 2),
        const SizedBox(height: 12),
        _text('styleEars', 'Groom style — ears', breed.groomStyleEars, lines: 2),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'These fill in a new dog of this breed to start with. They never '
            'overwrite a dog that already has its own.',
            style: TextStyle(fontSize: 12, color: context.mojo.muted),
          ),
        ),

        const SectionHeader(title: 'Health'),
        _text('ailments', 'Common ailments', breed.commonAilments, lines: 3),
        const SizedBox(height: 12),
        _text('notes', 'Notes', breed.notes, lines: 3),
      ],
    );
  }

  Widget _row(List<Widget> children) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: children[i]),
          ],
        ],
      );

  Widget _text(String key, String label, String initial, {int lines = 1}) => MojoTextField(
        controller: _field(key, initial),
        decoration: InputDecoration(labelText: label),
        maxLines: lines,
        textCapitalization: TextCapitalization.sentences,
      );

  Widget _number(String key, String label, String initial, {bool decimal = false}) =>
      MojoTextField(
        controller: _field(key, initial),
        decoration: InputDecoration(labelText: label),
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      );

  Widget _choice(
    String label,
    Map<String, String> options,
    String selected,
    ValueChanged<String> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: options.containsKey(selected) ? selected : '',
      decoration: InputDecoration(labelText: label),
      items: [
        for (final entry in options.entries)
          DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: (value) => onChanged(value ?? ''),
    );
  }
}
