import '../models/models.dart';
import 'api_client.dart';

/// Every API call the app makes, in one place.
///
/// Screens depend on this rather than [ApiClient] directly, so the endpoint
/// shapes live here and the widgets stay about presentation.
class DataService {
  DataService(this._api);

  final ApiClient _api;

  // ── Settings and profile ───────────────────────────────────────────

  Future<AppSettings> getSettings() async =>
      AppSettings.fromJson(await _api.get('/settings/') as Map<String, dynamic>);

  Future<void> updateSettings(Map<String, dynamic> changes) =>
      _api.patch('/settings/', changes);

  Future<Map<String, dynamic>> getMyProfile() async =>
      await _api.get('/me/') as Map<String, dynamic>;

  Future<void> updateMyProfile(Map<String, dynamic> changes) => _api.patch('/me/', changes);

  // ── Doguments / dogs ───────────────────────────────────────────────

  /// The Doguments list. Server-side [search] covers dog name, client name,
  /// client UID and phone number.
  Future<List<DogSummary>> getDogs({String? search, bool includeInactive = false}) async {
    final payload = await _api.get('/dogs/', query: {
      if (search != null && search.isNotEmpty) 'search': search,
      if (includeInactive) 'include_inactive': '1',
    });
    return ApiClient.resultsOf(payload).map(DogSummary.fromJson).toList();
  }

  Future<Dog> getDog(int id) async =>
      Dog.fromJson(await _api.get('/dogs/$id/') as Map<String, dynamic>);

  Future<Dog> createDog(Map<String, dynamic> body) async =>
      Dog.fromJson(await _api.post('/dogs/', body) as Map<String, dynamic>);

  Future<Dog> updateDog(int id, Map<String, dynamic> changes) async =>
      Dog.fromJson(await _api.patch('/dogs/$id/', changes) as Map<String, dynamic>);

  Future<void> deleteDog(int id) => _api.delete('/dogs/$id/');

  Future<String?> getSuggestedNextGroom(int dogId) async {
    final payload = await _api.get('/dogs/$dogId/suggested_next_groom/');
    return (payload as Map<String, dynamic>)['due_date']?.toString();
  }

  // ── Clients ────────────────────────────────────────────────────────

  Future<List<ClientRecord>> getClients({String? search}) async {
    final payload = await _api.get('/clients/', query: {
      if (search != null && search.isNotEmpty) 'search': search,
    });
    return ApiClient.resultsOf(payload).map(ClientRecord.fromJson).toList();
  }

  Future<ClientRecord> getClient(int id) async =>
      ClientRecord.fromJson(await _api.get('/clients/$id/') as Map<String, dynamic>);

  Future<ClientRecord> createClient(Map<String, dynamic> body) async =>
      ClientRecord.fromJson(await _api.post('/clients/', body) as Map<String, dynamic>);

  Future<ClientRecord> updateClient(int id, Map<String, dynamic> changes) async =>
      ClientRecord.fromJson(await _api.patch('/clients/$id/', changes) as Map<String, dynamic>);

  // ── Breeds ─────────────────────────────────────────────────────────

  Future<List<Breed>> getBreeds({String? search}) async {
    final payload = await _api.get('/breeds/', query: {
      if (search != null && search.isNotEmpty) 'search': search,
      'page_size': '200',
    });
    return ApiClient.resultsOf(payload).map(Breed.fromJson).toList();
  }

  Future<void> updateBreed(int id, Map<String, dynamic> changes) =>
      _api.patch('/breeds/$id/', changes);

  // ── Problem areas ──────────────────────────────────────────────────

  Future<List<ProblemArea>> getProblemAreas(int dogId) async {
    final payload = await _api.get('/problem-areas/', query: {'dog': dogId});
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
    final payload = await _api.get('/dog-photos/', query: {'dog': dogId});
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
    final payload = await _api.get('/appointments/', query: {
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
  }) async {
    final payload = await _api.post('/appointments/check/', {
      'dog': dogId,
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': ?endAt?.toUtc().toIso8601String(),
      'exclude_appointment': ?excludeAppointmentId,
    });
    return BookingCheck.fromJson(payload as Map<String, dynamic>);
  }

  Future<Appointment> createAppointment({
    required int dogId,
    required DateTime startAt,
    DateTime? endAt,
    String bookingType = 'ADHOC',
    String notes = '',
  }) async {
    final payload = await _api.post('/appointments/', {
      'dog': dogId,
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': ?endAt?.toUtc().toIso8601String(),
      'booking_type': bookingType,
      'notes': notes,
    });
    return Appointment.fromJson(payload as Map<String, dynamic>);
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

  Future<List<GroomSession>> getGroomSessions(int dogId) async {
    final payload = await _api.get('/groom-sessions/', query: {'dog': dogId});
    return ApiClient.resultsOf(payload).map(GroomSession.fromJson).toList();
  }

  Future<GroomSession> createGroomSession({
    required int dogId,
    int? appointmentId,
    required List<PhaseTiming> timings,
    String notes = '',
  }) async {
    final payload = await _api.post('/groom-sessions/', {
      'dog': dogId,
      'appointment': ?appointmentId,
      'timings': timings.map((t) => t.toJson()).toList(),
      'notes': notes,
    });
    return GroomSession.fromJson(payload as Map<String, dynamic>);
  }

  /// Write this session's total back to the dog's default groom time, which
  /// then sizes the diary block for future bookings.
  Future<GroomSession> applySessionToDog(int sessionId) async {
    final payload = await _api.post('/groom-sessions/$sessionId/apply_to_dog/');
    return GroomSession.fromJson(payload as Map<String, dynamic>);
  }

  // ── To-dos ─────────────────────────────────────────────────────────

  Future<List<TodoItem>> getTodos() async {
    final payload = await _api.get('/todos/');
    return ApiClient.resultsOf(payload).map(TodoItem.fromJson).toList();
  }

  Future<TodoItem> createTodo(String text, {DateTime? dueDate}) async {
    final payload = await _api.post('/todos/', {
      'text': text,
      'due_date': ?dueDate?.toIso8601String().split('T').first,
    });
    return TodoItem.fromJson(payload as Map<String, dynamic>);
  }

  Future<TodoItem> updateTodo(int id, Map<String, dynamic> changes) async =>
      TodoItem.fromJson(await _api.patch('/todos/$id/', changes) as Map<String, dynamic>);

  Future<void> deleteTodo(int id) => _api.delete('/todos/$id/');

  // ── Equipment ──────────────────────────────────────────────────────

  Future<List<Equipment>> getEquipment() async {
    final payload = await _api.get('/equipment/');
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

  Future<List<Invoice>> getInvoices() async {
    final payload = await _api.get('/invoices/');
    return ApiClient.resultsOf(payload).map(Invoice.fromJson).toList();
  }

  Future<Invoice> createInvoice({
    required int clientId,
    required String number,
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
    final payload = await _api.get('/intake-submissions/', query: {
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
    final payload = await _api.get('/claim-requests/');
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
    final payload = await _api.get('/accounts/', query: {
      'search': ?search,
    });
    return ApiClient.resultsOf(payload).map(AccountSummary.fromJson).toList();
  }

  Future<List<PasswordHelpRequest>> getPasswordHelpRequests({String? status}) async {
    final payload = await _api.get('/password-reset-requests/', query: {
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
}
