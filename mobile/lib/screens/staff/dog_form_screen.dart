import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

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
  late final TextEditingController _medicalNotes;
  late final TextEditingController _vet;
  late final TextEditingController _generalNotes;
  late final Map<String, TextEditingController> _prefs;

  List<ClientRecord> _clients = const [];
  List<Breed> _breeds = const [];
  int? _clientId;
  int? _breedId;
  String _temperament = 'EASY';
  String _sex = '';
  bool _isNeutered = false;
  bool _isActive = true;
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
    _temperamentNotes = TextEditingController(text: dog?.temperamentNotes ?? '');
    _medicalNotes = TextEditingController(text: dog?.medicalNotes ?? '');
    _vet = TextEditingController(text: dog?.vet ?? '');
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
    _isNeutered = dog?.isNeutered ?? false;
    _isActive = dog?.isActive ?? true;
    _dateOfBirth = dog?.dateOfBirth;
    _loadReferenceData();
  }

  @override
  void dispose() {
    for (final controller in [
      _name, _breedOther, _groomMinutes, _price, _scheduleWeeks,
      _temperamentNotes, _medicalNotes, _vet, _generalNotes, ..._prefs.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadReferenceData() async {
    try {
      final clients = await _data.getClients();
      final breeds = await _data.getBreeds();
      if (!mounted) return;
      setState(() {
        _clients = clients;
        _breeds = breeds;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showSnack(context, error.toString(), isError: true);
    }
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
      // Null means "inherit from the breed" — send it explicitly so clearing
      // an override actually clears it.
      'groom_minutes': asInt(_groomMinutes),
      'price': _price.text.trim().isEmpty ? null : _price.text.trim(),
      'schedule_weeks': asInt(_scheduleWeeks),
      'medical_notes': _medicalNotes.text.trim(),
      'vet': _vet.text.trim(),
      'general_notes': _generalNotes.text.trim(),
      for (final entry in _prefs.entries) entry.key: entry.value.text.trim(),
    };

    try {
      if (_isEditing) {
        await _data.updateDog(widget.dog!.id, body);
      } else {
        await _data.createDog(body);
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
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: "Dog's name *"),
              textCapitalization: TextCapitalization.words,
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int?>(
              initialValue: _breedId,
              decoration: const InputDecoration(labelText: 'Breed'),
              isExpanded: true,
              items: [
                const DropdownMenuItem(value: null, child: Text('Not listed / cross')),
                for (final breed in _breeds)
                  DropdownMenuItem(value: breed.id, child: Text(breed.name)),
              ],
              onChanged: (value) => setState(() => _breedId = value),
            ),
            if (_breedId == null) ...[
              const SizedBox(height: 14),
              TextFormField(
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isNeutered,
              onChanged: (value) => setState(() => _isNeutered = value),
              title: const Text('Neutered'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isActive,
              onChanged: (value) => setState(() => _isActive = value),
              title: const Text('Active'),
              subtitle: const Text('Inactive dogs are hidden from Doguments'),
            ),

            const SectionHeader(title: 'Temperament'),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Drives the per-day booking limit. Never shown to the client.',
                style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
              ),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'EASY', label: Text('Easy')),
                ButtonSegment(value: 'FIDGETY', label: Text('Fidgety')),
                ButtonSegment(value: 'FEISTY', label: Text('Feisty')),
              ],
              selected: {_temperament},
              onSelectionChanged: (value) => setState(() => _temperament = value.first),
            ),
            const SizedBox(height: 14),
            TextFormField(
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
                style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
              ),
            ),
            TextFormField(
              controller: _groomMinutes,
              decoration: InputDecoration(
                labelText: 'Groom time (minutes)',
                hintText: breed?.avgGroomMinutes.toString(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _price,
              decoration: InputDecoration(
                labelText: 'Price (£)',
                hintText: breed?.avgPrice.toStringAsFixed(2),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _scheduleWeeks,
              decoration: InputDecoration(
                labelText: 'Groom every (weeks)',
                hintText: breed?.avgScheduleWeeks.toString(),
              ),
              keyboardType: TextInputType.number,
            ),

            const SectionHeader(title: 'Grooming preferences'),
            for (final entry in _prefs.entries) ...[
              TextFormField(
                controller: entry.value,
                decoration: InputDecoration(labelText: _prefLabel(entry.key)),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 14),
            ],

            const SectionHeader(title: 'Notes'),
            TextFormField(
              controller: _medicalNotes,
              decoration: const InputDecoration(labelText: 'Medical notes'),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _vet,
              decoration: const InputDecoration(labelText: 'Vet'),
              maxLines: 2,
            ),
            const SizedBox(height: 14),
            TextFormField(
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
