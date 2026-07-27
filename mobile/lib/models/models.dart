/// Data models mirroring the API payloads.
///
/// Staff-only fields (temperament, chatty, private notes) are nullable here on
/// purpose: the server strips them for client logins, so a null means "not
/// visible to me", not "not set". Never render one without a null check, and
/// never assume the field arrived.
library;

import 'package:intl/intl.dart';

final _dateFormat = DateFormat('d MMM yyyy');
final _timeFormat = DateFormat('HH:mm');
final _currency = NumberFormat.currency(locale: 'en_GB', symbol: '£', decimalDigits: 2);

String formatDate(DateTime value) => _dateFormat.format(value);
String formatTime(DateTime value) => _timeFormat.format(value);
String formatMoney(num value) => _currency.format(value);

String formatDuration(int minutes) {
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
}

num _num(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  return num.tryParse(value.toString()) ?? 0;
}

DateTime? _dateTime(dynamic value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toLocal();

class CurrentUser {
  final int id;
  final String username;
  final String email;
  final bool isStaff;
  final int? clientId;

  const CurrentUser({
    required this.id,
    required this.username,
    required this.email,
    required this.isStaff,
    this.clientId,
  });

  factory CurrentUser.fromJson(Map<String, dynamic> json) => CurrentUser(
        id: json['id'] as int,
        username: json['username']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        isStaff: json['is_staff'] == true,
        clientId: json['client_id'] as int?,
      );

  /// A client login with no linked record can't see anything yet — the app
  /// routes these to the "claim your profile" flow.
  bool get needsToClaimProfile => !isStaff && clientId == null;
}

class Breed {
  final int id;
  final String name;
  final String coatType;
  final int avgGroomMinutes;
  final num avgPrice;
  final int avgScheduleWeeks;

  const Breed({
    required this.id,
    required this.name,
    required this.coatType,
    required this.avgGroomMinutes,
    required this.avgPrice,
    required this.avgScheduleWeeks,
  });

  factory Breed.fromJson(Map<String, dynamic> json) => Breed(
        id: json['id'] as int,
        name: json['name']?.toString() ?? '',
        coatType: json['coat_type']?.toString() ?? '',
        avgGroomMinutes: (json['avg_groom_minutes'] as num?)?.toInt() ?? 0,
        avgPrice: _num(json['avg_price']),
        avgScheduleWeeks: (json['avg_schedule_weeks'] as num?)?.toInt() ?? 0,
      );
}

class ClientRecord {
  final int id;
  final String uid;
  final String firstName;
  final String lastName;
  final String fullName;
  final String email;
  final String phone;
  final String address;
  final String postcode;
  final int dogCount;
  final bool hasLogin;

  /// Staff-only. Null when the current login is a client.
  final bool? chatty;
  final bool? leafletReceived;
  final String? notes;

  const ClientRecord({
    required this.id,
    required this.uid,
    required this.firstName,
    required this.lastName,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.address,
    required this.postcode,
    required this.dogCount,
    required this.hasLogin,
    this.chatty,
    this.leafletReceived,
    this.notes,
  });

  factory ClientRecord.fromJson(Map<String, dynamic> json) => ClientRecord(
        id: json['id'] as int,
        uid: json['uid']?.toString() ?? '',
        firstName: json['first_name']?.toString() ?? '',
        lastName: json['last_name']?.toString() ?? '',
        fullName: json['full_name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        phone: json['phone']?.toString() ?? '',
        address: json['address']?.toString() ?? '',
        postcode: json['postcode']?.toString() ?? '',
        dogCount: (json['dog_count'] as num?)?.toInt() ?? 0,
        hasLogin: json['has_login'] == true,
        // Absent (not merely false) when the viewer isn't staff.
        chatty: json.containsKey('chatty') ? json['chatty'] == true : null,
        leafletReceived:
            json.containsKey('leaflet_received') ? json['leaflet_received'] == true : null,
        notes: json['notes']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'first_name': firstName,
        'last_name': lastName,
        'email': email,
        'phone': phone,
        'address': address,
        'postcode': postcode,
        if (chatty != null) 'chatty': chatty,
        if (leafletReceived != null) 'leaflet_received': leafletReceived,
        if (notes != null) 'notes': notes,
      };
}

/// A row in the Doguments list — a summary of the whole profile.
class DogSummary {
  final int id;
  final String name;
  final String? profileImage;
  final int clientId;
  final String clientUid;
  final String clientFirstName;
  final String clientFullName;
  final String clientPhone;
  final String breedLabel;
  final int groomMinutes;
  final num price;
  final int scheduleWeeks;
  final bool isActive;

  /// Staff-only.
  final String? temperament;
  final String? temperamentDisplay;

  const DogSummary({
    required this.id,
    required this.name,
    required this.clientId,
    required this.clientUid,
    required this.clientFirstName,
    required this.clientFullName,
    required this.clientPhone,
    required this.breedLabel,
    required this.groomMinutes,
    required this.price,
    required this.scheduleWeeks,
    required this.isActive,
    this.profileImage,
    this.temperament,
    this.temperamentDisplay,
  });

  factory DogSummary.fromJson(Map<String, dynamic> json) => DogSummary(
        id: json['id'] as int,
        name: json['name']?.toString() ?? '',
        profileImage: json['profile_image']?.toString(),
        clientId: (json['client'] as num?)?.toInt() ?? 0,
        clientUid: json['client_uid']?.toString() ?? '',
        clientFirstName: json['client_first_name']?.toString() ?? '',
        clientFullName: json['client_full_name']?.toString() ?? '',
        clientPhone: json['client_phone']?.toString() ?? '',
        breedLabel: json['breed_label']?.toString() ?? '',
        groomMinutes: (json['groom_minutes_effective'] as num?)?.toInt() ?? 0,
        price: _num(json['price_effective']),
        scheduleWeeks: (json['schedule_weeks_effective'] as num?)?.toInt() ?? 0,
        isActive: json['is_active'] != false,
        temperament: json['temperament']?.toString(),
        temperamentDisplay: json['temperament_display']?.toString(),
      );

  /// Everything the Doguments row shows after the name, in one line.
  String get summaryLine =>
      '$clientFirstName · $clientUid · ${formatDuration(groomMinutes)} · '
      '${formatMoney(price)} · every ${scheduleWeeks}w';

  bool matchesSearch(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        clientFullName.toLowerCase().contains(q) ||
        clientUid.toLowerCase().contains(q) ||
        clientPhone.replaceAll(' ', '').contains(q.replaceAll(' ', ''));
  }
}

class ProblemArea {
  final int id;
  final List<String> gridCells;
  final String reason;
  final String source;

  const ProblemArea({
    required this.id,
    required this.gridCells,
    required this.reason,
    required this.source,
  });

  factory ProblemArea.fromJson(Map<String, dynamic> json) => ProblemArea(
        id: (json['id'] as num?)?.toInt() ?? 0,
        gridCells:
            (json['grid_cells'] as List?)?.map((cell) => cell.toString()).toList() ?? const [],
        reason: json['reason']?.toString() ?? '',
        source: json['source']?.toString() ?? 'STAFF',
      );

  Map<String, dynamic> toJson() => {'grid_cells': gridCells, 'reason': reason};
}

class Dog {
  final int id;
  final int clientId;
  final ClientRecord? client;
  final String name;
  final int? breedId;
  final String breedOther;
  final String breedLabel;
  final DateTime? dateOfBirth;
  final String sex;
  final bool isNeutered;
  final String? profileImage;

  /// Overrides — null means "inherit from the breed".
  final int? groomMinutesOverride;
  final num? priceOverride;
  final int? scheduleWeeksOverride;

  final int groomMinutes;
  final num price;
  final int scheduleWeeks;

  final String prefBody;
  final String prefFeet;
  final String prefTail;
  final String prefFace;
  final String prefEars;
  final String prefSkirt;

  final String medicalNotes;
  final String vet;
  final String generalNotes;
  final bool isActive;

  /// Staff-only.
  final String? temperament;
  final String? temperamentDisplay;
  final String? temperamentNotes;
  final List<ProblemArea>? problemAreas;

  const Dog({
    required this.id,
    required this.clientId,
    required this.name,
    required this.breedLabel,
    required this.breedOther,
    required this.sex,
    required this.isNeutered,
    required this.groomMinutes,
    required this.price,
    required this.scheduleWeeks,
    required this.prefBody,
    required this.prefFeet,
    required this.prefTail,
    required this.prefFace,
    required this.prefEars,
    required this.prefSkirt,
    required this.medicalNotes,
    required this.vet,
    required this.generalNotes,
    required this.isActive,
    this.client,
    this.breedId,
    this.dateOfBirth,
    this.profileImage,
    this.groomMinutesOverride,
    this.priceOverride,
    this.scheduleWeeksOverride,
    this.temperament,
    this.temperamentDisplay,
    this.temperamentNotes,
    this.problemAreas,
  });

  factory Dog.fromJson(Map<String, dynamic> json) => Dog(
        id: json['id'] as int,
        clientId: (json['client'] as num?)?.toInt() ?? 0,
        client: json['client_detail'] is Map<String, dynamic>
            ? ClientRecord.fromJson(json['client_detail'] as Map<String, dynamic>)
            : null,
        name: json['name']?.toString() ?? '',
        breedId: (json['breed'] as num?)?.toInt(),
        breedOther: json['breed_other']?.toString() ?? '',
        breedLabel: json['breed_label']?.toString() ?? '',
        dateOfBirth: _dateTime(json['date_of_birth']),
        sex: json['sex']?.toString() ?? '',
        isNeutered: json['is_neutered'] == true,
        profileImage: json['profile_image']?.toString(),
        groomMinutesOverride: (json['groom_minutes'] as num?)?.toInt(),
        priceOverride: json['price'] == null ? null : _num(json['price']),
        scheduleWeeksOverride: (json['schedule_weeks'] as num?)?.toInt(),
        groomMinutes: (json['groom_minutes_effective'] as num?)?.toInt() ?? 0,
        price: _num(json['price_effective']),
        scheduleWeeks: (json['schedule_weeks_effective'] as num?)?.toInt() ?? 0,
        prefBody: json['pref_body']?.toString() ?? '',
        prefFeet: json['pref_feet']?.toString() ?? '',
        prefTail: json['pref_tail']?.toString() ?? '',
        prefFace: json['pref_face']?.toString() ?? '',
        prefEars: json['pref_ears']?.toString() ?? '',
        prefSkirt: json['pref_skirt']?.toString() ?? '',
        medicalNotes: json['medical_notes']?.toString() ?? '',
        vet: json['vet']?.toString() ?? '',
        generalNotes: json['general_notes']?.toString() ?? '',
        isActive: json['is_active'] != false,
        temperament: json['temperament']?.toString(),
        temperamentDisplay: json['temperament_display']?.toString(),
        temperamentNotes: json['temperament_notes']?.toString(),
        problemAreas: json.containsKey('problem_areas')
            ? ((json['problem_areas'] as List?) ?? const [])
                .map((area) => ProblemArea.fromJson(area as Map<String, dynamic>))
                .toList()
            : null,
      );

  /// The six grooming preference areas, in the order Jess lists them.
  List<({String label, String value})> get preferences => [
        (label: 'Body', value: prefBody),
        (label: 'Feet shape', value: prefFeet),
        (label: 'Tail', value: prefTail),
        (label: 'Face', value: prefFace),
        (label: 'Ears', value: prefEars),
        (label: 'Skirt', value: prefSkirt),
      ];

  String? get ageLabel {
    if (dateOfBirth == null) return null;
    final years = DateTime.now().difference(dateOfBirth!).inDays ~/ 365;
    if (years < 1) {
      final months = DateTime.now().difference(dateOfBirth!).inDays ~/ 30;
      return '$months month${months == 1 ? '' : 's'}';
    }
    return '$years year${years == 1 ? '' : 's'}';
  }
}

class DogPhoto {
  final int id;
  final int dogId;
  final String imageUrl;
  final DateTime takenAt;
  final String caption;

  const DogPhoto({
    required this.id,
    required this.dogId,
    required this.imageUrl,
    required this.takenAt,
    required this.caption,
  });

  factory DogPhoto.fromJson(Map<String, dynamic> json) => DogPhoto(
        id: json['id'] as int,
        dogId: (json['dog'] as num?)?.toInt() ?? 0,
        imageUrl: json['image']?.toString() ?? '',
        takenAt: _dateTime(json['taken_at']) ?? DateTime.now(),
        caption: json['caption']?.toString() ?? '',
      );
}

class Appointment {
  final int id;
  final int dogId;
  final String dogName;
  final int clientId;
  final String clientName;
  final String clientPhone;
  final DateTime startAt;
  final DateTime endAt;
  final int durationMinutes;
  final String bookingType;
  final String status;
  final num? priceQuoted;
  final String notes;

  /// Staff-only.
  final String? dogTemperament;

  const Appointment({
    required this.id,
    required this.dogId,
    required this.dogName,
    required this.clientId,
    required this.clientName,
    required this.clientPhone,
    required this.startAt,
    required this.endAt,
    required this.durationMinutes,
    required this.bookingType,
    required this.status,
    required this.notes,
    this.priceQuoted,
    this.dogTemperament,
  });

  factory Appointment.fromJson(Map<String, dynamic> json) => Appointment(
        id: json['id'] as int,
        dogId: (json['dog'] as num?)?.toInt() ?? 0,
        dogName: json['dog_name']?.toString() ?? '',
        clientId: (json['client_id'] as num?)?.toInt() ?? 0,
        clientName: json['client_name']?.toString() ?? '',
        clientPhone: json['client_phone']?.toString() ?? '',
        startAt: _dateTime(json['start_at']) ?? DateTime.now(),
        endAt: _dateTime(json['end_at']) ?? DateTime.now(),
        durationMinutes: (json['duration_minutes'] as num?)?.toInt() ?? 0,
        bookingType: json['booking_type']?.toString() ?? 'ADHOC',
        status: json['status']?.toString() ?? 'BOOKED',
        priceQuoted: json['price_quoted'] == null ? null : _num(json['price_quoted']),
        notes: json['notes']?.toString() ?? '',
        dogTemperament: json['dog_temperament']?.toString(),
      );

  String get timeRange => '${formatTime(startAt)} – ${formatTime(endAt)}';

  String get bookingTypeLabel => switch (bookingType) {
        'FIRST_GROOM' => 'First groom',
        'SCHEDULED' => 'Scheduled',
        _ => 'Ad hoc',
      };

  String get statusLabel => switch (status) {
        'REQUESTED' => 'Requested',
        'CONFIRMED' => 'Confirmed',
        'IN_PROGRESS' => 'In progress',
        'COMPLETED' => 'Completed',
        'CANCELLED' => 'Cancelled',
        'NO_SHOW' => 'No show',
        _ => 'Booked',
      };

  bool get isCancelled => status == 'CANCELLED' || status == 'NO_SHOW';
}

/// One advisory warning from the pre-booking check. Never blocking.
class BookingWarning {
  final String code;
  final String message;

  const BookingWarning({required this.code, required this.message});

  factory BookingWarning.fromJson(Map<String, dynamic> json) => BookingWarning(
        code: json['code']?.toString() ?? '',
        message: json['message']?.toString() ?? '',
      );
}

class BookingCheck {
  final List<BookingWarning> warnings;
  final DateTime? suggestedEndAt;
  final num? suggestedPrice;

  const BookingCheck({required this.warnings, this.suggestedEndAt, this.suggestedPrice});

  factory BookingCheck.fromJson(Map<String, dynamic> json) => BookingCheck(
        warnings: ((json['warnings'] as List?) ?? const [])
            .map((w) => BookingWarning.fromJson(w as Map<String, dynamic>))
            .toList(),
        suggestedEndAt: _dateTime(json['suggested_end_at']),
        suggestedPrice: json['suggested_price'] == null ? null : _num(json['suggested_price']),
      );

  bool get hasWarnings => warnings.isNotEmpty;
}

class PhaseTiming {
  final String phase;
  final int durationSeconds;
  final bool enteredManually;

  const PhaseTiming({
    required this.phase,
    required this.durationSeconds,
    this.enteredManually = false,
  });

  factory PhaseTiming.fromJson(Map<String, dynamic> json) => PhaseTiming(
        phase: json['phase']?.toString() ?? '',
        durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
        enteredManually: json['entered_manually'] == true,
      );

  Map<String, dynamic> toJson() => {
        'phase': phase,
        'duration_seconds': durationSeconds,
        'entered_manually': enteredManually,
      };

  static const phaseOrder = ['PREP', 'WASH', 'DRY', 'CLIP', 'STRIP'];

  static String labelFor(String phase) => switch (phase) {
        'PREP' => 'Prep',
        'WASH' => 'Wash',
        'DRY' => 'Dry',
        'CLIP' => 'Clip',
        'STRIP' => 'Strip',
        _ => phase,
      };
}

class GroomSession {
  final int id;
  final int dogId;
  final String dogName;
  final DateTime startedAt;
  final List<PhaseTiming> timings;
  final int totalMinutes;
  final DateTime? appliedToDogAt;

  const GroomSession({
    required this.id,
    required this.dogId,
    required this.dogName,
    required this.startedAt,
    required this.timings,
    required this.totalMinutes,
    this.appliedToDogAt,
  });

  factory GroomSession.fromJson(Map<String, dynamic> json) => GroomSession(
        id: json['id'] as int,
        dogId: (json['dog'] as num?)?.toInt() ?? 0,
        dogName: json['dog_name']?.toString() ?? '',
        startedAt: _dateTime(json['started_at']) ?? DateTime.now(),
        timings: ((json['timings'] as List?) ?? const [])
            .map((t) => PhaseTiming.fromJson(t as Map<String, dynamic>))
            .toList(),
        totalMinutes: (json['total_minutes'] as num?)?.toInt() ?? 0,
        appliedToDogAt: _dateTime(json['applied_to_dog_at']),
      );
}

class TodoItem {
  final int id;
  final String text;
  final bool isDone;
  final DateTime? dueDate;

  const TodoItem({
    required this.id,
    required this.text,
    required this.isDone,
    this.dueDate,
  });

  factory TodoItem.fromJson(Map<String, dynamic> json) => TodoItem(
        id: json['id'] as int,
        text: json['text']?.toString() ?? '',
        isDone: json['is_done'] == true,
        dueDate: _dateTime(json['due_date']),
      );
}

class Equipment {
  final int id;
  final String name;
  final String uid;
  final DateTime? lastSharpened;
  final bool patTested;
  final DateTime? patTestedDate;
  final String notes;
  final bool isActive;

  const Equipment({
    required this.id,
    required this.name,
    required this.uid,
    required this.patTested,
    required this.notes,
    required this.isActive,
    this.lastSharpened,
    this.patTestedDate,
  });

  factory Equipment.fromJson(Map<String, dynamic> json) => Equipment(
        id: json['id'] as int,
        name: json['name']?.toString() ?? '',
        uid: json['uid']?.toString() ?? '',
        lastSharpened: _dateTime(json['last_sharpened']),
        patTested: json['pat_tested'] == true,
        patTestedDate: _dateTime(json['pat_tested_date']),
        notes: json['notes']?.toString() ?? '',
        isActive: json['is_active'] != false,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'uid': uid,
        'last_sharpened': lastSharpened?.toIso8601String().split('T').first,
        'pat_tested': patTested,
        'pat_tested_date': patTestedDate?.toIso8601String().split('T').first,
        'notes': notes,
        'is_active': isActive,
      };
}

class InvoiceLine {
  final String description;
  final num quantity;
  final num unitPrice;
  final num lineTotal;

  const InvoiceLine({
    required this.description,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  factory InvoiceLine.fromJson(Map<String, dynamic> json) => InvoiceLine(
        description: json['description']?.toString() ?? '',
        quantity: _num(json['quantity']),
        unitPrice: _num(json['unit_price']),
        lineTotal: _num(json['line_total']),
      );

  Map<String, dynamic> toJson() => {
        'description': description,
        'quantity': quantity.toString(),
        'unit_price': unitPrice.toString(),
      };
}

class Invoice {
  final int id;
  final int clientId;
  final String clientName;
  final String number;
  final DateTime? issueDate;
  final String status;
  final List<InvoiceLine> lines;
  final num total;
  final num amountPaid;
  final num balance;

  const Invoice({
    required this.id,
    required this.clientId,
    required this.clientName,
    required this.number,
    required this.status,
    required this.lines,
    required this.total,
    required this.amountPaid,
    required this.balance,
    this.issueDate,
  });

  factory Invoice.fromJson(Map<String, dynamic> json) => Invoice(
        id: json['id'] as int,
        clientId: (json['client'] as num?)?.toInt() ?? 0,
        clientName: json['client_name']?.toString() ?? '',
        number: json['number']?.toString() ?? '',
        issueDate: _dateTime(json['issue_date']),
        status: json['status']?.toString() ?? 'DRAFT',
        lines: ((json['lines'] as List?) ?? const [])
            .map((l) => InvoiceLine.fromJson(l as Map<String, dynamic>))
            .toList(),
        total: _num(json['total']),
        amountPaid: _num(json['amount_paid']),
        balance: _num(json['balance']),
      );
}

class AppSettings {
  final String businessName;
  final String contactPhone;
  final String contactEmail;
  final bool invoicingVisibleToClients;

  const AppSettings({
    required this.businessName,
    required this.contactPhone,
    required this.contactEmail,
    required this.invoicingVisibleToClients,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        businessName: json['business_name']?.toString() ?? 'Mojo and Co',
        contactPhone: json['contact_phone']?.toString() ?? '',
        contactEmail: json['contact_email']?.toString() ?? '',
        invoicingVisibleToClients: json['invoicing_visible_to_clients'] == true,
      );
}

class IntakeSubmission {
  final int id;
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String postcode;
  final List<dynamic> dogs;
  final String status;
  final DateTime? createdAt;

  const IntakeSubmission({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    required this.postcode,
    required this.dogs,
    required this.status,
    this.createdAt,
  });

  factory IntakeSubmission.fromJson(Map<String, dynamic> json) => IntakeSubmission(
        id: json['id'] as int,
        firstName: json['first_name']?.toString() ?? '',
        lastName: json['last_name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        phone: json['phone']?.toString() ?? '',
        postcode: json['postcode']?.toString() ?? '',
        dogs: (json['dogs'] as List?) ?? const [],
        status: json['status']?.toString() ?? 'PENDING',
        createdAt: _dateTime(json['created_at']),
      );

  String get fullName => '$firstName $lastName'.trim();
}

class ClaimRequest {
  final int id;
  final String username;
  final String claimedName;
  final String claimedEmail;
  final String claimedPostcode;
  final int? matchedClientId;
  final String? matchedClientName;
  final String status;

  const ClaimRequest({
    required this.id,
    required this.username,
    required this.claimedName,
    required this.claimedEmail,
    required this.claimedPostcode,
    required this.status,
    this.matchedClientId,
    this.matchedClientName,
  });

  factory ClaimRequest.fromJson(Map<String, dynamic> json) => ClaimRequest(
        id: json['id'] as int,
        username: json['username']?.toString() ?? '',
        claimedName: json['claimed_name']?.toString() ?? '',
        claimedEmail: json['claimed_email']?.toString() ?? '',
        claimedPostcode: json['claimed_postcode']?.toString() ?? '',
        matchedClientId: (json['matched_client'] as num?)?.toInt(),
        matchedClientName: json['matched_client_name']?.toString(),
        status: json['status']?.toString() ?? 'PENDING',
      );
}
