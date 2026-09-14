import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/calendar/timeline_layout.dart';
import '../../widgets/common.dart';
import '../../widgets/duration_picker.dart';
import '../../widgets/searchable_picker.dart';
import '../../widgets/service_picker.dart';
import 'dog_profile_screen.dart';

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
  List<ServiceItem> _services = const [];
  Set<int> _selectedServices = {};
  String _status = 'BOOKED';

  /// Other dogs from the same household to book into the same slot — Jess:
  /// *"as usually people book all their dogs together for a groom, can it be
  /// made easy to 'share an appointment'?"*. They go in as **one visit**
  /// with one length: she grooms them interleaved — one bathing while the
  /// other dries — so the time they are in is neither any one dog's groom
  /// time nor the sum, and it is hers to say. Each dog still gets its own
  /// booking and its own price.
  Set<int> _extraDogIds = {};

  /// Whether Jess has set the length herself. Until she does, ticking a
  /// companion re-sizes the visit to the dogs' usual times added up — a
  /// starting point, not an answer — and once she has, nothing overwrites it.
  bool _durationTouched = false;

  /// Editing one dog of a visit: whether a new start or end goes to the
  /// others too. On by default, because that is the whole point of a visit
  /// — but a switch she can see, never a side effect.
  bool _applyToVisit = true;

  /// The same owner's other bookings on this day that are not yet in a
  /// visit — offered for linking when editing a booking that is not in one
  /// either. Empty unless both are true.
  List<Appointment> _linkable = const [];
  final Set<int> _linkIds = {};

  /// Once linked, whether the others take this booking's start and end.
  /// On by default: the reason to link is almost always that the visit's
  /// length is wrong, and it is this form's figure that is right.
  bool _reshapeLinked = true;

  // A repeating booking creates a BookingSeries, which materialises
  // appointments ahead at this interval.
  bool _repeat = false;
  int _repeatWeeks = 6;

  bool _loading = true;
  bool _busy = false;

  bool get _isEditing => widget.appointment != null;

  /// Editing a booking that is part of a household visit with other dogs.
  bool get _isVisitEdit => widget.appointment?.isSharedVisit ?? false;

  /// Booking several dogs in together, as one visit.
  bool get _isVisit => _extraDogIds.isNotEmpty;

  /// The dogs' usual groom times added up — the visit's starting length.
  int get _usualTimesSummed {
    final dog = _selectedDog;
    var total = dog == null ? _durationMinutes : dog.groomMinutes;
    for (final extra in _extraDogs) {
      total += extra.groomMinutes;
    }
    return total;
  }

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
      _selectedServices = {...appointment.serviceIds};
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
      List<ServiceItem> services = const [];
      try {
        services = await _data.getServices();
      } catch (_) {
        // The form still works without the catalogue; a booking with no
        // services attached behaves exactly as it did before it existed.
      }
      AppSettings? settings;
      try {
        settings = await _data.getSettings();
      } catch (_) {
        // Only needed to size a nails slot; the slider still works without it.
      }
      // Bookings this one could be linked with: same owner, same day, in
      // no visit yet. Only for a booking that is in no visit itself.
      List<Appointment> linkable = const [];
      final existing = widget.appointment;
      if (existing != null && existing.groupId == null) {
        try {
          final day = DateTime(existing.startAt.year, existing.startAt.month, existing.startAt.day);
          final sameDay = await _data.getAppointments(from: day, to: day);
          linkable = [
            for (final other in sameDay)
              if (other.id != existing.id &&
                  other.clientId == existing.clientId &&
                  other.groupId == null &&
                  kLinkableStatuses.contains(other.status))
                other,
          ]..sort((a, b) => a.startAt.compareTo(b.startAt));
        } catch (_) {
          // The form works without the offer.
        }
      }
      if (!mounted) return;
      setState(() {
        _dogs = dogs;
        _services = services;
        _settings = settings;
        _linkable = linkable;
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

  /// The same owner's other dogs, offered for booking into this slot.
  List<DogSummary> get _householdDogs {
    final dog = _selectedDog;
    if (dog == null || _isEditing) return const [];
    return [
      for (final other in _dogs)
        if (other.clientId == dog.clientId && other.id != dog.id && other.isActive)
          other,
    ];
  }

  List<DogSummary> get _extraDogs =>
      [for (final d in _dogs) if (_extraDogIds.contains(d.id)) d];

  DogSummary? get _selectedDog {
    for (final dog in _dogs) {
      if (dog.id == _dogId) return dog;
    }
    return null;
  }

  DateTime get _startAt =>
      DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);

  DateTime get _endAt => _startAt.add(Duration(minutes: _durationMinutes));

  /// Tick whatever this dog usually has, so the common booking is one tap.
  Future<void> _prefillFromDog(int dogId) async {
    try {
      final dog = await _data.getDog(dogId);
      if (!mounted || dog.defaultServices.isEmpty) return;
      setState(() => _selectedServices = {...dog.defaultServices});
      _resizeFromServices();
    } catch (_) {
      // Nothing pre-filled; Jess ticks them herself.
    }
  }

  /// Ask the server what this combination costs and how long it takes.
  ///
  /// The same resolver the booking itself will use, so what the form shows is
  /// what gets saved — rather than the app doing its own arithmetic and
  /// disagreeing with the server about an unpriced service.
  Future<void> _resizeFromServices() async {
    final dogId = _dogId;
    if (dogId == null) return;
    try {
      final check = await _data.checkBooking(
        dogId: dogId,
        startAt: _startAt,
        excludeAppointmentId: widget.appointment?.id,
        serviceType: _serviceType,
        serviceIds: _selectedServices.toList(),
      );
      final end = check.suggestedEndAt;
      if (!mounted || end == null) return;
      // A visit's length is the household's, not this dog's services'.
      if (_isVisit || _durationTouched) return;
      setState(() => _durationMinutes = end.difference(_startAt).inMinutes);
    } catch (_) {
      // Leave the duration as it is rather than guessing.
    }
  }

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
        // The rest of the visit overlaps this dog on purpose.
        excludeGroupId: _applyToVisit || _isVisitEdit ? widget.appointment?.groupId : null,
        serviceType: _serviceType,
        serviceIds: _selectedServices.toList(),
      );

      // The companions' warnings too, so a bitey second dog on a full day is
      // said out loud before anything is created. Deduplicated on the message
      // and prefixed with the dog, or two dogs from one household warn twice
      // in the same words. What no check can see is the overlap between the
      // dogs being booked together — none of them exist yet — and that
      // overlap is the point, not a mistake.
      final warnings = [...check.warnings];
      for (final extra in _extraDogs) {
        final extraCheck = await _data.checkBooking(
          dogId: extra.id,
          startAt: _startAt,
          endAt: _endAt,
          serviceType: _serviceType,
        );
        for (final warning in extraCheck.warnings) {
          final message = '${extra.name}: ${warning.message}';
          if (!warnings.any((w) => w.message == message)) {
            warnings.add(BookingWarning(code: warning.code, message: message));
          }
        }
      }
      if (!mounted) return;

      // Advisory only — "book anyway" is always available.
      final proceed = await showWarningsDialog(
        context,
        BookingCheck(
          warnings: warnings,
          suggestedEndAt: check.suggestedEndAt,
          suggestedPrice: check.suggestedPrice,
        ),
      );
      if (!proceed) {
        setState(() => _busy = false);
        return;
      }

      if (_isEditing) {
        final original = widget.appointment!;
        await _data.updateAppointment(original.id, {
          'dog': _dogId,
          'start_at': _startAt.toUtc().toIso8601String(),
          'end_at': _endAt.toUtc().toIso8601String(),
          'booking_type': _bookingType,
          'service_type': _serviceType,
          'services': _selectedServices.toList(),
          'status': _status,
          'notes': _notes.text.trim(),
        });
        // Linking bookings already in the diary into a visit, and — if she
        // left the switch on — giving them this booking's start and end.
        if (_linkIds.isNotEmpty) {
          final members = await _data.groupAppointments([original.id, ..._linkIds]);
          final groupId = members.isEmpty ? null : members.first.groupId;
          final names = [
            for (final other in _linkable)
              if (_linkIds.contains(other.id)) other.dogName,
          ].join(', ');
          if (_reshapeLinked && groupId != null) {
            await _data.updateBookingGroup(groupId, startAt: _startAt, endAt: _endAt);
            if (mounted) {
              showSnack(
                context,
                'Linked with $names as one visit, '
                '${formatTime(_startAt)} – ${formatTime(_endAt)}.',
              );
            }
          } else if (mounted) {
            showSnack(context, 'Linked with $names as one visit.');
          }
        }
        // Then the rest of the visit, if she asked. Only what actually
        // moved is sent: a new end alone must not re-anchor every start.
        final startMoved = _startAt != original.startAt;
        final endMoved = _endAt != original.endAt;
        final groupId = original.groupId;
        if (_isVisitEdit && _applyToVisit && groupId != null && (startMoved || endMoved)) {
          final visitWarnings = await _data.updateBookingGroup(
            groupId,
            startAt: startMoved ? _startAt : null,
            endAt: endMoved ? _endAt : null,
          );
          if (mounted) {
            final names = original.companionNames.join(', ');
            showSnack(
              context,
              visitWarnings.isEmpty
                  ? 'Changed for $names too.'
                  : 'Changed for $names too — ${visitWarnings.first.message}',
            );
          }
        }
      } else if (_repeat) {
        await _data.createBookingSeries(
          dogId: _dogId!,
          intervalWeeks: _repeatWeeks,
          startDate: _date,
          preferredTime:
              '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
          notes: _notes.text.trim(),
        );
      } else if (_isVisit) {
        // One visit, one length, made together or not at all. The
        // companions carry no services, so the server prices each dog
        // exactly as a booking made alone.
        await _data.bookTogether(
          dogIds: [_dogId!, for (final extra in _extraDogs) extra.id],
          startAt: _startAt,
          endAt: _endAt,
          bookingType: _bookingType,
          serviceType: _serviceType,
          services: _selectedServices.toList(),
          notes: _notes.text.trim(),
        );
        if (mounted) {
          final names = [
            _selectedDog?.name ?? '',
            for (final extra in _extraDogs) extra.name,
          ].where((name) => name.isNotEmpty).join(', ');
          showSnack(context, 'Booked in together: $names, ${formatDuration(_durationMinutes)}.');
        }
      } else {
        await _data.createAppointment(
          dogId: _dogId!,
          startAt: _startAt,
          endAt: _endAt,
          bookingType: _bookingType,
          serviceType: _serviceType,
          serviceIds: _selectedServices.toList(),
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

  /// Offers the first few free gaps, and fills the form in from whichever
  /// Jess picks.
  Future<void> _findNextFree() async {
    final dogId = _dogId;
    if (dogId == null) return;
    setState(() => _busy = true);
    Map<String, dynamic> result;
    try {
      result = await _data.nextAvailable(
        dogId: dogId,
        serviceType: _serviceType,
        serviceIds: _selectedServices.toList(),
        from: _date,
      );
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    // An empty list means different things and the app must not conflate
    // them: no opening hours at all is "set them up", not "fully booked".
    if (result['reason'] == 'no_opening_hours') {
      showSnack(
        context,
        'Set your opening hours in Settings first — the app has nothing to '
        'search.',
        isError: true,
      );
      return;
    }

    final slots = (result['slots'] as List?) ?? const [];
    if (slots.isEmpty) {
      showSnack(context, 'Nothing free in the next couple of months.');
      return;
    }

    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Next free slots',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              subtitle: Text(
                formatDuration((result['minutes'] as num?)?.toInt() ?? _durationMinutes),
              ),
            ),
            const Divider(height: 1),
            for (final slot in slots)
              if (DateTime.tryParse(slot['start_at'].toString())?.toLocal()
                  case final start?)
                ListTile(
                  leading: Icon(Icons.event_available_outlined,
                      color: sheetContext.mojo.accent),
                  title: Text(formatTime(start)),
                  subtitle: Text('${slot['weekday']} ${formatDate(start)}'),
                  onTap: () => Navigator.pop(sheetContext, start),
                ),
            if (result['exhausted'] == true)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Nothing else free before then.',
                  style: TextStyle(fontSize: 12.5, color: sheetContext.mojo.muted),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (picked != null) {
      setState(() {
        _date = picked;
        _time = TimeOfDay.fromDateTime(picked);
      });
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
          // The paw Jess remembered — *"I thought there was a dog paw that I
          // could click on individual bookings that took me to the dogs
          // profile?"*. There was, on the month view's list, and the day and
          // week views open here instead, where there was none. A block on
          // the time axis is too small to carry a second target, so the
          // profile is one tap on from it rather than on it.
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.pets_outlined),
              tooltip: 'Dog profile',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DogProfileScreen(dogId: widget.appointment!.dogId),
                ),
              ),
            ),
          if (_isEditing)
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: PageBody(child: ListView(
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
                // A different owner's household — the old companions don't
                // carry over.
                _extraDogIds = {};
                // Re-size the slot to the newly chosen dog's groom time.
                if (dog != null && !_isEditing) _durationMinutes = dog.groomMinutes;
              });
              if (dog != null && !_isEditing) _prefillFromDog(dog.id);
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

          // "Usually people book all their dogs together for a groom" — the
          // same household's other dogs, one tap each. Every ticked dog gets
          // its own booking at the same start time, sized to its own groom
          // time, so they overlap in the diary the way she actually works
          // them: one in the bath while the other dries in the crate.
          if (_householdDogs.isNotEmpty) ...[
            const SectionHeader(title: 'Book together'),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                "${dog!.clientFirstName}'s other dog"
                '${_householdDogs.length == 1 ? '' : 's'} — tick to book into '
                'the same visit. One length for all of them; each dog keeps '
                'its own price.',
                style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final other in _householdDogs)
                  FilterChip(
                    label: Text(
                      '${other.name} · ${formatDuration(other.groomMinutes)}',
                    ),
                    selected: _extraDogIds.contains(other.id),
                    onSelected: (ticked) => setState(() {
                      if (ticked) {
                        _extraDogIds.add(other.id);
                        // A shared visit and a repeating series don't mix —
                        // the series materialises one dog. Booked together is
                        // one-off; the repeat can be set up per dog.
                        _repeat = false;
                      } else {
                        _extraDogIds.remove(other.id);
                      }
                      // A starting point for the visit's length, until she
                      // has set one herself.
                      if (!_durationTouched && _serviceType == ServiceType.groom) {
                        _durationMinutes = _usualTimesSummed;
                      }
                    }),
                  ),
              ],
            ),
          ],

          // The same owner's other bookings that day, not in a visit yet.
          // Every household booked before visits existed looks like this,
          // and this is where it gets put right one booking at a time.
          if (_linkable.isNotEmpty) ...[
            const SectionHeader(title: 'Link into one visit'),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                "${dog?.clientFirstName ?? 'This owner'}'s other booking"
                '${_linkable.length == 1 ? '' : 's'} today. Tick to make them '
                'one visit with ${dog?.name ?? 'this dog'}.',
                style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final other in _linkable)
                  FilterChip(
                    label: Text('${other.dogName} · ${other.timeRange}'),
                    selected: _linkIds.contains(other.id),
                    onSelected: (ticked) => setState(() {
                      if (ticked) {
                        _linkIds.add(other.id);
                      } else {
                        _linkIds.remove(other.id);
                      }
                    }),
                  ),
              ],
            ),
            if (_linkIds.isNotEmpty)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _reshapeLinked,
                onChanged: (value) => setState(() => _reshapeLinked = value),
                title: const Text('Give them all this start and end'),
                subtitle: Text(
                  'Every dog booked ${formatTime(_startAt)} – ${formatTime(_endAt)}. '
                  'Off, and each keeps the time it has.',
                ),
              ),
          ],

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
                title: _isVisit
                    ? 'How long will they be in altogether?'
                    : 'How long for ${dog?.name ?? 'this groom'}?',
              );
              if (picked != null) {
                setState(() {
                  _durationMinutes = picked;
                  _durationTouched = true;
                });
              }
            },
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: _isVisit ? 'Visit length' : 'Duration',
                helperText: _isVisit
                    ? 'Every dog is booked ${formatTime(_startAt)} – ${formatTime(_endAt)}. '
                        'Grooming them in turn, this is the time they are in, '
                        'not the sum of their grooms.'
                    : 'Ends at ${formatTime(_endAt)}',
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
                if (_isVisit)
                  DurationPreset(
                    label: 'Usual times added up (${formatDuration(_usualTimesSummed)})',
                    minutes: _usualTimesSummed,
                    selected: _durationMinutes == _usualTimesSummed,
                    onPick: (value) => setState(() {
                      _durationMinutes = value;
                      _durationTouched = true;
                    }),
                  )
                else if (dog != null)
                  DurationPreset(
                    label: 'Usual (${formatDuration(dog.groomMinutes)})',
                    minutes: dog.groomMinutes,
                    selected: _durationMinutes == dog.groomMinutes,
                    onPick: (value) => setState(() {
                      _durationMinutes = value;
                      _durationTouched = true;
                    }),
                  ),
                DurationPreset(
                  label: 'Nails (${formatDuration(_nailVisitMinutes)})',
                  minutes: _nailVisitMinutes,
                  selected: _durationMinutes == _nailVisitMinutes,
                  onPick: (value) => setState(() {
                    _durationMinutes = value;
                    _durationTouched = true;
                  }),
                ),
              ],
            ),
          ),
          if (_isVisitEdit)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _applyToVisit,
              onChanged: (value) => setState(() => _applyToVisit = value),
              title: Text(
                'Also change the other '
                '${widget.appointment!.companionNames.length == 1 ? 'dog' : '${widget.appointment!.companionNames.length} dogs'} '
                'in this visit',
              ),
              subtitle: Text(
                '${widget.appointment!.companionNames.join(', ')} — a new start or '
                'end applies to them too. Off, and only ${dog?.name ?? 'this dog'} changes.',
              ),
            ),

          const SizedBox(height: 12),
          if (_dogId != null)
            OutlinedButton.icon(
              onPressed: _busy ? null : _findNextFree,
              icon: const Icon(Icons.search, size: 18),
              label: const Text('FIND THE NEXT FREE SLOT'),
            ),

          const SectionHeader(title: "What's being done"),
          ServicePicker(
            services: _services,
            selected: _selectedServices,
            onChanged: (next) {
              setState(() => _selectedServices = next);
              _resizeFromServices();
            },
          ),

          const SectionHeader(title: 'Record card'),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Which of your two cards you fill in afterwards.',
              style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
            ),
          ),
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

          if (!_isEditing && _serviceType == ServiceType.groom && _extraDogIds.isEmpty) ...[
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
              decoration: InputDecoration(
                labelText: 'Status',
                // A request opened here to change the time is still a
                // request when saved unless this moves — and a request
                // with a new time on it is not in the diary.
                helperText: _status == 'REQUESTED'
                    ? 'Still a request — choose Booked to put it in the diary.'
                    : null,
              ),
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
      )),
    );
  }
}
