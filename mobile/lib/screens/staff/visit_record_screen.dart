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
  late final TextEditingController _finalFace;
  late final TextEditingController _notes;
  late final TextEditingController _sensitive;
  late final TextEditingController _checklistNotes;

  bool _mattingPaws = false;
  bool _mattingArmpits = false;
  bool _mattingEars = false;
  bool _mattingElsewhere = false;
  bool? _bathedWellBehaved;
  bool? _hvDryer;
  bool? _nails;
  bool? _hygiene;
  bool? _healthCheckDone;
  bool? _earsCleaned;
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

  /// The phases behind this record — handed over by the timer when the card is
  /// being written up, read off the saved session when it is being looked at
  /// again. Either way they were saved and never shown, which is the whole of
  /// Jess's *"it doesn't come up with the individual times for the groom"*.
  List<PhaseTiming> get _timings =>
      _isEditing ? widget.session!.timingsInOrder : widget.timings;

  int get _timedSeconds =>
      _timings.fold(0, (sum, timing) => sum + timing.durationSeconds);

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
    _finalFace = TextEditingController(text: session?.finalFace ?? '');
    _notes = TextEditingController(text: session?.notes ?? '');
    _sensitive = TextEditingController(text: session?.sensitiveNotes ?? '');
    _checklistNotes = TextEditingController(text: session?.checklistNotes ?? '');

    _mattingPaws = session?.mattingPaws ?? false;
    _mattingArmpits = session?.mattingArmpits ?? false;
    _mattingEars = session?.mattingEars ?? false;
    _mattingElsewhere = session?.mattingElsewhere ?? false;
    _bathedWellBehaved = session?.bathedWellBehaved;
    _hvDryer = session?.highVelocityDryer;
    // No `?? false` on the checklist four: a card written up before this
    // list existed answered none of them, and starting them at "not done"
    // would put an answer in Jess's mouth she never gave.
    _nails = session?.nailsDone;
    _hygiene = session?.hygieneAreaDone;
    _healthCheckDone = session?.healthCheckDone;
    _earsCleaned = session?.earsCleaned;
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
      _finalBody, _finalFeet, _finalTail, _finalFace, _notes, _sensitive,
      _checklistNotes,
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
          // The checklist. Sent even when null — the server stores the third
          // state, and dropping the key would leave a box Jess deliberately
          // un-answered looking the same as one she ticked last time.
          'nails_done': _nails,
          'hygiene_area_done': _hygiene,
          'health_check_done': _healthCheckDone,
          'ears_cleaned': _earsCleaned,
          'checklist_notes': _checklistNotes.text.trim(),
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
          'final_face': _finalFace.text.trim(),
        },
        if (!_isGroom) ...{
          // Coerced here and nowhere else. This card asks which of the three
          // the visit was *for* and refuses to save unless one is ticked, so
          // an untouched box is a deliberate "no" rather than a silence —
          // which is exactly the distinction the groom card's checklist keeps
          // as null.
          'nails_done': _nails ?? false,
          'fleas_treated': _fleas,
          'ticks_removed': _ticks,
        },
      };

  Future<void> _save() async {
    if (!_isGroom && _nails != true && !_fleas && !_ticks) {
      showSnack(context, 'Say whether this was nails, fleas or ticks.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      if (_isEditing) {
        await _data.updateGroomSession(widget.session!.id, _record);
      } else {
        final session = await _data.createGroomSession(
          dogId: widget.dogId,
          appointmentId: widget.appointmentId,
          timings: widget.timings,
          notes: _notes.text.trim(),
          record: _record,
        );
        // Which booking this landed on, that it has been marked off, and the
        // way back. The snack goes to the root messenger, so it outlives this
        // route popping.
        if (mounted) reportSavedVisit(context, session, saved: 'Visit record saved.');
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  /// One line of Jess's finishing checklist.
  ///
  /// Three states, not two, and the same rule as the bathing and dryer
  /// questions above it: a box that starts unticked cannot tell "I left the
  /// hygiene area" from "I have not been down this list yet", and on this
  /// list the first one is the fact worth having — it is what the reason box
  /// underneath exists to explain.
  ///
  /// A tristate [Checkbox] cycles `false → true → null` on its own, which puts
  /// **Not done** under the first tap. The common case is the opposite, so the
  /// value handed back is ignored and the order is set here: not recorded →
  /// done → not done → back to not recorded. The subtitle says which state it
  /// is in outright, because a dash is only obvious once somebody has told you
  /// what it means.
  Widget _checklistTile(String label, bool? value, ValueChanged<bool?> onChanged) {
    final (String state, Color colour) = switch (value) {
      true => ('Done', context.mojo.accent),
      false => ('Not done — say why below', AppColors.warning),
      null => ('Not recorded', context.mojo.muted),
    };
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      tristate: true,
      value: value,
      onChanged: (_) => onChanged(switch (value) {
        null => true,
        true => false,
        false => null,
      }),
      title: Text(label),
      subtitle: Text(state, style: TextStyle(fontSize: 11.5, color: colour)),
    );
  }

  /// Actual grooming time, and the phases underneath it.
  ///
  /// Every groom Jess has timed stored its phases and showed her none of them
  /// — the card kept one total and the timer screen was gone by the time she
  /// looked. This is that breakdown, folded away because the total is the
  /// answer most of the time and the phases are what she opens it for.
  ///
  /// Deliberately read-only. The phases are a measurement; the figure she can
  /// change is the one above, which is the one that does anything.
  Widget _timedSection() {
    return Theme(
      // The default expansion tile draws a divider top and bottom, which reads
      // as a section break in the middle of one.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 12, bottom: 8),
        title: const Text('Actual grooming time', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          '${_timings.length} phase${_timings.length == 1 ? '' : 's'} timed',
          style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatClock(_timedSeconds),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 20),
          ],
        ),
        children: [
          for (final timing in _timings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      PhaseTiming.labelFor(timing.phase),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (timing.enteredManually)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        'by hand',
                        style: TextStyle(fontSize: 11, color: context.mojo.muted),
                      ),
                    ),
                  Text(
                    formatClock(timing.durationSeconds),
                    style: const TextStyle(
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'What the stopwatch measured. The figure above is the whole groom '
            "— drop-off, nails, ears and collection are in it and aren't timed.",
            style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
          ),
        ],
      ),
    );
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

                // Two figures, and they are not the same number.
                //
                // Jess: *"can the 'appointment time' be the 'how long the
                // groom took' but the timer is 'actual grooming time' so I can
                // click on it and see the timer?"*. The one above is what
                // sizes the next booking; the one below is what the stopwatch
                // measured, and it opens.
                MojoTextField(
                  controller: _recordedMinutes,
                  decoration: InputDecoration(
                    labelText: _isGroom
                        ? 'How long the groom took (minutes)'
                        : 'How long the visit took (minutes)',
                    helperText: _isGroom
                        ? 'What to book next time. Blank uses the timer.'
                        : null,
                  ),
                  keyboardType: TextInputType.number,
                ),
                if (_timings.isNotEmpty) _timedSection(),

                if (!_isGroom) ...[
                  const SectionHeader(title: 'What was done'),
                  // Two-state here on purpose, unlike the groom card's
                  // checklist: this card asks which of the three the visit was
                  // *for*, and saving is refused unless one is ticked — so an
                  // empty box is an answer rather than a silence.
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _nails ?? false,
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
                  // Jess's four: "Nails Clipped, Hygiene Area, Health Check,
                  // Ears Cleaned ... with a little box under to fill in why
                  // something not done". First on the card because it is the
                  // list she works down, and last thing before she puts the
                  // dog back is the wrong time to go looking for it.
                  const SectionHeader(title: 'Checklist'),
                  _checklistTile(
                    'Nails clipped',
                    _nails,
                    (value) => setState(() => _nails = value),
                  ),
                  _checklistTile(
                    'Hygiene area',
                    _hygiene,
                    (value) => setState(() => _hygiene = value),
                  ),
                  _checklistTile(
                    'Health check',
                    _healthCheckDone,
                    (value) => setState(() => _healthCheckDone = value),
                  ),
                  _checklistTile(
                    'Ears cleaned',
                    _earsCleaned,
                    (value) => setState(() => _earsCleaned = value),
                  ),
                  const SizedBox(height: 8),
                  MojoTextField(
                    controller: _checklistNotes,
                    decoration: const InputDecoration(
                      labelText: 'Why anything was not done',
                    ),
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                  ),

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
                  const SizedBox(height: 12),
                  // Jess asked for this "like the bathed", and for the same
                  // reason: a switch that starts off cannot tell "we didn't
                  // use one" from "nobody wrote it down".
                  DropdownButtonFormField<bool?>(
                    initialValue: _hvDryer,
                    decoration: const InputDecoration(labelText: 'High velocity dryer'),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('Not recorded')),
                      DropdownMenuItem(value: true, child: Text('Used')),
                      DropdownMenuItem(value: false, child: Text('Not used')),
                    ],
                    onChanged: (value) => setState(() => _hvDryer = value),
                  ),
                  const SizedBox(height: 12),
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
                  const SizedBox(height: 14),
                  // Jess's request. Goes beyond the paper card, which records
                  // body, feet and tail only — see docs/paper-cards.md.
                  MojoTextField(
                    controller: _finalFace,
                    decoration: const InputDecoration(labelText: 'Final face shape'),
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

/// Confirm a saved visit: what it did to the dog, which booking it landed on,
/// and the way back.
///
/// Jess asked why a session she recorded "wasn't automatically assigned to the
/// appointment". It is now — and because that also marks the booking off in
/// the diary, this says so out loud rather than leaving her to find it. A
/// status changed on the back of a different action is a fair inference and a
/// poor thing to do silently; one tap from reversible is what squares it.
///
/// One snackbar, not two. [saved] is the caller's own line about the save, and
/// showing it separately would mean two bars in a row — the second hides the
/// first, so the first may as well not have been shown.
void reportSavedVisit(BuildContext context, GroomSession session, {String? saved}) {
  final message = [saved, session.bookingNote].whereType<String>().join(' ');
  if (message.isEmpty) return;

  final bookingId = session.appointmentId;
  final before = session.appointmentStatusBefore;
  if (bookingId == null || before == null) {
    // No booking, or one filed against without changing it: nothing to undo.
    showSnack(context, message);
    return;
  }

  // Held now rather than inside the callback: the screen that raised this is
  // usually popping behind the snack, and the messenger belongs to the app
  // rather than to this route.
  final messenger = ScaffoldMessenger.of(context);
  showSnackWithUndo(context, message, onUndo: () async {
    try {
      await getIt<DataService>().updateAppointment(bookingId, {'status': before});
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Booking put back.')));
    } catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Could not put the booking back. $error'),
          backgroundColor: AppColors.error,
        ));
    }
  });
}
