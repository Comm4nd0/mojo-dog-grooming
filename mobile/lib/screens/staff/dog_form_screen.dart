import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/dog_silhouette.dart';
import '../../widgets/searchable_picker.dart';
import '../../widgets/service_picker.dart';
import '../../widgets/temperament_picker.dart';
import '../../widgets/weekday_picker.dart';
import 'problem_area_editor.dart';

/// Add or edit a dog.
///
/// Groom time, price and interval are left blank by default so the dog
/// inherits its breed's figures. The form shows what it would inherit as a
/// hint, so it's obvious what filling the box would override.
class DogFormScreen extends StatefulWidget {
  const DogFormScreen({super.key, this.dog, this.presetClientId});

  final Dog? dog;
  final int? presetClientId;

  @override
  State<DogFormScreen> createState() => _DogFormScreenState();
}

class _DogFormScreenState extends State<DogFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _data = getIt<DataService>();

  late final TextEditingController _name;
  late final TextEditingController _breedOther;
  late final TextEditingController _groomMinutes;
  late final TextEditingController _price;
  late final TextEditingController _scheduleWeeks;
  late final TextEditingController _temperamentNotes;
  // Absent means the server withheld it, which only happens for a client —
  // and a client cannot reach this form at all. False is the right start.
  late bool _requiresRestraint;
  late final TextEditingController _colour;
  late final TextEditingController _microchip;
  late final TextEditingController _allergies;
  late final TextEditingController _medications;
  late final TextEditingController _medicalIssues;
  late final TextEditingController _vaccinations;
  late final TextEditingController _medicalNotes;
  late final TextEditingController _vet;
  late final TextEditingController _lastVetVisit;
  late final TextEditingController _ownerGrooming;
  late final TextEditingController _generalNotes;
  late final Map<String, TextEditingController> _prefs;

  List<ClientRecord> _clients = const [];
  List<Breed> _breeds = const [];
  List<TemperamentGrade> _grades = TemperamentChipLabels.fallback;
  List<ServiceItem> _services = const [];
  Set<int> _defaultServices = {};
  int? _clientId;
  int? _breedId;
  String _temperament = 'EASY';
  String _sex = '';
  bool? _isNeutered;
  bool _isActive = true;
  bool _isAdHoc = false;
  bool _isDaycare = false;
  Set<int> _daycareDays = {};
  DateTime? _dateOfBirth;
  bool _loading = true;
  bool _busy = false;

  bool get _isEditing => widget.dog != null;

  @override
  void initState() {
    super.initState();
    final dog = widget.dog;
    _name = TextEditingController(text: dog?.name ?? '');
    _breedOther = TextEditingController(text: dog?.breedOther ?? '');
    _groomMinutes = TextEditingController(text: dog?.groomMinutesOverride?.toString() ?? '');
    _price = TextEditingController(text: dog?.priceOverride?.toString() ?? '');
    _scheduleWeeks = TextEditingController(text: dog?.scheduleWeeksOverride?.toString() ?? '');
    _isAdHoc = dog?.isAdHoc ?? false;
    _isDaycare = dog?.isDaycare ?? false;
    _daycareDays = {...?dog?.daycareDays};
    _temperamentNotes = TextEditingController(text: dog?.temperamentNotes ?? '');
    _requiresRestraint = dog?.requiresRestraint ?? false;
    _colour = TextEditingController(text: dog?.colour ?? '');
    _microchip = TextEditingController(text: dog?.microchipNumber ?? '');
    _allergies = TextEditingController(text: dog?.allergies ?? '');
    _medications = TextEditingController(text: dog?.medications ?? '');
    _medicalIssues = TextEditingController(text: dog?.medicalIssues ?? '');
    _vaccinations = TextEditingController(text: dog?.vaccinations ?? '');
    _medicalNotes = TextEditingController(text: dog?.medicalNotes ?? '');
    _vet = TextEditingController(text: dog?.vet ?? '');
    _lastVetVisit = TextEditingController(text: dog?.lastVetVisit ?? '');
    _ownerGrooming = TextEditingController(text: dog?.ownerGrooming ?? '');
    _generalNotes = TextEditingController(text: dog?.generalNotes ?? '');
    _prefs = {
      'pref_body': TextEditingController(text: dog?.prefBody ?? ''),
      'pref_feet': TextEditingController(text: dog?.prefFeet ?? ''),
      'pref_tail': TextEditingController(text: dog?.prefTail ?? ''),
      'pref_face': TextEditingController(text: dog?.prefFace ?? ''),
      'pref_ears': TextEditingController(text: dog?.prefEars ?? ''),
      'pref_skirt': TextEditingController(text: dog?.prefSkirt ?? ''),
    };
    _clientId = dog?.clientId ?? widget.presetClientId;
    _breedId = dog?.breedId;
    _temperament = dog?.temperament ?? 'EASY';
    _sex = dog?.sex ?? '';
    _isNeutered = dog?.isNeutered;
    _defaultServices = {...?dog?.defaultServices};
    _isActive = dog?.isActive ?? true;
    _dateOfBirth = dog?.dateOfBirth;
    _loadReferenceData();
  }

  @override
  void dispose() {
    for (final controller in [
      _name, _breedOther, _groomMinutes, _price, _scheduleWeeks,
      _temperamentNotes, _colour, _microchip, _allergies, _medications,
      _medicalIssues, _vaccinations, _medicalNotes, _vet, _lastVetVisit,
      _ownerGrooming, _generalNotes, ..._prefs.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadReferenceData() async {
    try {
      final clients = await _data.getClients();
      final breeds = await _data.getBreeds();
      // Jess's own names for the handling grades. Falls back to the seed
      // wording rather than failing the whole form if this one call errors.
      List<TemperamentGrade> grades = TemperamentChipLabels.fallback;
      try {
        grades = await _data.getTemperamentGrades();
      } catch (_) {
        // Left on the fallback.
      }
      List<ServiceItem> services = const [];
      try {
        services = await _data.getServices();
      } catch (_) {
        // The rest of the form is still usable without the catalogue.
      }
      if (!mounted) return;
      setState(() {
        _clients = clients;
        _breeds = breeds;
        if (grades.isNotEmpty) _grades = grades;
        _services = services;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  /// Sore or sensitive areas marked here but not yet saved.
  ///
  /// They can't be posted as they're added: on a new dog there is no id to
  /// hang them off until the form is saved. Jess asked to be able to record
  /// them "if known" while adding the dog, which is exactly when the owner is
  /// standing there telling her.
  final List<ProblemAreaDraft> _areaDrafts = [];

  Widget _problemAreasSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Sore or sensitive areas',
          action: TextButton(
            onPressed: _addArea,
            child: const Text('ADD'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _areaDrafts.isEmpty
                ? _isEditing
                    ? 'Anything already marked is on the profile. Adding here adds to it.'
                    : "Mark anywhere they don't like being touched, if you know."
                : 'Saved with the dog. Not visible to the client.',
            style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
          ),
        ),
        for (final (index, draft) in _areaDrafts.indexed)
          ListTile(
            dense: true,
            leading: DogSilhouetteThumbnail(cells: draft.cells),
            title: Text(draft.reason),
            subtitle: Text(
              '${draft.cells.length} square${draft.cells.length == 1 ? '' : 's'}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Remove',
              onPressed: () => setState(() => _areaDrafts.removeAt(index)),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _addArea() async {
    final draft = await Navigator.of(context).push<ProblemAreaDraft>(
      MaterialPageRoute(
        builder: (_) => ProblemAreaEditor.draft(dogName: _name.text.trim()),
      ),
    );
    if (draft != null) setState(() => _areaDrafts.add(draft));
  }

  Breed? get _selectedBreed {
    if (_breedId == null) return null;
    for (final breed in _breeds) {
      if (breed.id == _breedId) return breed;
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_clientId == null) {
      showSnack(context, 'Choose which client this dog belongs to.', isError: true);
      return;
    }
    setState(() => _busy = true);

    int? asInt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : int.tryParse(c.text.trim());

    final body = <String, dynamic>{
      'client': _clientId,
      'name': _name.text.trim(),
      'breed': _breedId,
      'breed_other': _breedOther.text.trim(),
      'date_of_birth': _dateOfBirth?.toIso8601String().split('T').first,
      'sex': _sex,
      'is_neutered': _isNeutered,
      'is_active': _isActive,
      'temperament': _temperament,
      'temperament_notes': _temperamentNotes.text.trim(),
      'requires_restraint': _requiresRestraint,
      // Null means "inherit from the breed" — send it explicitly so clearing
      // an override actually clears it.
      'groom_minutes': asInt(_groomMinutes),
      'price': _price.text.trim().isEmpty ? null : _price.text.trim(),
      'schedule_weeks': asInt(_scheduleWeeks),
      'is_ad_hoc': _isAdHoc,
      'is_daycare': _isDaycare,
      // Sorted here as well as on the server — the server is the guarantee,
      // this is so the field Jess just filled in reads back in order.
      'daycare_days': (_daycareDays.toList()..sort()),
      'colour': _colour.text.trim(),
      'microchip_number': _microchip.text.trim(),
      'allergies': _allergies.text.trim(),
      'medications': _medications.text.trim(),
      'medical_issues': _medicalIssues.text.trim(),
      'vaccinations': _vaccinations.text.trim(),
      'medical_notes': _medicalNotes.text.trim(),
      'vet': _vet.text.trim(),
      'last_vet_visit': _lastVetVisit.text.trim(),
      'owner_grooming': _ownerGrooming.text.trim(),
      'general_notes': _generalNotes.text.trim(),
      'default_services': _defaultServices.toList(),
      for (final entry in _prefs.entries) entry.key: entry.value.text.trim(),
    };

    try {
      final int dogId;
      if (_isEditing) {
        await _data.updateDog(widget.dog!.id, body);
        dogId = widget.dog!.id;
      } else {
        dogId = (await _data.createDog(body)).id;
      }

      // Areas marked on the form go up now the dog has an id. Deliberately
      // after the dog is saved and not rolled back with it: if one of these
      // fails, the dog is still recorded and Jess is told which areas didn't
      // make it, rather than losing the whole form.
      final failed = <String>[];
      for (final draft in _areaDrafts) {
        try {
          await _data.createProblemArea(
            dogId: dogId,
            gridCells: draft.cells,
            reason: draft.reason,
          );
        } catch (_) {
          failed.add(draft.reason);
        }
      }
      if (!mounted) return;
      if (failed.isNotEmpty) {
        showSnack(
          context,
          'Dog saved, but ${failed.length} marked area'
          '${failed.length == 1 ? '' : 's'} did not. Add again from the profile.',
          isError: true,
        );
      }
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(_isEditing ? 'Edit dog' : 'Add dog')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final breed = _selectedBreed;
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit ${widget.dog!.name}' : 'Add dog')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            DropdownButtonFormField<int>(
              initialValue: _clientId,
              decoration: const InputDecoration(labelText: 'Owner *'),
              isExpanded: true,
              items: [
                for (final client in _clients)
                  DropdownMenuItem(
                    value: client.id,
                    child: Text('${client.fullName} (${client.uid})',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) => setState(() => _clientId = value),
              validator: (value) => value == null ? 'Choose an owner' : null,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _name,
              decoration: const InputDecoration(labelText: "Dog's name *"),
              textCapitalization: TextCapitalization.words,
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 14),
            // 224 breeds is far too many to scroll a dropdown through, which
            // is what Jess ran into. Clearing the field is how you say "not
            // listed / cross" and reveal the free-text box below.
            SearchablePicker<Breed>(
              items: _breeds,
              selected: _selectedBreed,
              decoration: const InputDecoration(
                labelText: 'Breed',
                hintText: 'Start typing, or leave blank for a cross',
              ),
              labelOf: (breed) => breed.name,
              subtitleOf: (breed) => breed.coatType,
              matches: (breed, query) =>
                  breed.name.toLowerCase().contains(query.toLowerCase()),
              emptyLabel: 'Not on the list — leave this blank and use the box below',
              onSelected: (breed) {
                setState(() => _breedId = breed?.id);
                if (breed != null) _applyBreedStyles(breed);
              },
            ),
            if (_breedId == null) ...[
              const SizedBox(height: 14),
              MojoTextField(
                controller: _breedOther,
                decoration: const InputDecoration(
                  labelText: 'Breed (free text)',
                  helperText: 'Used when the breed is a cross or not on the list',
                ),
                textCapitalization: TextCapitalization.words,
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _sex.isEmpty ? null : _sex,
                    decoration: const InputDecoration(labelText: 'Sex'),
                    items: const [
                      DropdownMenuItem(value: 'M', child: Text('Male')),
                      DropdownMenuItem(value: 'F', child: Text('Female')),
                    ],
                    onChanged: (value) => setState(() => _sex = value ?? ''),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _dateOfBirth ?? DateTime.now(),
                        firstDate: DateTime(1995),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) setState(() => _dateOfBirth = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Date of birth'),
                      child: Text(
                        _dateOfBirth == null ? 'Not set' : formatDate(_dateOfBirth!),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: MojoTextField(
                    controller: _colour,
                    decoration: const InputDecoration(labelText: 'Colour'),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: MojoTextField(
                    controller: _microchip,
                    decoration: const InputDecoration(labelText: 'Microchip number'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            // Three states, not a switch. A switch can only be on or off, so
            // a dog nobody had asked about looked exactly like one confirmed
            // entire — and the profile would have tagged it "Intact".
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                'Neutered or spayed',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            SegmentedButton<bool?>(
              segments: const [
                ButtonSegment(value: true, label: Text('Done')),
                ButtonSegment(value: false, label: Text('Intact')),
                ButtonSegment(value: null, label: Text("Don't know")),
              ],
              selected: {_isNeutered},
              onSelectionChanged: (value) => setState(() => _isNeutered = value.first),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isActive,
              onChanged: (value) => setState(() => _isActive = value),
              title: const Text('Active'),
              subtitle: const Text('Inactive dogs are hidden from Doguments'),
            ),

            const SectionHeader(title: 'Temperament'),
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Drives the per-day booking limit. Never shown to the client.',
                style: TextStyle(fontSize: 12, color: context.mojo.muted),
              ),
            ),
            TemperamentPicker(
              grades: _grades,
              selected: _temperament,
              onSelected: (code) =>
                  setState(() => _temperament = code ?? _temperament),
            ),
            const SizedBox(height: 6),
            // Jess's request. Sits with the handling notes rather than with
            // the consents: the RESTRAINT consent is the owner agreeing a
            // muzzle *may* be used, this is Jess recording that this dog
            // needs one. Staff-only, like the rest of this section.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _requiresRestraint,
              onChanged: (value) => setState(() => _requiresRestraint = value),
              title: const Text('Restraints required'),
              subtitle: const Text('A collar or muzzle is needed to groom safely'),
            ),
            const SizedBox(height: 8),
            MojoTextField(
              controller: _temperamentNotes,
              decoration: const InputDecoration(labelText: 'Handling notes'),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),

            const SectionHeader(title: 'Groom time, price and schedule'),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                breed == null
                    ? 'No breed selected, so fill these in directly.'
                    : 'Leave blank to use the ${breed.name} defaults.',
                style: TextStyle(fontSize: 12, color: context.mojo.muted),
              ),
            ),
            MojoTextField(
              controller: _groomMinutes,
              decoration: InputDecoration(
                labelText: 'Groom time (minutes)',
                hintText: breed?.avgGroomMinutes.toString(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _price,
              decoration: InputDecoration(
                labelText: 'Price (£)',
                hintText: breed?.avgPrice.toStringAsFixed(2),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _scheduleWeeks,
              decoration: InputDecoration(
                labelText: 'Groom every (weeks)',
                hintText: breed?.avgScheduleWeeks.toString(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 6),
            // The interval above stays editable and stays in use: it is what
            // answers "when is this one next due" when Jess asks about the dog
            // directly. What the switch stops is the overdue list volunteering
            // a deadline nobody agreed to.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isAdHoc,
              onChanged: (value) => setState(() => _isAdHoc = value),
              title: const Text('Ad hoc'),
              subtitle: const Text('Comes when the owner asks — keep off the due list'),
            ),

            const SectionHeader(title: 'Daycare'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isDaycare,
              onChanged: (value) => setState(() => _isDaycare = value),
              title: const Text('Daycare dog'),
            ),
            // Shown whether or not the tickbox is on, and the tickbox does not
            // clear them: a dog can be signed up before the days are settled,
            // and days typed in then wiped by a stray tap is worse than a
            // list sitting quietly under an unticked box.
            const SizedBox(height: 4),
            WeekdayPicker(
              selected: _daycareDays,
              onChanged: (days) => setState(() => _daycareDays = days),
            ),

            const SectionHeader(title: 'Grooming preferences'),
            // Services first, as Jess asked — "at the top of the list would we
            // be able to have a drop down list of services/type of groom".
            // Prices are hidden here: this is what the dog usually has, not
            // what a particular visit costs.
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'What this dog usually has. Pre-fills a new booking.',
                style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
              ),
            ),
            ServicePicker(
              services: _services,
              selected: _defaultServices,
              showPrices: false,
              onChanged: (next) => setState(() => _defaultServices = next),
            ),
            const SizedBox(height: 14),
            for (final entry in _prefs.entries) ...[
              MojoTextField(
                controller: entry.value,
                decoration: InputDecoration(labelText: _prefLabel(entry.key)),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 14),
            ],

            _problemAreasSection(),

            const SectionHeader(title: 'Health'),
            MojoTextField(
              controller: _allergies,
              decoration: const InputDecoration(labelText: 'Allergies'),
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _medications,
              decoration: const InputDecoration(labelText: 'Medication'),
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _medicalIssues,
              decoration: const InputDecoration(labelText: 'Known medical issues'),
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _vaccinations,
              decoration: const InputDecoration(labelText: 'Vaccinations, and when'),
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _medicalNotes,
              decoration: const InputDecoration(labelText: 'Other medical notes'),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _vet,
              decoration: const InputDecoration(labelText: 'Vet'),
              maxLines: 2,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _lastVetVisit,
              decoration: const InputDecoration(labelText: 'What the last vet trip was for'),
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),

            const SectionHeader(title: 'Notes'),
            MojoTextField(
              controller: _ownerGrooming,
              decoration: const InputDecoration(
                labelText: 'What the owner does themselves, and how often',
              ),
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _generalNotes,
              decoration: const InputDecoration(labelText: 'General notes'),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),

            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'SAVING…' : 'SAVE DOG'),
            ),
          ],
        ),
      ),
    );
  }

  /// Start this dog's grooming preferences off from its breed's usual styles.
  ///
  /// **Only fills blanks.** Picking a breed must never wipe something already
  /// typed — a client's own instructions outrank the breed's usual, and a
  /// mis-tap on the breed picker should not silently rewrite them. That also
  /// makes it safe when editing an existing dog.
  ///
  /// Nothing happens silently either: if it filled anything in, it says so, so
  /// Jess knows where the words came from and can change them.
  void _applyBreedStyles(Breed breed) {
    final defaults = breed.preferenceDefaults;
    if (defaults.isEmpty) return;

    final filled = <String>[];
    for (final entry in defaults.entries) {
      final controller = _prefs[entry.key];
      if (controller == null || controller.text.trim().isNotEmpty) continue;
      controller.text = entry.value;
      filled.add(_prefLabel(entry.key).toLowerCase());
    }
    if (filled.isEmpty || !mounted) return;

    setState(() {});
    showSnack(
      context,
      'Filled in ${filled.join(', ')} from the ${breed.name} record — change '
      'anything that is different for this dog.',
    );
  }

  static String _prefLabel(String key) => switch (key) {
        'pref_body' => 'Body',
        'pref_feet' => 'Feet shape',
        'pref_tail' => 'Tail',
        'pref_face' => 'Face',
        'pref_ears' => 'Ears',
        'pref_skirt' => 'Skirt',
        _ => key,
      };
}
