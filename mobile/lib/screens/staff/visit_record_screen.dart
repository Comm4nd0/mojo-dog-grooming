import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/temperament_picker.dart';

/// Jess's "Ongoing Record" card, as a screen.
///
/// One screen for both of her cards: a groom shows the lot, a nails/fleas/ticks
/// visit shows the handful of questions that card actually asks. Which fields
/// appear is driven by [visitType] — the paper cards differ that much, and
/// showing a shampoo box on a nail trim would just be noise.
class VisitRecordScreen extends StatefulWidget {
  const VisitRecordScreen({
    super.key,
    required this.dogId,
    required this.dogName,
    this.visitType = VisitType.groom,
    this.session,
    this.appointmentId,
    this.timings = const [],
  });

  final int dogId;
  final String dogName;
  final String visitType;

  /// An existing record to edit. Null means this is a new one.
  final GroomSession? session;

  /// Only used when creating: the appointment and phase timings the record
  /// belongs to, handed over by the timer screen.
  final int? appointmentId;
  final List<PhaseTiming> timings;

  @override
  State<VisitRecordScreen> createState() => _VisitRecordScreenState();
}

class _VisitRecordScreenState extends State<VisitRecordScreen> {
  final _data = getIt<DataService>();

  late final TextEditingController _recordedMinutes;
  late final TextEditingController _healthCheck;
  late final TextEditingController _mattingNotes;
  late final TextEditingController _shampoo;
  late final TextEditingController _finalBody;
  late final TextEditingController _finalFeet;
  late final TextEditingController _finalTail;
  late final TextEditingController _notes;
  late final TextEditingController _sensitive;

  bool _mattingPaws = false;
  bool _mattingArmpits = false;
  bool _mattingEars = false;
  bool _mattingElsewhere = false;
  bool? _bathedWellBehaved;
  bool _hvDryer = false;
  bool _nails = false;
  bool _fleas = false;
  bool _ticks = false;
  String _temperament = '';
  Set<int> _equipmentIds = {};

  List<Equipment> _equipment = const [];
  List<TemperamentGrade> _grades = TemperamentChipLabels.fallback;
  bool _loading = true;
  bool _busy = false;

  bool get _isGroom => widget.visitType == VisitType.groom;
  bool get _isEditing => widget.session != null;

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    _recordedMinutes =
        TextEditingController(text: session?.recordedMinutes?.toString() ?? '');
    _healthCheck = TextEditingController(text: session?.healthCheckNotes ?? '');
    _mattingNotes = TextEditingController(text: session?.mattingNotes ?? '');
    _shampoo = TextEditingController(text: session?.shampooUsed ?? '');
    _finalBody = TextEditingController(text: session?.finalBody ?? '');
    _finalFeet = TextEditingController(text: session?.finalFeet ?? '');
    _finalTail = TextEditingController(text: session?.finalTail ?? '');
    _notes = TextEditingController(text: session?.notes ?? '');
    _sensitive = TextEditingController(text: session?.sensitiveNotes ?? '');

    _mattingPaws = session?.mattingPaws ?? false;
    _mattingArmpits = session?.mattingArmpits ?? false;
    _mattingEars = session?.mattingEars ?? false;
    _mattingElsewhere = session?.mattingElsewhere ?? false;
    _bathedWellBehaved = session?.bathedWellBehaved;
    _hvDryer = session?.highVelocityDryer ?? false;
    _nails = session?.nailsDone ?? false;
    _fleas = session?.fleasTreated ?? false;
    _ticks = session?.ticksRemoved ?? false;
    _temperament = session?.temperamentObserved ?? '';
    _equipmentIds = {for (final item in session?.equipmentUsed ?? const []) item.id};

    _loadReferenceData();
  }

  @override
  void dispose() {
    for (final controller in [
      _recordedMinutes, _healthCheck, _mattingNotes, _shampoo,
      _finalBody, _finalFeet, _finalTail, _notes, _sensitive,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadReferenceData() async {
    // Both cards ask how the dog was, so the grades are fetched whichever one
    // this is. Equipment is on the groom card only.
    try {
      final grades = await _data.getTemperamentGrades();
      if (mounted && grades.isNotEmpty) setState(() => _grades = grades);
    } catch (_) {
      // Left on the seed wording.
    }

    if (!_isGroom) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final equipment = await _data.getEquipment();
      if (!mounted) return;
      setState(() {
        _equipment = equipment.where((item) => item.isActive).toList();
        _loading = false;
      });
    } catch (_) {
      // The card is still usable without the equipment list — losing it
      // shouldn't stop Jess writing up a groom she has just finished.
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> get _record => {
        'visit_type': widget.visitType,
        'recorded_minutes': _recordedMinutes.text.trim().isEmpty
            ? null
            : int.tryParse(_recordedMinutes.text.trim()),
        'notes': _notes.text.trim(),
        'sensitive_notes': _sensitive.text.trim(),
        'temperament_observed': _temperament,
        if (_isGroom) ...{
          'health_check_notes': _healthCheck.text.trim(),
          'matting_paws': _mattingPaws,
          'matting_armpits': _mattingArmpits,
          'matting_ears': _mattingEars,
          'matting_elsewhere': _mattingElsewhere,
          'matting_notes': _mattingNotes.text.trim(),
          'bathed_well_behaved': _bathedWellBehaved,
          'high_velocity_dryer': _hvDryer,
          'shampoo_used': _shampoo.text.trim(),
          'equipment_used': _equipmentIds.toList(),
          'final_body': _finalBody.text.trim(),
          'final_feet': _finalFeet.text.trim(),
          'final_tail': _finalTail.text.trim(),
        },
        if (!_isGroom) ...{
          'nails_done': _nails,
          'fleas_treated': _fleas,
          'ticks_removed': _ticks,
        },
      };

  Future<void> _save() async {
    if (!_isGroom && !_nails && !_fleas && !_ticks) {
      showSnack(context, 'Say whether this was nails, fleas or ticks.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      if (_isEditing) {
        await _data.updateGroomSession(widget.session!.id, _record);
      } else {
        await _data.createGroomSession(
          dogId: widget.dogId,
          appointmentId: widget.appointmentId,
          timings: widget.timings,
          notes: _notes.text.trim(),
          record: _record,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isGroom ? 'Groom record' : 'Nails, fleas or ticks'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                Text(widget.dogName, style: AppColors.display(22)),
                const SizedBox(height: 16),

                MojoTextField(
                  controller: _recordedMinutes,
                  decoration: const InputDecoration(
                    labelText: 'How long the visit took (minutes)',
                    helperText: 'Leave blank to use the timer total',
                  ),
                  keyboardType: TextInputType.number,
                ),

                if (!_isGroom) ...[
                  const SectionHeader(title: 'What was done'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _nails,
                    onChanged: (value) => setState(() => _nails = value ?? false),
                    title: const Text('Nails'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _fleas,
                    onChanged: (value) => setState(() => _fleas = value ?? false),
                    title: const Text('Fleas'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _ticks,
                    onChanged: (value) => setState(() => _ticks = value ?? false),
                    title: const Text('Ticks'),
                  ),
                ],

                if (_isGroom) ...[
                  const SectionHeader(title: 'Health check'),
                  MojoTextField(
                    controller: _healthCheck,
                    decoration: const InputDecoration(labelText: 'Anything found'),
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                  ),

                  const SectionHeader(title: 'Matting found'),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('In paws'),
                        selected: _mattingPaws,
                        onSelected: (value) => setState(() => _mattingPaws = value),
                      ),
                      FilterChip(
                        label: const Text('Under armpits'),
                        selected: _mattingArmpits,
                        onSelected: (value) => setState(() => _mattingArmpits = value),
                      ),
                      FilterChip(
                        label: const Text('Under ears'),
                        selected: _mattingEars,
                        onSelected: (value) => setState(() => _mattingEars = value),
                      ),
                      FilterChip(
                        label: const Text('Anywhere else'),
                        selected: _mattingElsewhere,
                        onSelected: (value) => setState(() => _mattingElsewhere = value),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  MojoTextField(
                    controller: _mattingNotes,
                    decoration: const InputDecoration(labelText: 'Where, and how bad'),
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                  ),

                  const SectionHeader(title: 'Bathing and drying'),
                  // Three states on purpose: "not bathed" is not the same as
                  // "bathed and hated it", and the card leaves it blank when
                  // there was no bath.
                  DropdownButtonFormField<bool?>(
                    initialValue: _bathedWellBehaved,
                    decoration: const InputDecoration(labelText: 'Bathing, well behaved'),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('Not recorded')),
                      DropdownMenuItem(value: true, child: Text('Yes')),
                      DropdownMenuItem(value: false, child: Text('No')),
                    ],
                    onChanged: (value) => setState(() => _bathedWellBehaved = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _hvDryer,
                    onChanged: (value) => setState(() => _hvDryer = value),
                    title: const Text('High velocity dryer used'),
                  ),
                  MojoTextField(
                    controller: _shampoo,
                    decoration: const InputDecoration(labelText: 'Shampoo used'),
                  ),

                  const SectionHeader(title: 'Equipment used'),
                  if (_equipment.isEmpty)
                    Text(
                      'No equipment on file yet.',
                      style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final item in _equipment)
                          FilterChip(
                            label: Text(item.name),
                            selected: _equipmentIds.contains(item.id),
                            onSelected: (value) => setState(() {
                              if (value) {
                                _equipmentIds.add(item.id);
                              } else {
                                _equipmentIds.remove(item.id);
                              }
                            }),
                          ),
                      ],
                    ),

                  const SectionHeader(title: 'How it was left'),
                  MojoTextField(
                    controller: _finalBody,
                    decoration: const InputDecoration(labelText: 'Final body trim'),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  const SizedBox(height: 14),
                  MojoTextField(
                    controller: _finalFeet,
                    decoration: const InputDecoration(labelText: 'Final feet shape'),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  const SizedBox(height: 14),
                  MojoTextField(
                    controller: _finalTail,
                    decoration: const InputDecoration(labelText: 'Final tail'),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ],

                const SectionHeader(title: 'How the dog was'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Overall temperament',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TemperamentPicker(
                  grades: _grades,
                  selected: _temperament,
                  includeUnset: true,
                  onSelected: (code) => setState(() => _temperament = code ?? ''),
                ),
                const SizedBox(height: 6),
                Text(
                  "Recorded against this visit only — it doesn't change the dog's "
                  'temperament or the daily booking limit.',
                  style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
                ),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: _sensitive,
                  decoration: const InputDecoration(
                    labelText: "Anywhere they didn't want to be touched",
                  ),
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: 'Anything to note'),
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                ),

                const SizedBox(height: 28),
                ElevatedButton(
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'SAVING…' : 'SAVE RECORD'),
                ),
              ],
            ),
    );
  }
}
