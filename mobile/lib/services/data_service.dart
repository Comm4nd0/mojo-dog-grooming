import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'api_client.dart';
import 'offline_store.dart';

/// Every API call the app makes, in one place.
///
/// Screens depend on this rather than [ApiClient] directly, so the endpoint
/// shapes live here and the widgets stay about presentation.
class DataService {
  DataService(this._api, {this.offline});

  final OfflineStore? offline;

  final ApiClient _api;

  // ── Settings and profile ───────────────────────────────────────────

  Future<AppSettings> getSettings() async =>
      AppSettings.fromJson(await _get('/settings/') as Map<String, dynamic>);

  Future<void> updateSettings(Map<String, dynamic> changes) =>
      _api.patch('/settings/', changes);

  Future<Map<String, dynamic>> getMyProfile() async =>
      await _get('/me/') as Map<String, dynamic>;

  Future<void> updateMyProfile(Map<String, dynamic> changes) => _api.patch('/me/', changes);

  // ── Doguments / dogs ───────────────────────────────────────────────

  /// The Doguments list. Server-side [search] covers dog name, client name,
  /// client UID and phone number.
  Future<List<DogSummary>> getDogs({String? search, bool includeInactive = false}) async {
    final payload = await _getAll('/dogs/', query: {
      if (search != null && search.isNotEmpty) 'search': search,
      if (includeInactive) 'include_inactive': '1',
    });
    return ApiClient.resultsOf(payload).map(DogSummary.fromJson).toList();
  }

  Future<Dog> getDog(int id) async =>
      Dog.fromJson(await _get('/dogs/$id/') as Map<String, dynamic>);

  Future<Dog> createDog(Map<String, dynamic> body) async =>
      Dog.fromJson(await _api.post('/dogs/', body) as Map<String, dynamic>);

  Future<Dog> updateDog(int id, Map<String, dynamic> changes) async =>
      Dog.fromJson(await _api.patch('/dogs/$id/', changes) as Map<String, dynamic>);

  Future<void> deleteDog(int id) => _api.delete('/dogs/$id/');

  /// When a dog is next due, and the sum behind it.
  ///
  /// [basis] is the server's own wording — "8 weeks after 12 Jun 2026" — and
  /// is worth carrying rather than re-deriving: it names the groom the figure
  /// was counted from, which the app does not otherwise know. [dueDate] is
  /// null for a dog with no completed groom behind it, and that is a real
  /// answer rather than a missing one.
  Future<({String? dueDate, String basis})> getSuggestedNextGroom(int dogId) async {
    final payload =
        await _get('/dogs/$dogId/suggested_next_groom/') as Map<String, dynamic>;
    return (
      dueDate: payload['due_date']?.toString(),
      basis: payload['basis']?.toString() ?? '',
    );
  }

  /// Who needs booking in. Staff only — it is a worklist over the whole book.
  ///
  /// Dogs already in the diary are left out by the server unless
  /// [includeBooked], which is what makes it a call list rather than a report.
  Future<List<DueDog>> getDogsDue({int withinDays = 14, bool includeBooked = false}) async {
    final payload = await _get('/dogs/due/', query: {
      'within_days': '$withinDays',
      if (includeBooked) 'include_booked': '1',
    });
    final rows = (payload as Map<String, dynamic>)['results'] as List<dynamic>? ?? const [];
    return rows.map((row) => DueDog.fromJson(row as Map<String, dynamic>)).toList();
  }

  // ── Clients ────────────────────────────────────────────────────────

  Future<List<ClientRecord>> getClients({String? search}) async {
    final payload = await _getAll('/clients/', query: {
      if (search != null && search.isNotEmpty) 'search': search,
    });
    return ApiClient.resultsOf(payload).map(ClientRecord.fromJson).toList();
  }

  Future<ClientRecord> getClient(int id) async =>
      ClientRecord.fromJson(await _get('/clients/$id/') as Map<String, dynamic>);

  Future<ClientRecord> createClient(Map<String, dynamic> body) async =>
      ClientRecord.fromJson(await _api.post('/clients/', body) as Map<String, dynamic>);

  Future<ClientRecord> updateClient(int id, Map<String, dynamic> changes) async =>
      ClientRecord.fromJson(await _api.patch('/clients/$id/', changes) as Map<String, dynamic>);

  // ── Breeds ─────────────────────────────────────────────────────────

  /// The whole breed table. Walks every page — a reference list arriving
  /// short looks like a reference list, which is how "not all the breeds
  /// are showing" went unnoticed until Jess added some past the cut.
  Future<List<Breed>> getBreeds({String? search}) async {
    final rows = await _getAll('/breeds/', query: {
      if (search != null && search.isNotEmpty) 'search': search,
    });
    return rows.map(Breed.fromJson).toList();
  }

  Future<Breed> getBreed(int id) async =>
      Breed.fromJson(await _get('/breeds/$id/') as Map<String, dynamic>);

  Future<void> updateBreed(int id, Map<String, dynamic> changes) =>
      _api.patch('/breeds/$id/', changes);

  // ── Medical notes ──────────────────────────────────────────────────
  //
  // Reference material, not anybody's record — a dog's own conditions live on
  // the dog and stay staff-gated with the rest of that profile. Nothing here
  // is seeded or written by the app: it is veterinary information.

  Future<List<MedicalNote>> getMedicalNotes({String? search, String? kind, int? breedId}) async {
    final rows = await _getAll('/medical-notes/', query: {
      'search': ?search,
      'kind': ?kind,
      if (breedId != null) 'breed': '$breedId',
    });
    return rows.map(MedicalNote.fromJson).toList();
  }

  Future<MedicalNote> saveMedicalNote(Map<String, dynamic> body, {int? id}) async {
    final payload = id == null
        ? await _api.post('/medical-notes/', body)
        : await _api.patch('/medical-notes/$id/', body);
    return MedicalNote.fromJson(payload as Map<String, dynamic>);
  }

  Future<void> deleteMedicalNote(int id) => _api.delete('/medical-notes/$id/');

  // ── Problem areas ──────────────────────────────────────────────────

  Future<List<ProblemArea>> getProblemAreas(int dogId) async {
    final payload = await _get('/problem-areas/', query: {'dog': dogId});
    return ApiClient.resultsOf(payload).map(ProblemArea.fromJson).toList();
  }

  Future<ProblemArea> createProblemArea({
    required int dogId,
    required List<String> gridCells,
    required String reason,
  }) async {
    final payload = await _api.post('/problem-areas/', {
      'dog': dogId,
      'grid_cells': gridCells,
      'reason': reason,
    });
    return ProblemArea.fromJson(payload as Map<String, dynamic>);
  }

  Future<void> deleteProblemArea(int id) => _api.delete('/problem-areas/$id/');

  // ── Photos ─────────────────────────────────────────────────────────

  Future<List<DogPhoto>> getDogPhotos(int dogId) async {
    final payload = await _get('/dog-photos/', query: {'dog': dogId});
    return ApiClient.resultsOf(payload).map(DogPhoto.fromJson).toList();
  }

  Future<DogPhoto> uploadDogPhoto({
    required int dogId,
    required String filePath,
    String caption = '',
    DateTime? takenAt,
  }) async {
    final payload = await _api.upload(
      '/dog-photos/',
      field: 'image',
      filePath: filePath,
      fields: {
        'dog': dogId.toString(),
        'caption': caption,
        'taken_at': (takenAt ?? DateTime.now()).toUtc().toIso8601String(),
      },
    );
    return DogPhoto.fromJson(payload as Map<String, dynamic>);
  }

  Future<void> deleteDogPhoto(int id) => _api.delete('/dog-photos/$id/');

  // ── Appointments ───────────────────────────────────────────────────

  Future<List<Appointment>> getAppointments({
    DateTime? from,
    DateTime? to,
    int? dogId,
  }) async {
    String? asDate(DateTime? value) => value?.toIso8601String().split('T').first;

    // Null query values are dropped by ApiClient, so these can be passed
    // unconditionally.
    final payload = await _getAll('/appointments/', query: {
      'from': asDate(from),
      'to': asDate(to),
      'dog': dogId,
      'page_size': '500',
    });
    return ApiClient.resultsOf(payload).map(Appointment.fromJson).toList();
  }

  /// Advisory checks before saving a booking. Warnings never block.
  Future<BookingCheck> checkBooking({
    required int dogId,
    required DateTime startAt,
    DateTime? endAt,
    int? excludeAppointmentId,
    int? excludeGroupId,
    String serviceType = ServiceType.groom,
    List<int> serviceIds = const [],
  }) async {
    final payload = await _api.post('/appointments/check/', {
      'dog': dogId,
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': ?endAt?.toUtc().toIso8601String(),
      'exclude_appointment': ?excludeAppointmentId,
      // The rest of a household visit: they overlap on purpose.
      'exclude_group': ?excludeGroupId,
      'service_type': serviceType,
      'services': serviceIds,
    });
    return BookingCheck.fromJson(payload as Map<String, dynamic>);
  }

  /// The first few free gaps long enough for this booking.
  ///
  /// Returns the raw payload: `slots`, plus `exhausted` and `reason` which the
  /// caller has to honour. An empty list with `reason: no_opening_hours` means
  /// "set your hours up", not "you are fully booked", and showing the same
  /// blank list for both would be the app telling her something untrue.
  Future<Map<String, dynamic>> nextAvailable({
    required int dogId,
    String serviceType = ServiceType.groom,
    List<int> serviceIds = const [],
    DateTime? from,
    int count = 3,
  }) async {
    final payload = await _get('/appointments/next_available/', query: {
      'dog': dogId,
      'service_type': serviceType,
      'count': count,
      'from': from?.toIso8601String().split('T').first,
    });
    return payload as Map<String, dynamic>;
  }

  Future<Appointment> createAppointment({
    required int dogId,
    required DateTime startAt,
    DateTime? endAt,
    String bookingType = 'ADHOC',
    String serviceType = ServiceType.groom,
    List<int> serviceIds = const [],
    String notes = '',
  }) async {
    final payload = await _api.post('/appointments/', {
      'dog': dogId,
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': ?endAt?.toUtc().toIso8601String(),
      'booking_type': bookingType,
      'service_type': serviceType,
      'services': serviceIds,
      'notes': notes,
    });
    return Appointment.fromJson(payload as Map<String, dynamic>);
  }

  /// Bookings a client has asked for and Jess has not answered yet.
  ///
  /// PendingView counts these towards the More badge, so there has to be a
  /// way to list them — without one the badge pointed at a screen that could
  /// not show them.
  Future<List<Appointment>> getAppointmentRequests() async {
    final payload = await _get('/appointments/', query: {'status': 'REQUESTED'});
    return ApiClient.resultsOf(payload).map(Appointment.fromJson).toList();
  }

  /// Book a household in as one visit: one appointment per dog, all from
  /// [startAt] to [endAt], made together or not at all.
  ///
  /// [services] are the first dog's; the companions are booked with none,
  /// so the server resolves each dog's own price exactly as a booking made
  /// alone. Returns the appointments made.
  Future<List<Appointment>> bookTogether({
    required List<int> dogIds,
    required DateTime startAt,
    required DateTime endAt,
    String bookingType = 'ADHOC',
    String serviceType = ServiceType.groom,
    List<int> services = const [],
    String notes = '',
  }) async {
    final payload = await _api.post('/booking-groups/', {
      'bookings': [
        for (var i = 0; i < dogIds.length; i++)
          {'dog': dogIds[i], if (i == 0) 'services': services},
      ],
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': endAt.toUtc().toIso8601String(),
      'booking_type': bookingType,
      'service_type': serviceType,
      'notes': notes,
    });
    final rows = (payload as Map<String, dynamic>)['appointments'] as List? ?? const [];
    return rows.map((row) => Appointment.fromJson(row as Map<String, dynamic>)).toList();
  }

  /// Link bookings already in the diary into one visit.
  ///
  /// The fix for a household booked one dog at a time before visits
  /// existed. Nothing moves: the members come back with their group set,
  /// and giving them one length is a separate, visible step.
  Future<List<Appointment>> groupAppointments(List<int> appointmentIds) async {
    final payload = await _api.post('/booking-groups/', {'appointments': appointmentIds});
    final rows = (payload as Map<String, dynamic>)['appointments'] as List? ?? const [];
    return rows.map((row) => Appointment.fromJson(row as Map<String, dynamic>)).toList();
  }

  /// Move or resize every dog in a visit at once.
  ///
  /// A new start shifts each by the same amount, keeping its own length; a
  /// new end sets every dog's end. Returns the server's warnings, prefixed
  /// with the dog — advisory, as always.
  Future<List<BookingWarning>> updateBookingGroup(
    int id, {
    DateTime? startAt,
    DateTime? endAt,
  }) async {
    final payload = await _api.patch('/booking-groups/$id/', {
      'start_at': ?startAt?.toUtc().toIso8601String(),
      'end_at': ?endAt?.toUtc().toIso8601String(),
    });
    final rows = (payload as Map<String, dynamic>)['warnings'] as List? ?? const [];
    return rows.map((row) => BookingWarning.fromJson(row as Map<String, dynamic>)).toList();
  }

  Future<Appointment> updateAppointment(int id, Map<String, dynamic> changes) async =>
      Appointment.fromJson(await _api.patch('/appointments/$id/', changes) as Map<String, dynamic>);

  Future<void> deleteAppointment(int id) => _api.delete('/appointments/$id/');

  Future<void> createBookingSeries({
    required int dogId,
    required int intervalWeeks,
    required DateTime startDate,
    required String preferredTime,
    String notes = '',
  }) =>
      _api.post('/booking-series/', {
        'dog': dogId,
        'interval_weeks': intervalWeeks,
        'start_date': startDate.toIso8601String().split('T').first,
        'preferred_time': preferredTime,
        'notes': notes,
      });

  // ── Groom sessions ─────────────────────────────────────────────────

  Future<List<GroomSession>> getGroomSessions(int dogId, {String? visitType}) async {
    final payload = await _getAll('/groom-sessions/', query: {
      'dog': dogId,
      'visit_type': ?visitType,
    });
    return [
      ...ApiClient.resultsOf(payload).map(GroomSession.fromJson),
      for (final entry in offline?.pending ?? <Map<String, dynamic>>[])
        if (entry['body']['dog'] == dogId && (visitType == null || entry['body']['visit_type'] == visitType))
          _pendingSession(Map<String, dynamic>.from(entry['body'] as Map), entry['dog_name'] as String),
    ];
  }

  Future<GroomSession> createGroomSession({
    required int dogId,
    String dogName = '',
    String? clientReference,
    DateTime? startedAt,
    bool applyToDog = false,
    bool completeCard = false,
    int? appointmentId,
    required List<PhaseTiming> timings,
    String notes = '',
    Map<String, dynamic> record = const {},
  }) async {
    var body = <String, dynamic>{
      'notes': notes,
      ...record,
      'dog': dogId > 0 ? dogId : null,
      if (dogId <= 0) 'walk_in_name': dogName,
      'appointment': ?appointmentId,
      'timings': timings.map((t) => t.toJson()).toList(),
      'started_at': (startedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'finished_at': DateTime.now().toUtc().toIso8601String(),
      'client_reference': clientReference ?? newGroomReference(),
      'apply_to_dog': applyToDog,
      'complete_card': completeCard,
    };
    final store = offline;
    final epoch = store?.generation;
    if (store?.enabled ?? false) {
      for (final entry in store!.pending) {
        if (entry['body']['client_reference'] == body['client_reference']) {
          body = Map<String, dynamic>.from(entry['body'] as Map);
          break;
        }
      }
      await store.enqueue(body, dogName);
      if (epoch != store.generation) throw const ApiException(409, 'Account changed while saving.');
    }
    try {
      final payload = await _api.post('/groom-sessions/', body) as Map<String, dynamic>;
      if (epoch != store?.generation) throw const ApiException(409, 'Account changed while saving.');
      if (store?.enabled ?? false) {
        await store!.remove(body['client_reference'] as String);
        if (epoch != store.generation) throw const ApiException(409, 'Account changed while saving.');
        store.status(offline: false);
      }
      return GroomSession.fromJson(payload);
    } on NoConnectionException {
      if (store == null || !store.enabled || epoch != store.generation) rethrow;
      store.status(offline: true);
      return _pendingSession(body, dogName);
    } on ApiException catch (error) {
      if (store == null || !store.enabled || epoch != store.generation) rethrow;
      if (error.statusCode >= 500) {
        store.status(error: error.message);
        return _pendingSession(body, dogName);
      }
      await store.remove(body['client_reference'] as String);
      rethrow;
    }
  }

  GroomSession _pendingSession(Map<String, dynamic> body, String name, {String? error}) {
    final timings = (body['timings'] as List? ?? []);
    final seconds = timings.fold<int>(0, (sum, t) => sum + ((t['duration_seconds'] as num?)?.toInt() ?? 0));
    return GroomSession.fromJson({
      ...body, 'id': -1, 'dog_name': name, 'pending_sync': true,
      'invoice_state': body['complete_card'] == true ? 'READY' : 'AWAITING_CARD',
      'pending_error': error,
      'total_minutes': body['recorded_minutes'] ?? (seconds / 60).round(),
    });
  }

  List<GroomSession> get pendingGrooms => [
    for (final entry in offline?.pending ?? <Map<String, dynamic>>[])
      _pendingSession(Map<String, dynamic>.from(entry['body'] as Map),
        entry['dog_name'] as String, error: entry['error']?.toString()),
  ];

  Future<void> revisePendingGroom(String reference, Map<String, dynamic> changes, {String? dogName}) async {
    if (offline == null) throw StateError('No saved upload found.');
    await offline!.revise(reference, changes, dogName: dogName);
  }

  Future<List<GroomSession>> getWalkIns() async {
    List<Map<String, dynamic>> rows;
    try {
      rows = await _getAll('/groom-sessions/', query: {'unassigned': '1'});
    } on NoConnectionException {
      if (offline?.pendingCount == 0 || offline == null) rethrow;
      rows = [];
    }
    return [
      ...rows.map(GroomSession.fromJson),
      for (final entry in offline?.pending ?? <Map<String, dynamic>>[])
        if (entry['body']['dog'] == null)
          _pendingSession(Map<String, dynamic>.from(entry['body'] as Map), entry['dog_name'] as String),
    ];
  }

  Future<GroomSession> assignWalkIn(int sessionId, int dogId) async =>
      GroomSession.fromJson(await _api.post('/groom-sessions/$sessionId/assign/', {'dog': dogId}) as Map<String, dynamic>);

  Future<GroomSession> updateGroomSession(int id, Map<String, dynamic> changes) async =>
      GroomSession.fromJson(await _api.patch('/groom-sessions/$id/', changes) as Map<String, dynamic>);

  /// Write this session's total back to the dog's default groom time, which
  /// then sizes the diary block for future bookings.
  Future<GroomSession> applySessionToDog(int sessionId) async {
    final payload = await _api.post('/groom-sessions/$sessionId/apply_to_dog/');
    return GroomSession.fromJson(payload as Map<String, dynamic>);
  }

  /// The owner-visible slice of a dog's visit records. Scoped on the server,
  /// so a client only ever gets their own dogs' reports back.
  Future<List<GroomReport>> getGroomReports(int dogId) async {
    final payload = await _get('/groom-reports/', query: {'dog': dogId});
    return ApiClient.resultsOf(payload).map(GroomReport.fromJson).toList();
  }

  // ── To-dos ─────────────────────────────────────────────────────────

  /// What Jess does, in her order. Active services only.
  Future<List<ServiceItem>> getServices() async {
    final payload = await _get('/services/');
    return ApiClient.resultsOf(payload).map(ServiceItem.fromJson).toList();
  }

  Future<void> updateService(int id, Map<String, dynamic> changes) =>
      _api.patch('/services/$id/', changes);

  /// How much is waiting for Jess, for the badge on More.
  ///
  /// Staff-only on the server, so this is never called for a client login.
  static final ValueNotifier<int> pendingTotal = ValueNotifier<int>(0);

  Future<PendingCounts> getPending() async {
    final counts = PendingCounts.fromJson(
      await _get('/pending/') as Map<String, dynamic>,
    );
    pendingTotal.value = counts.total;
    return counts;
  }

  // ── Change requests ────────────────────────────────────────────────

  Future<List<ChangeRequest>> getChangeRequests({String? status}) async {
    final payload = await _get(
      '/client-change-requests/',
      query: {'status': ?status},
    );
    return ApiClient.resultsOf(payload).map(ChangeRequest.fromJson).toList();
  }

  /// Ask Jess to correct something. The server takes the client from the
  /// session, so there is nothing to pass but the changes themselves.
  Future<void> requestDetailChange(Map<String, dynamic> changes) =>
      _api.post('/client-change-requests/', {'changes': changes});

  Future<void> approveChangeRequest(int id) =>
      _api.post('/client-change-requests/$id/approve/', {});

  Future<void> rejectChangeRequest(int id) =>
      _api.post('/client-change-requests/$id/reject/', {});

  // ── Consents ───────────────────────────────────────────────────────
  //
  // Staff only, and append-only: withdrawing agreement is a new row, never an
  // edit. A consent is evidence of what was signed on a day.

  Future<List<ConsentKindOption>> getConsentKinds() async {
    final payload = await _get('/consents/kinds/');
    return (payload as List<dynamic>)
        .map((row) => ConsentKindOption.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  /// [signedAt] is for typing up a card signed across the counter days ago.
  /// The server refuses a future date and stamps the wording itself.
  Future<void> recordConsent({
    required int clientId,
    required String kind,
    required bool agreed,
    required String signedName,
    DateTime? signedAt,
  }) =>
      _api.post('/consents/', {
        'client': clientId,
        'kind': kind,
        'agreed': agreed,
        'signed_name': signedName,
        if (signedAt != null) 'signed_at': signedAt.toIso8601String(),
      });

  // ── Booking change requests ────────────────────────────────────────
  //
  // Bookings are read-only to a client. This is how they *ask* to cancel or
  // move one; Jess reviews it and the booking is unchanged until she does.

  Future<List<AppointmentChangeRequest>> getAppointmentChangeRequests({String? status}) async {
    final payload = await _get('/appointment-change-requests/', query: {
      'status': ?status,
    });
    return ApiClient.resultsOf(payload).map(AppointmentChangeRequest.fromJson).toList();
  }

  Future<AppointmentChangeRequest> requestAppointmentChange({
    required int appointmentId,
    required String kind,
    DateTime? preferredStartAt,
    String note = '',
  }) async {
    final payload = await _api.post('/appointment-change-requests/', {
      'appointment': appointmentId,
      'kind': kind,
      if (preferredStartAt != null) 'preferred_start_at': preferredStartAt.toIso8601String(),
      'note': note,
    });
    return AppointmentChangeRequest.fromJson(payload as Map<String, dynamic>);
  }

  /// [startAt] lets Jess approve a move to a time other than the one asked
  /// for — the common case, when the requested slot clashes.
  ///
  /// Returns the server's warnings, which never block: an approved move that
  /// overlaps still happens, and she slides it in the day view.
  Future<List<String>> approveAppointmentChange(int id, {DateTime? startAt}) async {
    final payload = await _api.post('/appointment-change-requests/$id/approve/', {
      if (startAt != null) 'start_at': startAt.toUtc().toIso8601String(),
    });
    final warnings = (payload as Map<String, dynamic>)['warnings'] as List<dynamic>? ?? const [];
    return warnings.map((w) => w.toString()).toList();
  }

  Future<void> rejectAppointmentChange(int id) =>
      _api.post('/appointment-change-requests/$id/reject/', {});

  // ── Dog change requests ────────────────────────────────────────────
  //
  // A dog's record is read-only to its owner. This is how they *suggest* an
  // update — free text, reviewed by Jess, who makes any edit herself.

  Future<List<DogChangeRequest>> getDogChangeRequests({String? status}) async {
    final payload = await _get('/dog-change-requests/', query: {
      'status': ?status,
    });
    return ApiClient.resultsOf(payload).map(DogChangeRequest.fromJson).toList();
  }

  Future<void> suggestDogChange({required int dogId, required String message}) =>
      _api.post('/dog-change-requests/', {'dog': dogId, 'message': message});

  /// Marks the suggestion dealt with. Deliberately changes nothing on the dog
  /// — the message is prose, and Jess edits the record herself.
  Future<void> approveDogChange(int id) =>
      _api.post('/dog-change-requests/$id/approve/', {});

  Future<void> rejectDogChange(int id) =>
      _api.post('/dog-change-requests/$id/reject/', {});

  // ── Documents ──────────────────────────────────────────────────────

  Future<List<DogDocument>> getDogDocuments(int dogId) async {
    final payload = await _get('/dog-documents/', query: {'dog': '$dogId'});
    return ApiClient.resultsOf(payload).map(DogDocument.fromJson).toList();
  }

  Future<DogDocument> uploadDogDocument({
    required int dogId,
    required String filePath,
    required String title,
    String kind = 'INTAKE_FORM',
    bool visibleToClient = true,
  }) async {
    final payload = await _api.upload(
      '/dog-documents/',
      filePath: filePath,
      field: 'file',
      fields: {
        'dog': '$dogId',
        'title': title,
        'kind': kind,
        'visible_to_client': visibleToClient.toString(),
      },
    );
    return DogDocument.fromJson(payload as Map<String, dynamic>);
  }

  Future<void> deleteDogDocument(int id) => _api.delete('/dog-documents/$id/');

  /// The file itself, with the auth header attached.
  Future<Uint8List> downloadDocument(int id) async =>
      Uint8List.fromList(await _api.getBytes('/dog-documents/$id/download/'));

  /// Opening hours keyed by weekday, Monday 1 — the shape the diary wants.
  ///
  /// A day with no row, or one marked closed, is simply absent: the timeline
  /// shades a missing weekday entirely, because "no hours set" means "not
  /// normally open", not "open all hours".
  Future<Map<int, (int, int)>> getOpeningHoursByWeekday() async {
    final rows = ApiClient.resultsOf(await _get('/opening-hours/'));
    final hours = <int, (int, int)>{};
    for (final row in rows) {
      if (row['is_closed'] == true) continue;
      final open = _minutesOfTime(row['open_time']?.toString());
      final close = _minutesOfTime(row['close_time']?.toString());
      if (open == null || close == null) continue;
      // The API stores Monday as 0; DateTime.weekday is Monday 1.
      final weekday = ((row['weekday'] as num?)?.toInt() ?? 0) + 1;
      hours[weekday] = (open, close);
    }
    return hours;
  }

  Future<Set<DateTime>> getClosureDates() async {
    final rows = ApiClient.resultsOf(await _get('/closures/'));
    return {
      for (final row in rows)
        if (DateTime.tryParse(row['date']?.toString() ?? '') case final date?)
          DateTime.utc(date.year, date.month, date.day),
    };
  }

  /// Blocked-out time touching the window, by overlap rather than start —
  /// a long weekend off is on Saturday's diary even though it starts Friday.
  ///
  /// Readable by clients too (minus the notes), which is what lets the
  /// request sheet say "not available" before anything is sent.
  Future<List<BlockedTime>> getBlockedTimes({DateTime? from, DateTime? to}) async {
    String? asDate(DateTime? value) => value?.toIso8601String().split('T').first;
    final payload = await _get('/blocked-times/', query: {
      'from': asDate(from),
      'to': asDate(to),
      'page_size': '500',
    });
    return ApiClient.resultsOf(payload).map(BlockedTime.fromJson).toList();
  }

  Future<BlockedTime> createBlockedTime({
    required DateTime startAt,
    required DateTime endAt,
    String notes = '',
    String category = '',
  }) async {
    final payload = await _api.post('/blocked-times/', {
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': endAt.toUtc().toIso8601String(),
      'notes': notes,
      'category': category,
    });
    return BlockedTime.fromJson(payload as Map<String, dynamic>);
  }

  Future<BlockedTime> updateBlockedTime(int id, Map<String, dynamic> changes) async =>
      BlockedTime.fromJson(
        await _api.patch('/blocked-times/$id/', changes) as Map<String, dynamic>,
      );

  Future<void> deleteBlockedTime(int id) => _api.delete('/blocked-times/$id/');

  static int? _minutesOfTime(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split(':');
    if (parts.length < 2) return null;
    final hours = int.tryParse(parts[0]);
    final minutes = int.tryParse(parts[1]);
    if (hours == null || minutes == null) return null;
    return hours * 60 + minutes;
  }

  /// The five handling grades, easiest first.
  ///
  /// Fetched rather than hardcoded because Jess renames them in Settings —
  /// anything in the app that spells out "Fidgety" will be wrong the day she
  /// changes it.
  Future<List<TemperamentGrade>> getTemperamentGrades() async {
    final payload = await _get('/temperament-grades/');
    return ApiClient.resultsOf(payload).map(TemperamentGrade.fromJson).toList();
  }

  Future<void> updateTemperamentGrade(int id, Map<String, dynamic> changes) =>
      _api.patch('/temperament-grades/$id/', changes);

  /// How many to-dos are still outstanding, for the badge on the More tab.
  ///
  /// A notifier rather than a `FutureBuilder` because `MoreScreen` sits in the
  /// shell's `IndexedStack` and never rebuilds on its own — a future resolved
  /// once when the tab was first built would show a count from whenever that
  /// happened to be and never move again.
  static final ValueNotifier<int> outstandingTodos = ValueNotifier<int>(0);

  Future<List<TodoItem>> getTodos() async {
    final payload = await _get('/todos/');
    final todos = ApiClient.resultsOf(payload).map(TodoItem.fromJson).toList();
    outstandingTodos.value = todos.where((todo) => !todo.isDone).length;
    return todos;
  }

  Future<TodoItem> createTodo(String text, {DateTime? dueDate}) async {
    final payload = await _api.post('/todos/', {
      'text': text,
      'due_date': ?dueDate?.toIso8601String().split('T').first,
    });
    outstandingTodos.value += 1;
    return TodoItem.fromJson(payload as Map<String, dynamic>);
  }

  Future<TodoItem> updateTodo(int id, Map<String, dynamic> changes) async {
    final todo =
        TodoItem.fromJson(await _api.patch('/todos/$id/', changes) as Map<String, dynamic>);
    // Ticking one off is the common edit and the one the badge cares about.
    // Every caller reloads the list straight after, which sets the exact
    // figure; this only keeps the badge honest in between.
    if (changes.containsKey('is_done')) {
      outstandingTodos.value =
          (outstandingTodos.value + (todo.isDone ? -1 : 1)).clamp(0, 999);
    }
    return todo;
  }

  Future<void> deleteTodo(int id) => _api.delete('/todos/$id/');

  // ── Equipment ──────────────────────────────────────────────────────

  Future<List<Equipment>> getEquipment() async {
    final payload = await _get('/equipment/');
    return ApiClient.resultsOf(payload).map(Equipment.fromJson).toList();
  }

  Future<Equipment> saveEquipment(Equipment item) async {
    final payload = item.id == 0
        ? await _api.post('/equipment/', item.toJson())
        : await _api.patch('/equipment/${item.id}/', item.toJson());
    return Equipment.fromJson(payload as Map<String, dynamic>);
  }

  Future<void> deleteEquipment(int id) => _api.delete('/equipment/$id/');

  // ── Invoices ───────────────────────────────────────────────────────

  Future<List<Invoice>> getInvoices({int? clientId}) async {
    final payload = await _getAll('/invoices/', query: {'client': clientId});
    return ApiClient.resultsOf(payload).map(Invoice.fromJson).toList();
  }

  /// [number] is optional: blank means the server allocates the next in
  /// sequence. Only pass one to match a number already written on paper.
  Future<Invoice> createInvoice({
    required int clientId,
    String number = '',
    required List<InvoiceLine> lines,
    String notes = '',
  }) async {
    final payload = await _api.post('/invoices/', {
      'client': clientId,
      'number': number,
      'notes': notes,
      'lines': lines.map((l) => l.toJson()).toList(),
    });
    return Invoice.fromJson(payload as Map<String, dynamic>);
  }

  /// Record that an invoice has gone out.
  ///
  /// An action rather than a status PATCH, because the server stamps the date
  /// and refuses the move if the invoice is already paid.
  Future<void> markInvoiceSent(int id) => _api.post('/invoices/$id/mark_sent/', {});

  /// Take payment and close the invoice in one call.
  ///
  /// [amount] left null means "whatever is outstanding", which is the case
  /// every time in practice.
  Future<void> markInvoicePaid(
    int id, {
    required String method,
    num? amount,
    String reference = '',
  }) =>
      _api.post('/invoices/$id/mark_paid/', {
        'method': method,
        'amount': ?amount?.toString(),
        'reference': reference,
      });

  /// Only a draft can go. Anything further along is voided instead — the
  /// number has been quoted to somebody and it is unique.
  Future<void> deleteInvoice(int id) => _api.delete('/invoices/$id/');

  Future<void> updateInvoice(int id, Map<String, dynamic> changes) =>
      _api.patch('/invoices/$id/', changes);

  Future<void> recordPayment({
    required int invoiceId,
    required num amount,
    String method = 'CARD',
    String reference = '',
  }) =>
      _api.post('/payments/', {
        'invoice': invoiceId,
        'amount': amount.toString(),
        'method': method,
        'reference': reference,
      });

  // ── Intake ─────────────────────────────────────────────────────────

  Future<List<IntakeSubmission>> getIntakeSubmissions({String? status}) async {
    final payload = await _get('/intake-submissions/', query: {
      'status': ?status,
    });
    return ApiClient.resultsOf(payload).map(IntakeSubmission.fromJson).toList();
  }

  Future<void> approveIntake(int id, String clientUid) =>
      _api.post('/intake-submissions/$id/approve/', {'client_uid': clientUid});

  Future<void> rejectIntake(int id, {String notes = ''}) =>
      _api.post('/intake-submissions/$id/reject/', {'review_notes': notes});

  /// Create an invite link to send to a new client.
  Future<String> createIntakeInvite({required String email, int? clientId}) async {
    final payload = await _api.post('/intake-invites/', {
      'email': email,
      'client': ?clientId,
    });
    return (payload as Map<String, dynamic>)['token']?.toString() ?? '';
  }

  // ── Profile claims ─────────────────────────────────────────────────

  Future<List<ClaimRequest>> getClaimRequests() async {
    final payload = await _get('/claim-requests/');
    return ApiClient.resultsOf(payload).map(ClaimRequest.fromJson).toList();
  }

  Future<ClaimRequest> submitClaim({
    required String name,
    required String email,
    required String postcode,
  }) async {
    final payload = await _api.post('/claim-requests/', {
      'claimed_name': name,
      'claimed_email': email,
      'claimed_postcode': postcode,
    });
    return ClaimRequest.fromJson(payload as Map<String, dynamic>);
  }

  Future<void> approveClaim(int id, {int? clientId}) =>
      _api.post('/claim-requests/$id/approve/', {'client_id': ?clientId});

  /// Approve a claim from someone who was never entered as a client, creating
  /// their record from the details they gave and attaching their login.
  Future<void> approveClaimAsNewClient(int id, {required String uid}) =>
      _api.post('/claim-requests/$id/approve_as_new_client/', {'client_uid': uid});

  Future<void> rejectClaim(int id, {String notes = ''}) =>
      _api.post('/claim-requests/$id/reject/', {'review_notes': notes});

  // ── Logins and passwords (superuser only) ──────────────────────────

  Future<List<AccountSummary>> getAccounts({String? search}) async {
    final payload = await _get('/accounts/', query: {
      'search': ?search,
    });
    return ApiClient.resultsOf(payload).map(AccountSummary.fromJson).toList();
  }

  Future<List<PasswordHelpRequest>> getPasswordHelpRequests({String? status}) async {
    final payload = await _get('/password-reset-requests/', query: {
      'status': ?status,
    });
    return ApiClient.resultsOf(payload).map(PasswordHelpRequest.fromJson).toList();
  }

  Future<void> dismissPasswordHelpRequest(int id) =>
      _api.post('/password-reset-requests/$id/dismiss/');

  /// Issue a single-use reset link.
  ///
  /// Exactly one of [accountId], [clientId] or [requestId] identifies who it
  /// is for. The link comes back in the response and nowhere else, so whatever
  /// calls this has to put it in front of Jess there and then.
  Future<IssuedResetLink> issueResetLink({
    int? accountId,
    int? clientId,
    int? requestId,
    bool sendEmail = true,
  }) async {
    final payload = await _api.post('/password-resets/', {
      'user_id': ?accountId,
      'client_id': ?clientId,
      'request_id': ?requestId,
      'send_email': sendEmail,
    });
    return IssuedResetLink.fromJson(payload as Map<String, dynamic>);
  }

  static const _offlinePaths = {
    'dogs', 'clients', 'breeds', 'groom-sessions', 'dog-photos',
    'dog-documents', 'temperament-grades', 'equipment', 'settings',
  };

  bool _canCache(String path) {
    final bits = path.split('/').where((s) => s.isNotEmpty).toList();
    return bits.isNotEmpty && _offlinePaths.contains(bits.first) &&
        (bits.length == 1 || (bits.length == 2 && int.tryParse(bits[1]) != null));
  }

  Future<dynamic> _read(String path, Map<String, dynamic>? query, {bool all = false}) async {
    final store = offline;
    final epoch = store?.generation;
    final cacheable = _canCache(path) && (store?.enabled ?? false);
    final cached = cacheable ? store!.read(path, query) : null;
    if (store?.enabled == true && store!.isOffline) {
      if (cached != null) return cached;
      throw const NoConnectionException();
    }
    try {
      final result = all ? await _api.getAll(path, query: query) : await _api.get(path, query: query);
      if (epoch != store?.generation) throw const ApiException(409, 'Account changed.');
      if (cacheable) {
        // An ordinary read still works if the device cannot cache it. Finishing
        // a groom, unlike reading one, never swallows a storage failure.
        try { await store!.remember(path, query, result); } catch (_) {}
        if (epoch != store!.generation) throw const ApiException(409, 'Account changed.');
        store.status(offline: false);
      }
      return result;
    } on ApiException catch (error) {
      if (epoch == store?.generation && (error.isUnauthorised || error.isForbidden)) {
        await store?.activate(null);
      }
      rethrow;
    } on NoConnectionException {
      if (epoch != store?.generation) rethrow;
      if (store?.enabled == true) store!.status(offline: true);
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<dynamic> _get(String path, {Map<String, dynamic>? query}) => _read(path, query);
  Future<List<Map<String, dynamic>>> _getAll(String path, {Map<String, dynamic>? query}) async =>
      ApiClient.resultsOf(await _read(path, query, all: true));

  /// Called on opening/resuming the staff app and periodically while open.
  /// A reference stays on disk until its server response is acknowledged.
  Future<void> syncOffline({bool refreshSnapshot = false}) async {
    final store = offline;
    if (store == null || !store.enabled || store.syncing) return;
    final epoch = store.generation;
    final hadPending = store.pendingCount > 0;
    store.status(busy: true);
    try {
      // Revalidate the remembered role before sending any saved staff data.
      final identity = await _api.get('/auth/users/me/') as Map<String, dynamic>;
      if (epoch != store.generation) return;
      if (identity['is_staff'] != true) {
        await store.activate(null);
        return;
      }
      for (final entry in store.pending) {
        if (epoch != store.generation) return;
        final body = Map<String, dynamic>.from(entry['body'] as Map);
        try {
          await _api.post('/groom-sessions/', body);
        } on ApiException catch (error) {
          if (epoch != store.generation) return;
          if (error.statusCode == 400) {
            await store.reject(body['client_reference'] as String, error.message);
            continue;
          }
          rethrow;
        }
        if (epoch != store.generation) return;
        await store.remove(body['client_reference'] as String);
        if (epoch != store.generation) return;
      }
      // This both probes the connection and refreshes the offline book after
      // uploads. One response is complete, including dogs past the first page.
      if (refreshSnapshot || hadPending || store.isOffline || store.savedAt == null) {
        final snapshot = await _api.get('/dogs/offline/') as Map<String, dynamic>;
        if (epoch != store.generation) return;
        await store.saveSnapshot(snapshot);
        if (epoch != store.generation) return;
      }
      store.status(offline: false, busy: false,
        error: store.pendingCount > 0 ? 'Review the saved grooms in Doguments.' : null);
    } on ApiException catch (error) {
      if (epoch != store.generation) return;
      if (error.isUnauthorised || error.isForbidden) {
        await store.activate(null);
      } else {
        store.status(busy: false, error: error.message);
      }
    } on NoConnectionException {
      if (epoch == store.generation) store.status(offline: true, busy: false);
    } catch (error) {
      if (epoch == store.generation) store.status(busy: false, error: error.toString());
    }
  }
}
