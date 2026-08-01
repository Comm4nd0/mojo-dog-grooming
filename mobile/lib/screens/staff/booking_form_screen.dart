import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/duration_picker.dart';
import '../../widgets/searchable_picker.dart';

/// Create or edit a booking.
///
/// Before saving, the form asks the server for warnings — temperament limits,
/// opening hours, overlaps — and shows them in a confirm dialog. They never
/// block: Jess decides, the app only makes sure she knows.
class BookingFormScreen extends StatefulWidget {
  const BookingFormScreen({
    super.key,
    this.appointment,
    required this.initialDate,
    this.initialDogId,
  });

  final Appointment? appointment;
  final DateTime initialDate;

  /// Pre-selects a dog on a new booking — set when arriving from that dog's
  /// profile. Ignored when editing, where the appointment supplies it.
  final int? initialDogId;

  @override
  State<BookingFormScreen> createState() => _BookingFormScreenState();
}

class _BookingFormScreenState extends State<BookingFormScreen> {
  final _data = getIt<DataService>();
  final _notes = TextEditingController();

  List<DogSummary> _dogs = const [];
  int? _dogId;
  DateTime _date = DateTime.now();
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  int _durationMinutes = 90;
  String _bookingType = 'ADHOC';
  String _serviceType = ServiceType.groom;
  AppSettings? _settings;
  String _status = 'BOOKED';

  // A repeating booking creates a BookingSeries, which materialises
  // appointments ahead at this interval.
  bool _repeat = false;
  int _repeatWeeks = 6;

  bool _loading = true;
  bool _busy = false;

  bool get _isEditing => widget.appointment != null;

  /// How long a nail trim runs. Falls back to 20 only so the picker lands
  /// somewhere sensible when Jess hasn't set a length in Settings — the
  /// server's check still warns that the figure isn't hers.
  int get _nailVisitMinutes => _settings?.nailVisitMinutes ?? 20;

  @override
  void initState() {
    super.initState();
    final appointment = widget.appointment;
    if (appointment != null) {
      _dogId = appointment.dogId;
      _date = appointment.startAt;
      _time = TimeOfDay.fromDateTime(appointment.startAt);
      _durationMinutes = appointment.durationMinutes;
      _bookingType = appointment.bookingType;
      _serviceType = appointment.serviceType;
      _status = appointment.status;
      _notes.text = appointment.notes;
    } else {
      _date = widget.initialDate;
      _dogId = widget.initialDogId;
    }
    _loadDogs();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadDogs() async {
    try {
      final dogs = await _data.getDogs();
      AppSettings? settings;
      try {
        settings = await _data.getSettings();
      } catch (_) {
        // Only needed to size a nails slot; the slider still works without it.
      }
      if (!mounted) return;
      setState(() {
        _dogs = dogs;
        _settings = settings;
        _loading = false;
        // Size the slot to a dog we were handed — arriving from a dog's
        // profile, say. The field is otherwise left empty on purpose: it used
        // to default to whichever dog sorted first, which was harmless as a
        // dropdown you had to open anyway, but reads as a real choice in a
        // search field and is one mis-tap from booking the wrong dog.
        if (!_isEditing && _dogId != null) {
          _durationMinutes = _selectedDog?.groomMinutes ?? _durationMinutes;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  DogSummary? get _selectedDog {
    for (final dog in _dogs) {
      if (dog.id == _dogId) return dog;
    }
    return null;
  }

  DateTime get _startAt =>
      DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);

  DateTime get _endAt => _startAt.add(Duration(minutes: _durationMinutes));

  Future<void> _save() async {
    if (_dogId == null) {
      showSnack(context, 'Choose a dog first.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final check = await _data.checkBooking(
        dogId: _dogId!,
        startAt: _startAt,
        endAt: _endAt,
        excludeAppointmentId: widget.appointment?.id,
        serviceType: _serviceType,
      );
      if (!mounted) return;

      // Advisory only — "book anyway" is always available.
      final proceed = await showWarningsDialog(context, check);
      if (!proceed) {
        setState(() => _busy = false);
        return;
      }

      if (_isEditing) {
        await _data.updateAppointment(widget.appointment!.id, {
          'dog': _dogId,
          'start_at': _startAt.toUtc().toIso8601String(),
          'end_at': _endAt.toUtc().toIso8601String(),
          'booking_type': _bookingType,
          'service_type': _serviceType,
          'status': _status,
          'notes': _notes.text.trim(),
        });
      } else if (_repeat) {
        await _data.createBookingSeries(
          dogId: _dogId!,
          intervalWeeks: _repeatWeeks,
          startDate: _date,
          preferredTime:
              '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
          notes: _notes.text.trim(),
        );
      } else {
        await _data.createAppointment(
          dogId: _dogId!,
          startAt: _startAt,
          endAt: _endAt,
          bookingType: _bookingType,
          serviceType: _serviceType,
          notes: _notes.text.trim(),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this booking?'),
        content: Text(
          '${widget.appointment!.dogName} on ${formatDate(widget.appointment!.startAt)} '
          'at ${formatTime(widget.appointment!.startAt)}. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DELETE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _data.deleteAppointment(widget.appointment!.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Booking')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final dog = _selectedDog;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit booking' : 'New booking'),
        actions: [
          if (_isEditing)
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          SearchablePicker<DogSummary>(
            items: _dogs,
            selected: _selectedDog,
            decoration: const InputDecoration(
              labelText: 'Dog *',
              hintText: 'Dog, owner or phone number',
            ),
            labelOf: (dog) => dog.name,
            subtitleOf: (dog) => dog.clientFullName,
            matches: (dog, query) => dog.matchesSearch(query),
            emptyLabel: 'No dog matches that',
            onSelected: (dog) {
              setState(() {
                _dogId = dog?.id;
                // Re-size the slot to the newly chosen dog's groom time.
                if (dog != null && !_isEditing) _durationMinutes = dog.groomMinutes;
              });
            },
          ),
          if (dog != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  TemperamentChip(
                    temperament: dog.temperament,
                    label: dog.temperamentDisplay,
                    compact: true,
                  ),
                  InfoTag(label: '${formatDuration(dog.groomMinutes)} usual'),
                  InfoTag(label: formatMoney(dog.price)),
                  InfoTag(label: 'every ${dog.scheduleWeeks}w'),
                ],
              ),
            ),

          const SectionHeader(title: 'When'),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 730)),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Date'),
                    child: Text(formatDate(_date)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: _time,
                      // Keypad first. `input`, not `inputOnly` — Jess asked to
                      // keep the clock face, so the toggle has to stay.
                      initialEntryMode: TimePickerEntryMode.input,
                    );
                    if (picked != null) setState(() => _time = picked);
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Start time'),
                    child: Text(_time.format(context)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: () async {
              final picked = await showDurationPicker(
                context,
                initialMinutes: _durationMinutes,
                title: 'How long for ${dog?.name ?? 'this groom'}?',
              );
              if (picked != null) setState(() => _durationMinutes = picked);
            },
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Duration',
                helperText: 'Ends at ${formatTime(_endAt)}',
              ),
              child: Text(formatDuration(_durationMinutes)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (dog != null)
                  DurationPreset(
                    label: 'Usual (${formatDuration(dog.groomMinutes)})',
                    minutes: dog.groomMinutes,
                    selected: _durationMinutes == dog.groomMinutes,
                    onPick: (value) => setState(() => _durationMinutes = value),
                  ),
                DurationPreset(
                  label: 'Nails (${formatDuration(_nailVisitMinutes)})',
                  minutes: _nailVisitMinutes,
                  selected: _durationMinutes == _nailVisitMinutes,
                  onPick: (value) => setState(() => _durationMinutes = value),
                ),
              ],
            ),
          ),

          const SectionHeader(title: 'Service'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: ServiceType.groom, label: Text('Groom')),
              ButtonSegment(value: ServiceType.nailsFleasTicks, label: Text('Nails/fleas/ticks')),
            ],
            selected: {_serviceType},
            onSelectionChanged: (value) => setState(() {
              _serviceType = value.first;
              // A nail trim is minutes, not hours. Leaving the slider on the
              // dog's groom time would block out most of a morning for it.
              if (_serviceType == ServiceType.nailsFleasTicks) {
                _durationMinutes = _nailVisitMinutes;
                _repeat = false;
              } else {
                _durationMinutes = _selectedDog?.groomMinutes ?? _durationMinutes;
              }
            }),
          ),

          const SectionHeader(title: 'Type'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'FIRST_GROOM', label: Text('First')),
              ButtonSegment(value: 'ADHOC', label: Text('Ad hoc')),
              ButtonSegment(value: 'SCHEDULED', label: Text('Scheduled')),
            ],
            selected: {_bookingType},
            onSelectionChanged: (value) => setState(() => _bookingType = value.first),
          ),

          if (!_isEditing && _serviceType == ServiceType.groom) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _repeat,
              onChanged: (value) => setState(() {
                _repeat = value;
                if (value) {
                  _bookingType = 'SCHEDULED';
                  final dog = _selectedDog;
                  if (dog != null) _repeatWeeks = dog.scheduleWeeks;
                }
              }),
              title: const Text('Repeat this booking'),
              subtitle: const Text('Fills the diary ahead at a fixed interval'),
            ),
            if (_repeat)
              Row(
                children: [
                  const Text('Every'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Slider(
                      value: _repeatWeeks.toDouble().clamp(1, 16),
                      min: 1,
                      max: 16,
                      divisions: 15,
                      label: '$_repeatWeeks weeks',
                      onChanged: (value) => setState(() => _repeatWeeks = value.round()),
                    ),
                  ),
                  Text('$_repeatWeeks wks'),
                ],
              ),
          ],

          if (_isEditing) ...[
            const SectionHeader(title: 'Status'),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: const [
                DropdownMenuItem(value: 'REQUESTED', child: Text('Requested')),
                DropdownMenuItem(value: 'BOOKED', child: Text('Booked')),
                DropdownMenuItem(value: 'CONFIRMED', child: Text('Confirmed')),
                DropdownMenuItem(value: 'IN_PROGRESS', child: Text('In progress')),
                DropdownMenuItem(value: 'COMPLETED', child: Text('Completed')),
                DropdownMenuItem(value: 'CANCELLED', child: Text('Cancelled')),
                DropdownMenuItem(value: 'NO_SHOW', child: Text('No show')),
              ],
              onChanged: (value) => setState(() => _status = value ?? 'BOOKED'),
            ),
          ],

          const SizedBox(height: 20),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Notes'),
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
          ),

          const SizedBox(height: 28),
          ElevatedButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'CHECKING…' : (_isEditing ? 'SAVE CHANGES' : 'BOOK')),
          ),
        ],
      ),
    );
  }
}
