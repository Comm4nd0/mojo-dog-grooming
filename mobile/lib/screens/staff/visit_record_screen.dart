import 'dart:convert';

import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/temperament_picker.dart';

/// Jess's "Ongoing Record" card, as a screen.
///
/// **One card for every visit**, at her request — *"I don't think it needs to
/// be a separate thing for nails/fleas/ticks really"*. It used to fork on the
/// visit type and show a nails visit a cut-down card; now everything is always
/// on it, and the type survives only as a question near the top — because the
/// server keeps nails visits out of the groom-time average and refuses to
/// write their minutes to the dog, so which kind this was still has to be
/// true. A visit arriving from the timer was a groom by construction and is
/// never asked.
///
/// The checklist, its reason box, the temperament and the visit note are
/// **owner-visible** through the groom report — Jess: *"The owner should be
/// able to see this"*. The card says so beside each of them, because she is
/// writing with a reader now and the boundary should never be a surprise.
///
/// **It can be filled in while the groom is still on the clock.** Jess:
/// *"is there a way that I can 'fill out the groom card' whilst doing the
/// groom, so bits found in health check I remember to put on"*. Opened off
/// the timer with a [LiveGroom], every change goes straight back to the
/// timer's draft, so backing out keeps it and the app being killed keeps it;
/// the phases shown are the time so far and nothing on the clock is paused
/// by opening this. Saving from here is what finishes the groom.
class VisitRecordScreen extends StatefulWidget {
  const VisitRecordScreen({
    super.key,
    required this.dogId,
    required this.dogName,
    this.visitType = VisitType.groom,
    this.session,
    this.appointmentId,
    this.liveGroom,
  });

  final int dogId;
  final String dogName;

  /// What the visit was for, when the opener knows — the timer leaves the
  /// default (a timed visit is a groom), editing passes the record's own.
  /// **Null means ask**: the profile's ADD VISIT can't know, and a guess here
  /// would put nail trims into the groom-time average.
  final String? visitType;

  /// An existing record to edit. Null means this is a new one.
  final GroomSession? session;

  /// Only used when creating: the booking the record belongs to, handed
  /// over by the timer screen.
  final int? appointmentId;

  /// The groom this card is for, when it is still being timed. Null for a
  /// card added by hand or one being looked at again.
  final LiveGroom? liveGroom;

  @override
  State<VisitRecordScreen> createState() => _VisitRecordScreenState();
}

/// A groom on the clock, as the record card sees it.
///
/// The card knows nothing about the timer service; this is the seam. The
/// phases come as two readings because they differ in what they do: [phases]
/// is the time so far and stops nothing, [settle] banks whatever is running
/// and is what the saved record carries. [record] is the card as Jess left
/// it last time, and [onRecordChanged] is where every change goes.
class LiveGroom {
  const LiveGroom({
    required this.phases,
    required this.settle,
    required this.isRunning,
    required this.record,
    required this.onRecordChanged,
  });

  final List<PhaseTiming> Function() phases;
  final List<PhaseTiming> Function() settle;
  final bool Function() isRunning;
  final Map<String, dynamic> record;
  final ValueChanged<Map<String, dynamic>> onRecordChanged;
}

class _VisitRecordScreenState extends State<VisitRecordScreen> {
  final _data = getIt<DataService>();

  late final TextEditingController _recordedMinutes;
  late final TextEditingController _healthCheck;
  late final TextEditingController _mattingNotes;
  late final TextEditingController _bathing;
  late final TextEditingController _drying;
  late final TextEditingController _finalBody;
  late final TextEditingController _finalFeet;
  late final TextEditingController _finalTail;
  late final TextEditingController _finalFace;
  late final TextEditingController _notes;
  late final TextEditingController _sensitive;
  late final TextEditingController _checklistNotes;

  /// Null until answered. The dropdown starts unset on a hand-added visit for
  /// the same reason the intake form's radios do — a pre-picked answer is an
  /// answer nobody gave.
  String? _visitType;

  bool _mattingPaws = false;
  bool _mattingArmpits = false;
  bool _mattingEars = false;
  bool _mattingElsewhere = false;
  bool? _bathedWellBehaved;
  bool? _hvDryer;
  bool? _healthCheckDone;
  bool? _nails;
  bool? _earsCleaned;
  bool? _hygiene;
  bool? _feetClippedOut;
  bool? _bathed;
  bool? _blowDried;
  bool? _usualGroom;
  bool _fleas = false;
  bool _ticks = false;
  String _temperament = '';
  Set<int> _equipmentIds = {};

  List<Equipment> _equipment = const [];
  List<TemperamentGrade> _grades = TemperamentChipLabels.fallback;
  bool _loading = true;
  bool _busy = false;

  bool get _isEditing => widget.session != null;
  bool get _onTheClock => widget.liveGroom != null;

  /// The phases behind this record — the time so far when the groom is still
  /// being timed, read off the saved session when it is being looked at
  /// again. Either way they were saved and never shown, which is the whole of
  /// Jess's *"it doesn't come up with the individual times for the groom"*.
  List<PhaseTiming> get _timings => _isEditing
      ? widget.session!.timingsInOrder
      : widget.liveGroom?.phases() ?? const [];

  int get _timedSeconds =>
      _timings.fold(0, (sum, timing) => sum + timing.durationSeconds);

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    _visitType = session?.visitType ?? widget.visitType;
    _recordedMinutes =
        TextEditingController(text: session?.recordedMinutes?.toString() ?? '');
    _healthCheck = TextEditingController(text: session?.healthCheckNotes ?? '');
    _mattingNotes = TextEditingController(text: session?.mattingNotes ?? '');
    // The typed answers lead; a card from before they existed renders its old
    // yes/no as words rather than losing it. The words are a faithful reading
    // of a box labelled "well behaved" — nothing further is invented.
    _bathing = TextEditingController(
      text: (session?.bathingNotes.isNotEmpty ?? false)
          ? session!.bathingNotes
          : switch (session?.bathedWellBehaved) {
              true => 'Well behaved',
              false => 'Not well behaved',
              null => '',
            },
    );
    _drying = TextEditingController(
      text: (session?.dryingNotes.isNotEmpty ?? false)
          ? session!.dryingNotes
          : switch (session?.highVelocityDryer) {
              true => 'High velocity dryer used',
              false => 'High velocity dryer not used',
              null => '',
            },
    );
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
    // No `?? false` on the checklist: a card written up before this list
    // existed answered none of it, and starting a box at "not done" would put
    // an answer in Jess's mouth she never gave.
    _healthCheckDone = session?.healthCheckDone;
    _nails = session?.nailsDone;
    _earsCleaned = session?.earsCleaned;
    _hygiene = session?.hygieneAreaDone;
    _feetClippedOut = session?.feetClippedOut;
    _bathed = session?.bathed;
    _blowDried = session?.blowDried;
    _usualGroom = session?.usualGroomDone;
    _fleas = session?.fleasTreated ?? false;
    _ticks = session?.ticksRemoved ?? false;
    _temperament = session?.temperamentObserved ?? '';
    _equipmentIds = {for (final item in session?.equipmentUsed ?? const []) item.id};

    final live = widget.liveGroom;
    if (live != null) {
      _applyRecord(live.record);
      // After the prefill, so reading the draft back does not count as
      // changing it. Chips and checkboxes go through [setState] below; the
      // text fields do not, so they report themselves.
      _lastSent = jsonEncode(_record);
      for (final controller in _controllers) {
        controller.addListener(_recordChanged);
      }
    }

    _loadReferenceData();
  }

  List<TextEditingController> get _controllers => [
        _recordedMinutes, _healthCheck, _mattingNotes, _bathing, _drying,
        _finalBody, _finalFeet, _finalTail, _finalFace, _notes, _sensitive,
        _checklistNotes,
      ];

  /// Every change on a card that is still on the clock goes back to the
  /// timer's draft. Overridden rather than wired into each of the forty-odd
  /// `setState` calls below, which would leave the next one to be forgotten.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _recordChanged();
  }

  /// The record as last handed to the timer, so a rebuild that changed
  /// nothing on the card — the reference lists arriving, a busy flag — is
  /// not reported as a change to it.
  String? _lastSent;

  void _recordChanged() {
    final live = widget.liveGroom;
    if (live == null) return;
    final record = _record;
    final encoded = jsonEncode(record);
    if (encoded == _lastSent) return;
    _lastSent = encoded;
    live.onRecordChanged(record);
  }

  /// Read a draft back into the form — the inverse of [_record], and as
  /// forgiving as the persisted blob needs it to be: a value that is not the
  /// type it should be reads as not answered, never as an answer.
  void _applyRecord(Map<String, dynamic> record) {
    String text(String key) => record[key]?.toString() ?? '';
    bool? tri(String key) => record[key] is bool ? record[key] as bool : null;
    bool flag(String key) => record[key] == true;
    void put(TextEditingController controller, String key) {
      if (record.containsKey(key)) controller.text = text(key);
    }

    if (record['visit_type'] is String) _visitType = record['visit_type'] as String;
    put(_recordedMinutes, 'recorded_minutes');
    put(_notes, 'notes');
    put(_sensitive, 'sensitive_notes');
    put(_checklistNotes, 'checklist_notes');
    put(_healthCheck, 'health_check_notes');
    put(_mattingNotes, 'matting_notes');
    put(_bathing, 'bathing_notes');
    put(_drying, 'drying_notes');
    put(_finalBody, 'final_body');
    put(_finalFeet, 'final_feet');
    put(_finalTail, 'final_tail');
    put(_finalFace, 'final_face');
    _temperament = text('temperament_observed');
    _healthCheckDone = tri('health_check_done');
    _nails = tri('nails_done');
    _earsCleaned = tri('ears_cleaned');
    _hygiene = tri('hygiene_area_done');
    _feetClippedOut = tri('feet_clipped_out');
    _bathed = tri('bathed');
    _blowDried = tri('blow_dried');
    _usualGroom = tri('usual_groom_done');
    _bathedWellBehaved = tri('bathed_well_behaved');
    _hvDryer = tri('high_velocity_dryer');
    _fleas = flag('fleas_treated');
    _ticks = flag('ticks_removed');
    _mattingPaws = flag('matting_paws');
    _mattingArmpits = flag('matting_armpits');
    _mattingEars = flag('matting_ears');
    _mattingElsewhere = flag('matting_elsewhere');
    _equipmentIds = {
      for (final id in (record['equipment_used'] as List?) ?? const [])
        if (id is num) id.toInt(),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadReferenceData() async {
    try {
      final grades = await _data.getTemperamentGrades();
      if (mounted && grades.isNotEmpty) setState(() => _grades = grades);
    } catch (_) {
      // Left on the seed wording.
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
        'visit_type': _visitType,
        'recorded_minutes': _recordedMinutes.text.trim().isEmpty
            ? null
            : int.tryParse(_recordedMinutes.text.trim()),
        'notes': _notes.text.trim(),
        'sensitive_notes': _sensitive.text.trim(),
        'temperament_observed': _temperament,
        // The checklist. Sent even when null — the server stores the third
        // state, and dropping the key would leave a box Jess deliberately
        // un-answered looking the same as one she ticked last time.
        'health_check_done': _healthCheckDone,
        'nails_done': _nails,
        'ears_cleaned': _earsCleaned,
        'hygiene_area_done': _hygiene,
        'feet_clipped_out': _feetClippedOut,
        'bathed': _bathed,
        'blow_dried': _blowDried,
        'usual_groom_done': _usualGroom,
        'checklist_notes': _checklistNotes.text.trim(),
        'fleas_treated': _fleas,
        'ticks_removed': _ticks,
        'health_check_notes': _healthCheck.text.trim(),
        'matting_paws': _mattingPaws,
        'matting_armpits': _mattingArmpits,
        'matting_ears': _mattingEars,
        'matting_elsewhere': _mattingElsewhere,
        'matting_notes': _mattingNotes.text.trim(),
        'bathed_well_behaved': _bathedWellBehaved,
        'high_velocity_dryer': _hvDryer,
        'bathing_notes': _bathing.text.trim(),
        'drying_notes': _drying.text.trim(),
        'equipment_used': _equipmentIds.toList(),
        'final_body': _finalBody.text.trim(),
        'final_feet': _finalFeet.text.trim(),
        'final_tail': _finalTail.text.trim(),
        'final_face': _finalFace.text.trim(),
      };

  Future<void> _save() async {
    if (_visitType == null) {
      showSnack(context, 'Say what kind of visit this was.', isError: true);
      return;
    }
    if (_visitType == VisitType.nailsFleasTicks &&
        _nails != true && !_fleas && !_ticks) {
      showSnack(context, 'Say whether this was nails, fleas or ticks.', isError: true);
      return;
    }
    final live = widget.liveGroom;
    if (live != null && live.isRunning() && !await _confirmStoppingTheClock()) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      if (_isEditing) {
        await _data.updateGroomSession(widget.session!.id, _record);
      } else {
        final session = await _data.createGroomSession(
          dogId: widget.dogId,
          appointmentId: widget.appointmentId,
          // Banked now, not when the card was opened: the clock has been
          // going the whole time this was being filled in.
          timings: live?.settle() ?? const [],
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

  /// Saving a card off a groom that is still being timed stops the clock,
  /// and the button says so — but a phase that is actually running is worth
  /// one more question, because the tap that meant "keep this" and the tap
  /// that means "finish" are an inch apart.
  Future<bool> _confirmStoppingTheClock() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop the clock?'),
        content: Text(
          '${widget.dogName} is still being timed. Saving files the visit '
          'with the time so far and ends the timer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('KEEP TIMING'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('FINISH & SAVE'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// One line of Jess's finishing checklist.
  ///
  /// Three states, not two, and the same rule as the bathing and dryer
  /// questions below it: a box that starts unticked cannot tell "I left the
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
          // Not "nails, ears" — Jess does those inside the timed phases, so
          // the stopwatch does see them. What it never counts is the handover
          // at both ends and anything done off the clock.
          Text(
            'What the stopwatch measured. The figure above is the whole visit '
            "— drop-off, collection and anything done off the clock are in it.",
            style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
          ),
        ],
      ),
    );
  }

  /// Jess: *"Can the equipment selection be a drop down menu? Just takes up a
  /// bit of space when filling out the groom card."* One compact field showing
  /// what's ticked, opening into the list — instead of a wall of chips.
  Widget _equipmentField() {
    final selected = [
      for (final item in _equipment)
        if (_equipmentIds.contains(item.id)) item.name,
    ];
    return InkWell(
      onTap: _equipment.isEmpty ? null : _pickEquipment,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Equipment used',
          helperText: _equipment.isEmpty ? 'No equipment on file yet.' : null,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        isEmpty: selected.isEmpty,
        child: selected.isEmpty
            ? null
            : Text(selected.join(', '), style: const TextStyle(fontSize: 14)),
      ),
    );
  }

  Future<void> _pickEquipment() async {
    await showModalBottomSheet<void>(
      context: context,
      // The sheet mutates the screen's selection as boxes are ticked, so
      // backing out by any route keeps what was picked — there is no separate
      // confirm step to lose work behind.
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            children: [
              Text('Equipment used', style: AppColors.display(18)),
              const SizedBox(height: 4),
              for (final item in _equipment)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _equipmentIds.contains(item.id),
                  onChanged: (ticked) {
                    setSheetState(() {});
                    setState(() {
                      if (ticked == true) {
                        _equipmentIds.add(item.id);
                      } else {
                        _equipmentIds.remove(item.id);
                      }
                    });
                  },
                  title: Text(item.name),
                ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('DONE'),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// A quiet marker on the fields the owner can read through the groom
  /// report. Jess writes the whole card; only some of it has a reader now,
  /// and the boundary should be on the card rather than in her memory.
  Widget _ownerCanSee(String what) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility_outlined, size: 13, color: context.mojo.muted),
          const SizedBox(width: 5),
          Text(
            what,
            style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Visit record')),
      body: PageBody(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                Text(widget.dogName, style: AppColors.display(22)),
                const SizedBox(height: 16),

                // The one thing that is different about a card opened
                // mid-groom, said once at the top: nothing here is lost by
                // leaving, and nothing is filed until she says finish.
                if (_onTheClock) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: context.mojo.tintWash,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.timer, size: 18, color: context.mojo.accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Still on the clock. Fill this in as you go — it '
                            'is kept with the timer if you leave, and nothing '
                            'is filed until you finish the groom.',
                            style: TextStyle(fontSize: 12.5, color: context.mojo.accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Asked only when nothing has answered it: a timed visit is a
                // groom by construction, so a card opened off the timer never
                // shows this. It matters because the server keeps nails visits
                // out of the groom-time average — a nail trim filed as a groom
                // would quietly shrink the dog's booking length.
                if (_timings.isEmpty && !_onTheClock) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _visitType,
                    decoration: const InputDecoration(labelText: 'What kind of visit'),
                    hint: const Text('Choose one'),
                    items: const [
                      DropdownMenuItem(
                        value: VisitType.groom,
                        child: Text('Full groom'),
                      ),
                      DropdownMenuItem(
                        value: VisitType.nailsFleasTicks,
                        child: Text('Nails, fleas or ticks'),
                      ),
                    ],
                    onChanged: (value) => setState(() => _visitType = value),
                  ),
                  const SizedBox(height: 14),
                ],

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
                    labelText: _visitType == VisitType.nailsFleasTicks
                        ? 'How long the visit took (minutes)'
                        : 'How long the groom took (minutes)',
                    helperText: _visitType == VisitType.nailsFleasTicks
                        ? null
                        : 'What to book next time. Blank uses the timer.',
                  ),
                  keyboardType: TextInputType.number,
                ),
                if (_timings.isNotEmpty) _timedSection(),

                // Jess's eight: "Health Checked, Nails Clipped, Ears Cleaned,
                // Hygiene Area, Feet Clipped Out, Bathed, Blow Dried, Usual
                // Groom Carried Out ... with a text box below saying - notes
                // from any of the above, why it was not carried out". First on
                // the card because it is the list she works down, and last
                // thing before she puts the dog back is the wrong time to go
                // looking for it.
                const SectionHeader(title: 'Checklist'),
                _ownerCanSee('The owner sees this list and the reason box.'),
                _checklistTile(
                  'Health check',
                  _healthCheckDone,
                  (value) => setState(() => _healthCheckDone = value),
                ),
                _checklistTile(
                  'Nails clipped',
                  _nails,
                  (value) => setState(() => _nails = value),
                ),
                _checklistTile(
                  'Ears cleaned',
                  _earsCleaned,
                  (value) => setState(() => _earsCleaned = value),
                ),
                _checklistTile(
                  'Hygiene area',
                  _hygiene,
                  (value) => setState(() => _hygiene = value),
                ),
                _checklistTile(
                  'Feet clipped out',
                  _feetClippedOut,
                  (value) => setState(() => _feetClippedOut = value),
                ),
                // Bathed and blow dried are tied to the two behaviour
                // questions further down: an answer about how the bath went
                // means a bath went, so the pairs move together here exactly
                // as the server would fill them in anyway.
                _checklistTile(
                  'Bathed',
                  _bathed,
                  (value) => setState(() {
                    _bathed = value;
                    // "Not bathed" cannot sit beside an answer about how the
                    // bath went — the pair moves together, words included.
                    if (value == false) {
                      _bathedWellBehaved = null;
                      _bathing.clear();
                    }
                  }),
                ),
                _checklistTile(
                  'Blow dried',
                  _blowDried,
                  (value) => setState(() {
                    _blowDried = value;
                    if (value == false && _hvDryer == true) _hvDryer = false;
                  }),
                ),
                _checklistTile(
                  'Usual groom carried out',
                  _usualGroom,
                  (value) => setState(() => _usualGroom = value),
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

                // Two-state on purpose, unlike the checklist above: these ask
                // whether it happened at this visit, so an unticked box is an
                // answer rather than a silence — same as the matting flags.
                const SectionHeader(title: 'Fleas and ticks'),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _fleas,
                  onChanged: (value) => setState(() => _fleas = value ?? false),
                  title: const Text('Fleas treated'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _ticks,
                  onChanged: (value) => setState(() => _ticks = value ?? false),
                  title: const Text('Ticks removed'),
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
                // Typed, at Jess's request — *"Can the bathing and high
                // velocity dryer be option to type as not quite as simple as
                // yes or no well behaved"*. The old yes/no answers still show
                // here as words on an old card, so nothing already recorded is
                // lost. Blank means not recorded, the same third state the
                // dropdowns carried.
                MojoTextField(
                  controller: _bathing,
                  decoration: const InputDecoration(
                    labelText: 'Bathing',
                    helperText: 'How it went, in your words. Writing anything '
                        'here ticks Bathed above.',
                  ),
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  // The same entailment the dropdown carried: an answer about
                  // how the bath went means a bath went.
                  onChanged: (value) {
                    if (value.trim().isNotEmpty && _bathed != true) {
                      setState(() => _bathed = true);
                    }
                  },
                ),
                const SizedBox(height: 12),
                // Nothing is inferred from this one: "dried off in the crate"
                // is drying without a blow dry, so the words say nothing
                // about the Blow dried box.
                MojoTextField(
                  controller: _drying,
                  decoration: const InputDecoration(
                    labelText: 'Drying',
                    helperText: 'Dryer, crate, towel — and how they took it.',
                  ),
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                ),
                // The shampoo box used to sit here. Jess: "the shampoo used is
                // a bit irrelevant so just get rid of it" — anything already
                // typed is still on the server, just no longer asked for.
                const SizedBox(height: 14),
                _equipmentField(),

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
                  'temperament or the daily booking limit. The owner sees it on '
                  'their groom report, in the wording from Settings.',
                  style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
                ),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: _sensitive,
                  decoration: const InputDecoration(
                    labelText: "Anywhere they didn't want to be touched",
                    // Sitting between two owner-visible fields, so it says so
                    // — this one is Jess's working note and stays hers.
                    helperText: 'Staff only — never shown to the owner.',
                  ),
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: _notes,
                  decoration: const InputDecoration(
                    labelText: 'Anything to note',
                    helperText: 'The owner can read this on their groom report.',
                  ),
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                ),

                const SizedBox(height: 28),
                ElevatedButton(
                  onPressed: _busy ? null : _save,
                  child: Text(
                    _busy
                        ? 'SAVING…'
                        : _onTheClock
                            ? 'FINISH & SAVE RECORD'
                            : 'SAVE RECORD',
                  ),
                ),
                if (_onTheClock) ...[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                    child: const Text('KEEP — BACK TO THE TIMER'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Finishing stops the clock and files the visit with the '
                    'time so far. Keeping leaves both exactly as they are.',
                    style: TextStyle(fontSize: 12, color: context.mojo.muted),
                  ),
                ],
              ],
            )),
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
