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
  final String firstName;
  final String lastName;
  final bool isStaff;

  /// Gates the account-management screen. Handing out a password reset link is
  /// a step past ordinary staff access, so the server checks it too — this
  /// only decides whether the tile is worth showing.
  final bool isSuperuser;
  final int? clientId;

  const CurrentUser({
    required this.id,
    required this.username,
    required this.email,
    required this.isStaff,
    this.firstName = '',
    this.lastName = '',
    this.isSuperuser = false,
    this.clientId,
  });

  factory CurrentUser.fromJson(Map<String, dynamic> json) => CurrentUser(
        id: json['id'] as int,
        username: json['username']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        firstName: json['first_name']?.toString() ?? '',
        lastName: json['last_name']?.toString() ?? '',
        isStaff: json['is_staff'] == true,
        isSuperuser: json['is_superuser'] == true,
        clientId: json['client_id'] as int?,
      );

  /// What to call this person on screen.
  ///
  /// Jess asked to be "Jessica Croll" rather than "jess" — which was her
  /// *username* showing, because that was all this had. The username is still
  /// what she signs in with and is not something to change lightly; her name
  /// is a separate thing, and this is it.
  String get displayName {
    final full = [firstName, lastName].where((part) => part.isNotEmpty).join(' ');
    return full.isEmpty ? username : full;
  }

  /// A client login with no linked record can't see anything yet — the app
  /// routes these to the "claim your profile" flow.
  bool get needsToClaimProfile => !isStaff && clientId == null;
}

/// A reference entry: what an ailment means, and what it means for a groom.
///
/// **Nothing here is written by the app.** It is veterinary information, and
/// [source] exists so an entry is attributable to whoever said it — one with
/// no source is one to be wary of.
class MedicalNote {
  final int id;
  final String title;
  final String kind;
  final String kindDisplay;
  final String whatItMeans;
  final String groomingCare;
  final String firstAid;
  final String source;
  final List<int> breedIds;
  final List<String> breedNames;

  const MedicalNote({
    required this.id,
    required this.title,
    this.kind = 'AILMENT',
    this.kindDisplay = '',
    this.whatItMeans = '',
    this.groomingCare = '',
    this.firstAid = '',
    this.source = '',
    this.breedIds = const [],
    this.breedNames = const [],
  });

  factory MedicalNote.fromJson(Map<String, dynamic> json) => MedicalNote(
        id: json['id'] as int,
        title: json['title']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'AILMENT',
        kindDisplay: json['kind_display']?.toString() ?? '',
        whatItMeans: json['what_it_means']?.toString() ?? '',
        groomingCare: json['grooming_care']?.toString() ?? '',
        firstAid: json['first_aid']?.toString() ?? '',
        source: json['source']?.toString() ?? '',
        breedIds: ((json['breeds'] as List?) ?? const [])
            .map((b) => (b as num).toInt())
            .toList(),
        breedNames: ((json['breed_names'] as List?) ?? const [])
            .map((b) => b.toString())
            .toList(),
      );

  bool get isAttributed => source.trim().isNotEmpty;
}

/// Jess's breed standards record — "a little snippet of the whole dog".
///
/// Started as three numbers (time, price, interval) and is now the reference
/// sheet she looks a breed up in. Everything descriptive is free text: she is
/// still working out what belongs here, and a fixed option list would be
/// something to work around rather than with.
///
/// [sizeBand] and [coatType] are the two axes of the price grid, so they are
/// the two that are not merely descriptive.
class Breed {
  final int id;
  final String name;
  final String coatType;
  final String coatTypeDisplay;
  final String sizeBand;
  final String sizeBandDisplay;

  /// False for hairless, corded and silky — the three coats Jess's price list
  /// does not cover. Say "not on the price list" rather than showing a figure
  /// nobody set.
  final bool isPricedByTheGrid;

  final int avgGroomMinutes;
  final num avgPrice;
  final int avgScheduleWeeks;

  final String kennelClubGroup;
  final String kennelClubGroupDisplay;
  final String activityLevel;
  final String activityLevelDisplay;
  final int? lifeSpanMinYears;
  final int? lifeSpanMaxYears;
  final int? heightMinCm;
  final int? heightMaxCm;
  final num? weightMinKg;
  final num? weightMaxKg;
  final String originalPurpose;

  /// What the breed is generally like, in Jess's words off the Kennel Club's
  /// pages. Nothing seeds it and nothing here writes it — see the model.
  ///
  /// Not a substitute for [Dog.temperament], which is the dog in front of you
  /// and drives the booking limits.
  final String typicalTemperament;

  final String chestShape;
  final String headType;
  final String earShape;
  /// Renamed from `headShape` at Jess's request — `headType` already covered
  /// the head, and the tail had nowhere to go.
  final String tailShape;
  final String coatColours;

  final String groomingTechnique;
  final String groomStyleBody;
  final String groomStyleHead;
  final String groomStyleFeet;
  final String groomStyleTail;
  final String groomStyleEars;

  final String commonAilments;
  final String notes;
  final List<MedicalNote> medicalNotes;

  const Breed({
    required this.id,
    required this.name,
    required this.coatType,
    required this.avgGroomMinutes,
    required this.avgPrice,
    required this.avgScheduleWeeks,
    this.coatTypeDisplay = '',
    this.sizeBand = '',
    this.sizeBandDisplay = '',
    this.isPricedByTheGrid = true,
    this.kennelClubGroup = '',
    this.kennelClubGroupDisplay = '',
    this.activityLevel = '',
    this.activityLevelDisplay = '',
    this.lifeSpanMinYears,
    this.lifeSpanMaxYears,
    this.heightMinCm,
    this.heightMaxCm,
    this.weightMinKg,
    this.weightMaxKg,
    this.originalPurpose = '',
    this.typicalTemperament = '',
    this.chestShape = '',
    this.headType = '',
    this.earShape = '',
    this.tailShape = '',
    this.coatColours = '',
    this.groomingTechnique = '',
    this.groomStyleBody = '',
    this.groomStyleHead = '',
    this.groomStyleFeet = '',
    this.groomStyleTail = '',
    this.groomStyleEars = '',
    this.commonAilments = '',
    this.notes = '',
    this.medicalNotes = const [],
  });

  factory Breed.fromJson(Map<String, dynamic> json) => Breed(
        id: json['id'] as int,
        name: json['name']?.toString() ?? '',
        coatType: json['coat_type']?.toString() ?? '',
        coatTypeDisplay: json['coat_type_display']?.toString() ?? '',
        sizeBand: json['size_band']?.toString() ?? '',
        sizeBandDisplay: json['size_band_display']?.toString() ?? '',
        isPricedByTheGrid: json['is_priced_by_the_grid'] != false,
        avgGroomMinutes: (json['avg_groom_minutes'] as num?)?.toInt() ?? 0,
        avgPrice: _num(json['avg_price']),
        avgScheduleWeeks: (json['avg_schedule_weeks'] as num?)?.toInt() ?? 0,
        kennelClubGroup: json['kennel_club_group']?.toString() ?? '',
        kennelClubGroupDisplay: json['kennel_club_group_display']?.toString() ?? '',
        activityLevel: json['activity_level']?.toString() ?? '',
        activityLevelDisplay: json['activity_level_display']?.toString() ?? '',
        lifeSpanMinYears: (json['life_span_min_years'] as num?)?.toInt(),
        lifeSpanMaxYears: (json['life_span_max_years'] as num?)?.toInt(),
        heightMinCm: (json['height_min_cm'] as num?)?.toInt(),
        heightMaxCm: (json['height_max_cm'] as num?)?.toInt(),
        weightMinKg: json['weight_min_kg'] == null ? null : _num(json['weight_min_kg']),
        weightMaxKg: json['weight_max_kg'] == null ? null : _num(json['weight_max_kg']),
        originalPurpose: json['original_purpose']?.toString() ?? '',
        typicalTemperament: json['typical_temperament']?.toString() ?? '',
        chestShape: json['chest_shape']?.toString() ?? '',
        headType: json['head_type']?.toString() ?? '',
        earShape: json['ear_shape']?.toString() ?? '',
        tailShape: json['tail_shape']?.toString() ?? '',
        coatColours: json['coat_colours']?.toString() ?? '',
        groomingTechnique: json['grooming_technique']?.toString() ?? '',
        groomStyleBody: json['groom_style_body']?.toString() ?? '',
        groomStyleHead: json['groom_style_head']?.toString() ?? '',
        groomStyleFeet: json['groom_style_feet']?.toString() ?? '',
        groomStyleTail: json['groom_style_tail']?.toString() ?? '',
        groomStyleEars: json['groom_style_ears']?.toString() ?? '',
        commonAilments: json['common_ailments']?.toString() ?? '',
        notes: json['notes']?.toString() ?? '',
        medicalNotes: ((json['medical_notes'] as List?) ?? const [])
            .map((n) => MedicalNote.fromJson(n as Map<String, dynamic>))
            .toList(),
      );

  /// "12–15 years", "from 12 years", or blank. Never a half-written range.
  String get lifeSpanLabel => _range(lifeSpanMinYears, lifeSpanMaxYears, 'years');
  String get heightLabel => _range(heightMinCm, heightMaxCm, 'cm');
  String get weightLabel => _range(weightMinKg, weightMaxKg, 'kg');

  static String _range(num? low, num? high, String unit) {
    String n(num value) =>
        value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
    if (low != null && high != null) {
      return low == high ? '${n(low)} $unit' : '${n(low)}–${n(high)} $unit';
    }
    if (low != null) return 'from ${n(low)} $unit';
    if (high != null) return 'up to ${n(high)} $unit';
    return '';
  }

  /// What this breed suggests a new dog's preferences should start as.
  ///
  /// Head maps to the dog's *face*: the breed record says head, a dog's
  /// preferences say face, and a groomer means the same area. Skirt has no
  /// breed counterpart. Blank styles are left out, so nothing is overwritten
  /// with emptiness.
  Map<String, String> get preferenceDefaults => {
        if (groomStyleBody.isNotEmpty) 'pref_body': groomStyleBody,
        if (groomStyleHead.isNotEmpty) 'pref_face': groomStyleHead,
        if (groomStyleFeet.isNotEmpty) 'pref_feet': groomStyleFeet,
        if (groomStyleTail.isNotEmpty) 'pref_tail': groomStyleTail,
        if (groomStyleEars.isNotEmpty) 'pref_ears': groomStyleEars,
      };

  /// Whether anyone has filled in the descriptive half yet.
  bool get hasStandardsRecord =>
      kennelClubGroupDisplay.isNotEmpty ||
      originalPurpose.isNotEmpty ||
      typicalTemperament.isNotEmpty ||
      groomingTechnique.isNotEmpty ||
      coatColours.isNotEmpty;
}

/// One thing Jess does — Full Groom, Nail Clipping, Hand Stripping.
///
/// [minutes] and [price] are **nullable and often null**: her price list
/// covers full grooms only, so everything else is blank until she fills it in.
/// Never render a null as a price. A service with [takesDogDefaults] is priced
/// off the dog instead, i.e. off the breed grid.
class ServiceItem {
  final int id;
  final String code;
  final String name;

  /// GROOM or NAILS — which record card this belongs to.
  final String category;
  final int? minutes;
  final num? price;
  final bool takesDogDefaults;
  final int sortOrder;

  const ServiceItem({
    required this.id,
    required this.code,
    required this.name,
    required this.category,
    required this.minutes,
    required this.price,
    required this.takesDogDefaults,
    required this.sortOrder,
  });

  factory ServiceItem.fromJson(Map<String, dynamic> json) => ServiceItem(
        id: json['id'] as int,
        code: json['code']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        category: json['category']?.toString() ?? ServiceType.groom,
        minutes: (json['default_minutes'] as num?)?.toInt(),
        price: json['default_price'] == null ? null : _num(json['default_price']),
        takesDogDefaults: json['takes_dog_defaults'] == true,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );

  /// What to show under the name. "Not set" rather than a made-up figure.
  String get summary {
    if (takesDogDefaults) return "The dog's own time and price";
    final length = minutes == null ? 'Length not set' : formatDuration(minutes!);
    final cost = price == null ? 'price not set' : formatMoney(price!);
    return '$length · $cost';
  }

  bool get isPriced => takesDogDefaults || price != null;
}

/// A client's request to have their own details corrected.
class ChangeRequest {
  final int id;
  final int clientId;
  final String clientName;
  final String requestedByUsername;
  final Map<String, dynamic> changes;
  final String status;
  final DateTime? createdAt;

  const ChangeRequest({
    required this.id,
    required this.clientId,
    required this.clientName,
    required this.requestedByUsername,
    required this.changes,
    required this.status,
    this.createdAt,
  });

  factory ChangeRequest.fromJson(Map<String, dynamic> json) => ChangeRequest(
        id: json['id'] as int,
        clientId: (json['client'] as num?)?.toInt() ?? 0,
        clientName: json['client_name']?.toString() ?? '',
        requestedByUsername: json['requested_by_username']?.toString() ?? '',
        changes: Map<String, dynamic>.from(json['changes'] as Map? ?? const {}),
        status: json['status']?.toString() ?? 'PENDING',
        createdAt: _dateTime(json['created_at']),
      );

  static const _labels = {
    'first_name': 'First name',
    'last_name': 'Last name',
    'phone': 'Phone',
    'email': 'Email',
    'address': 'Address',
    'postcode': 'Postcode',
    'emergency_contact_name': 'Emergency contact',
    'emergency_contact_phone': 'Their number',
  };

  static String labelFor(String field) => _labels[field] ?? field;

  String get summary =>
      changes.entries.map((e) => '${labelFor(e.key)}: ${e.value}').join('\n');
}

/// A scanned document filed against a dog.
///
/// [downloadUrl] is the only way to reach the file: it lives outside the
/// publicly served media directory, because a scanned intake form carries the
/// client's address, phone and signature.
class DogDocument {
  final int id;
  final int dogId;
  final String title;
  final String kind;
  final String kindDisplay;
  final bool visibleToClient;
  final String originalFilename;
  final String contentType;
  final int sizeBytes;
  final String downloadUrl;
  final DateTime? createdAt;

  const DogDocument({
    required this.id,
    required this.dogId,
    required this.title,
    required this.kind,
    required this.kindDisplay,
    required this.visibleToClient,
    required this.originalFilename,
    required this.contentType,
    required this.sizeBytes,
    required this.downloadUrl,
    this.createdAt,
  });

  factory DogDocument.fromJson(Map<String, dynamic> json) => DogDocument(
        id: json['id'] as int,
        dogId: (json['dog'] as num?)?.toInt() ?? 0,
        title: json['title']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'OTHER',
        kindDisplay: json['kind_display']?.toString() ?? '',
        visibleToClient: json['visible_to_client'] == true,
        originalFilename: json['original_filename']?.toString() ?? '',
        contentType: json['content_type']?.toString() ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        downloadUrl: json['download_url']?.toString() ?? '',
        createdAt: _dateTime(json['created_at']),
      );

  String get sizeLabel {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / 1024).round()} KB';
  }
}

/// How much is waiting for Jess. Drives the badge on the More tab.
class PendingCounts {
  final int appointmentRequests;
  final int intakeSubmissions;
  final int claimRequests;
  final int changeRequests;
  final int passwordResetRequests;
  final int total;

  const PendingCounts({
    this.appointmentRequests = 0,
    this.intakeSubmissions = 0,
    this.claimRequests = 0,
    this.changeRequests = 0,
    this.passwordResetRequests = 0,
    this.total = 0,
  });

  factory PendingCounts.fromJson(Map<String, dynamic> json) => PendingCounts(
        appointmentRequests: (json['appointment_requests'] as num?)?.toInt() ?? 0,
        intakeSubmissions: (json['intake_submissions'] as num?)?.toInt() ?? 0,
        claimRequests: (json['claim_requests'] as num?)?.toInt() ?? 0,
        changeRequests: (json['change_requests'] as num?)?.toInt() ?? 0,
        // Absent unless the signed-in user is a superuser.
        passwordResetRequests: (json['password_reset_requests'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
      );
}

/// One handling grade: what Jess calls it, and how many she'll take a day.
///
/// The five [code]s are fixed — every dog stores one — but the [label] is
/// hers to change in Settings, so nothing in the app should hardcode wording.
/// Anywhere a grade is named, the name comes from here or from the server's
/// `temperament_display`.
class TemperamentGrade {
  final int id;
  final String code;
  final String label;

  /// Blank means no limit, not zero.
  final int? maxPerDay;
  final int sortOrder;

  const TemperamentGrade({
    required this.id,
    required this.code,
    required this.label,
    required this.maxPerDay,
    required this.sortOrder,
  });

  factory TemperamentGrade.fromJson(Map<String, dynamic> json) => TemperamentGrade(
        id: json['id'] as int,
        code: json['temperament']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        maxPerDay: (json['max_per_day'] as num?)?.toInt(),
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );

  String get capLabel => maxPerDay == null ? 'No limit' : '$maxPerDay a day';
}

/// One of the six disclaimers off the paper booking card, as answered.
class Consent {
  final int id;
  final String kind;
  final String kindDisplay;
  final bool agreed;
  final String signedName;
  final DateTime? signedAt;

  const Consent({
    required this.id,
    required this.kind,
    required this.kindDisplay,
    required this.agreed,
    required this.signedName,
    this.signedAt,
  });

  factory Consent.fromJson(Map<String, dynamic> json) => Consent(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: json['kind']?.toString() ?? '',
        kindDisplay: json['kind_display']?.toString() ?? '',
        agreed: json['agreed'] == true,
        signedName: json['signed_name']?.toString() ?? '',
        signedAt: _dateTime(json['signed_at']),
      );
}

/// One of the six disclaimers, with the wording as the server currently has it.
///
/// Served rather than hardcoded here: two copies of a string drift, and the
/// copy that matters is the one stored against a signature. The app also needs
/// the list *before* any consent exists — the walk-in case — so it cannot read
/// them off existing rows.
class ConsentKindOption {
  final String kind;
  final String label;
  final bool required;

  const ConsentKindOption({
    required this.kind,
    required this.label,
    required this.required,
  });

  factory ConsentKindOption.fromJson(Map<String, dynamic> json) => ConsentKindOption(
        kind: json['kind']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        required: json['required'] == true,
      );
}

class ClientRecord {
  final int id;

  /// Jess's filing reference, e.g. MOJO-001.
  ///
  /// Null for a client login — she asked for it to be hidden from them. Null
  /// means "the server withheld it", the same as every other gated field, so
  /// it must not be coerced to an empty string.
  final String? uid;
  final String firstName;
  final String lastName;
  final String fullName;
  final String email;
  final String phone;
  final String address;
  final String postcode;
  final String emergencyContactName;
  final String emergencyContactPhone;
  final int dogCount;
  final bool hasLogin;
  final List<Consent> consents;

  /// Whether photos of this client's dogs may be used publicly.
  ///
  /// Null means nobody has ever asked, which is **not** the same as "no".
  /// Anything about to publish a photo must treat null as "don't".
  final bool? photoConsent;

  /// Staff-only. Null when the current login is a client.
  final bool? chatty;
  final bool? leafletReceived;
  /// Jess's reading of an owner, not a fact about them — staff-only with the
  /// rest of this block, and nullable for the same reason: null means the
  /// server withheld it, never "no".
  final bool? particularAboutStandard;
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
    this.emergencyContactName = '',
    this.emergencyContactPhone = '',
    this.consents = const [],
    this.photoConsent,
    this.chatty,
    this.leafletReceived,
    this.particularAboutStandard,
    this.notes,
  });

  factory ClientRecord.fromJson(Map<String, dynamic> json) => ClientRecord(
        id: json['id'] as int,
        uid: json['uid']?.toString(),
        firstName: json['first_name']?.toString() ?? '',
        lastName: json['last_name']?.toString() ?? '',
        fullName: json['full_name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        phone: json['phone']?.toString() ?? '',
        address: json['address']?.toString() ?? '',
        postcode: json['postcode']?.toString() ?? '',
        emergencyContactName: json['emergency_contact_name']?.toString() ?? '',
        emergencyContactPhone: json['emergency_contact_phone']?.toString() ?? '',
        dogCount: (json['dog_count'] as num?)?.toInt() ?? 0,
        hasLogin: json['has_login'] == true,
        consents: ((json['consents'] as List?) ?? const [])
            .map((entry) => Consent.fromJson(entry as Map<String, dynamic>))
            .toList(),
        // Deliberately not coerced to false: a missing key means never asked.
        photoConsent: json['photo_consent'] is bool ? json['photo_consent'] as bool : null,
        // Absent (not merely false) when the viewer isn't staff.
        chatty: json.containsKey('chatty') ? json['chatty'] == true : null,
        leafletReceived:
            json.containsKey('leaflet_received') ? json['leaflet_received'] == true : null,
        particularAboutStandard: json.containsKey('particular_about_standard')
            ? json['particular_about_standard'] == true
            : null,
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
        'emergency_contact_name': emergencyContactName,
        'emergency_contact_phone': emergencyContactPhone,
        if (chatty != null) 'chatty': chatty,
        if (leafletReceived != null) 'leaflet_received': leafletReceived,
        if (particularAboutStandard != null)
          'particular_about_standard': particularAboutStandard,
        if (notes != null) 'notes': notes,
      };
}

/// A row in the Doguments list — a summary of the whole profile.
class DogSummary {
  final int id;
  final String name;
  final String? profileImage;
  final int clientId;
  /// Null for a client login — see [ClientRecord.uid].
  final String? clientUid;
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
    this.clientUid,
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
        clientUid: json['client_uid']?.toString(),
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
  ///
  /// The UID is dropped when absent rather than rendered as a gap — a client
  /// login would otherwise get 'Alice ·  · 1h 45m'.
  String get summaryLine => [
        clientFirstName,
        ?clientUid,
        formatDuration(groomMinutes),
        formatMoney(price),
        'every ${scheduleWeeks}w',
      ].join(' · ');

  bool matchesSearch(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        clientFullName.toLowerCase().contains(q) ||
        (clientUid?.toLowerCase().contains(q) ?? false) ||
        clientPhone.replaceAll(' ', '').contains(q.replaceAll(' ', ''));
  }
}

/// A client asking to cancel or move one of their own bookings.
///
/// Asking is not doing: the booking stands, unchanged, until Jess approves.
/// Nothing here should be rendered as though the change has happened.
class AppointmentChangeRequest {
  final int id;
  final int appointmentId;
  final DateTime? appointmentStartAt;
  final String dogName;
  final String clientName;
  final String clientPhone;
  final String kind;
  final DateTime? preferredStartAt;
  final String note;
  final String status;
  final String requestedByUsername;

  const AppointmentChangeRequest({
    required this.id,
    required this.appointmentId,
    required this.dogName,
    required this.clientName,
    required this.clientPhone,
    required this.kind,
    required this.note,
    required this.status,
    required this.requestedByUsername,
    this.appointmentStartAt,
    this.preferredStartAt,
  });

  factory AppointmentChangeRequest.fromJson(Map<String, dynamic> json) =>
      AppointmentChangeRequest(
        id: (json['id'] as num).toInt(),
        appointmentId: (json['appointment'] as num).toInt(),
        appointmentStartAt: _parseDate(json['appointment_start_at']),
        dogName: json['dog_name']?.toString() ?? '',
        clientName: json['client_name']?.toString() ?? '',
        clientPhone: json['client_phone']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'CANCEL',
        preferredStartAt: _parseDate(json['preferred_start_at']),
        note: json['note']?.toString() ?? '',
        status: json['status']?.toString() ?? 'PENDING',
        requestedByUsername: json['requested_by_username']?.toString() ?? '',
      );

  static DateTime? _parseDate(Object? raw) =>
      raw == null ? null : DateTime.tryParse(raw.toString())?.toLocal();

  bool get isCancellation => kind == 'CANCEL';
  bool get isPending => status == 'PENDING';
  String get kindLabel => isCancellation ? 'Cancel' : 'Move';
}

/// One row of "who needs booking in" — `GET /api/dogs/due/`.
///
/// [dueDate] and [daysOverdue] are **nullable and mean "never groomed"**, not
/// "not due". The server deliberately does not invent a date for a dog with no
/// completed groom behind it, so neither may be coerced to a number here — the
/// same rule as everywhere else in this file.
class DueDog {
  final int dogId;
  final String dogName;
  final String breedLabel;
  final int clientId;
  final String clientName;
  final String clientPhone;
  final String? lastGroomDate;
  final String? dueDate;
  final int? daysOverdue;
  final int scheduleWeeks;
  final String basis;

  const DueDog({
    required this.dogId,
    required this.dogName,
    required this.breedLabel,
    required this.clientId,
    required this.clientName,
    required this.clientPhone,
    required this.scheduleWeeks,
    required this.basis,
    this.lastGroomDate,
    this.dueDate,
    this.daysOverdue,
  });

  factory DueDog.fromJson(Map<String, dynamic> json) => DueDog(
        dogId: (json['dog_id'] as num).toInt(),
        dogName: json['dog_name']?.toString() ?? '',
        breedLabel: json['breed_label']?.toString() ?? '',
        clientId: (json['client_id'] as num).toInt(),
        clientName: json['client_name']?.toString() ?? '',
        clientPhone: json['client_phone']?.toString() ?? '',
        lastGroomDate: json['last_groom_date']?.toString(),
        dueDate: json['due_date']?.toString(),
        daysOverdue: (json['days_overdue'] as num?)?.toInt(),
        scheduleWeeks: (json['schedule_weeks'] as num?)?.toInt() ?? 8,
        basis: json['basis']?.toString() ?? '',
      );

  bool get neverGroomed => daysOverdue == null;
  bool get isOverdue => (daysOverdue ?? 0) > 0;

  /// "28 days overdue" / "due in 5 days" / "never been in".
  String get whenLabel {
    final days = daysOverdue;
    if (days == null) return 'Never been in';
    if (days > 0) return '$days ${days == 1 ? 'day' : 'days'} overdue';
    if (days == 0) return 'Due today';
    final ahead = -days;
    return 'Due in $ahead ${ahead == 1 ? 'day' : 'days'}';
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
  /// Yes, no, or **null for "nobody asked"**.
  ///
  /// Not a plain bool. It used to be `json['is_neutered'] == true`, which
  /// turned an unanswered question into a confident "intact" — the same
  /// coercion CLAUDE.md forbids for every other withheld or unset field.
  final bool? isNeutered;
  final String colour;
  final String microchipNumber;
  final String? profileImage;

  /// Overrides — null means "inherit from the breed".
  final int? groomMinutesOverride;
  final num? priceOverride;
  final int? scheduleWeeksOverride;

  final int groomMinutes;
  final num price;
  final int scheduleWeeks;

  /// No agreed interval — this one comes when the owner rings.
  ///
  /// It does not change [scheduleWeeks]; what it changes is that the "who is
  /// due" list stops volunteering this dog, because "last groom + interval" is
  /// a deadline nobody set for it.
  final bool isAdHoc;

  /// Daycare, and which days. Not staff-only: it is the arrangement the owner
  /// made, the same call as [defaultServices].
  ///
  /// [daycareDays] holds weekday numbers, 0 = Monday, sorted by the server.
  /// [daycareDaysLabel] is the server's wording of them ("Mon, Wed, Fri"), so
  /// the app and the admin cannot drift onto different names for a Tuesday.
  final bool isDaycare;
  final List<int> daycareDays;
  final String daycareDaysLabel;

  final String prefBody;
  final String prefFeet;
  final String prefTail;
  final String prefFace;
  final String prefEars;
  final String prefSkirt;

  /// Ids of what this dog usually has done. Not staff-only — it is what the
  /// owner asked for, and a client needs it to request the right booking.
  final List<int> defaultServices;

  /// The paper booking card asks these separately rather than as one
  /// "anything medical?" box, so they are separate here too.
  final String allergies;
  final String medications;
  final String medicalIssues;
  final String vaccinations;
  final String medicalNotes;
  final String vet;
  final String lastVetVisit;
  final String ownerGrooming;
  final String generalNotes;
  final bool isActive;

  /// Staff-only.
  final String? temperament;
  final String? temperamentDisplay;
  final String? temperamentNotes;

  /// Staff-only, so **nullable**: null means the server withheld it, not that
  /// no restraint is needed. Never render it as "no" without a null check —
  /// telling a groomer a bitey dog needs nothing is how somebody gets bitten.
  final bool? requiresRestraint;

  /// What this dog's grooms have actually taken, once there are enough of
  /// them. Null means not enough history yet, and the breed estimate stands.
  final int? averageGroomMinutes;
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
    this.isAdHoc = false,
    this.isDaycare = false,
    this.daycareDays = const [],
    this.daycareDaysLabel = '',
    required this.prefBody,
    required this.prefFeet,
    required this.prefTail,
    required this.prefFace,
    required this.prefEars,
    required this.prefSkirt,
    this.defaultServices = const [],
    required this.allergies,
    required this.medications,
    required this.medicalIssues,
    required this.vaccinations,
    required this.medicalNotes,
    required this.vet,
    required this.lastVetVisit,
    required this.ownerGrooming,
    required this.generalNotes,
    required this.isActive,
    required this.colour,
    required this.microchipNumber,
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
    this.requiresRestraint,
    this.averageGroomMinutes,
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
        isNeutered: json['is_neutered'] as bool?,
        colour: json['colour']?.toString() ?? '',
        microchipNumber: json['microchip_number']?.toString() ?? '',
        profileImage: json['profile_image']?.toString(),
        groomMinutesOverride: (json['groom_minutes'] as num?)?.toInt(),
        priceOverride: json['price'] == null ? null : _num(json['price']),
        scheduleWeeksOverride: (json['schedule_weeks'] as num?)?.toInt(),
        groomMinutes: (json['groom_minutes_effective'] as num?)?.toInt() ?? 0,
        price: _num(json['price_effective']),
        scheduleWeeks: (json['schedule_weeks_effective'] as num?)?.toInt() ?? 0,
        isAdHoc: json['is_ad_hoc'] == true,
        isDaycare: json['is_daycare'] == true,
        daycareDays: ((json['daycare_days'] as List?) ?? const [])
            .whereType<num>()
            .map((day) => day.toInt())
            .toList(),
        daycareDaysLabel: json['daycare_days_label']?.toString() ?? '',
        prefBody: json['pref_body']?.toString() ?? '',
        prefFeet: json['pref_feet']?.toString() ?? '',
        prefTail: json['pref_tail']?.toString() ?? '',
        prefFace: json['pref_face']?.toString() ?? '',
        prefEars: json['pref_ears']?.toString() ?? '',
        prefSkirt: json['pref_skirt']?.toString() ?? '',
        defaultServices: ((json['default_services'] as List?) ?? const [])
            .map((id) => (id as num).toInt())
            .toList(),
        allergies: json['allergies']?.toString() ?? '',
        medications: json['medications']?.toString() ?? '',
        medicalIssues: json['medical_issues']?.toString() ?? '',
        vaccinations: json['vaccinations']?.toString() ?? '',
        medicalNotes: json['medical_notes']?.toString() ?? '',
        vet: json['vet']?.toString() ?? '',
        lastVetVisit: json['last_vet_visit']?.toString() ?? '',
        ownerGrooming: json['owner_grooming']?.toString() ?? '',
        generalNotes: json['general_notes']?.toString() ?? '',
        isActive: json['is_active'] != false,
        temperament: json['temperament']?.toString(),
        temperamentDisplay: json['temperament_display']?.toString(),
        temperamentNotes: json['temperament_notes']?.toString(),
        // `== true` would turn a withheld field into a confident "no".
        requiresRestraint: json['requires_restraint'] as bool?,
        averageGroomMinutes: (json['average_groom_minutes'] as num?)?.toInt(),
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

  /// The health questions off the paper card, blank ones dropped.
  List<({String label, String value})> get healthNotes => [
        (label: 'Allergies', value: allergies),
        (label: 'Medication', value: medications),
        (label: 'Known medical issues', value: medicalIssues),
        (label: 'Vaccinations', value: vaccinations),
        (label: 'Other', value: medicalNotes),
      ].where((entry) => entry.value.trim().isNotEmpty).toList();

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
  final String serviceType;
  final String status;
  final num? priceQuoted;
  final String notes;

  /// Staff-only.
  final String? dogTemperament;

  /// Jess's own name for that grade. Null for a client login, and null on an
  /// older server — the chip falls back to the seed wording rather than
  /// rendering blank.
  final String? dogTemperamentDisplay;

  /// What is being done. Empty on a booking made before the catalogue, in
  /// which case the length and quote come from the dog as they always did.
  final List<int> serviceIds;

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
    this.serviceType = ServiceType.groom,
    required this.status,
    required this.notes,
    this.priceQuoted,
    this.dogTemperament,
    this.dogTemperamentDisplay,
    this.serviceIds = const [],
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
        serviceType: json['service_type']?.toString() ?? ServiceType.groom,
        status: json['status']?.toString() ?? 'BOOKED',
        priceQuoted: json['price_quoted'] == null ? null : _num(json['price_quoted']),
        notes: json['notes']?.toString() ?? '',
        dogTemperament: json['dog_temperament']?.toString(),
        dogTemperamentDisplay: json['dog_temperament_display']?.toString(),
        serviceIds: ((json['services'] as List?) ?? const [])
            .map((id) => (id as num).toInt())
            .toList(),
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

/// What a visit or booking is for. Matches ServiceType on the server.
class ServiceType {
  static const groom = 'GROOM';
  static const nailsFleasTicks = 'NAILS';

  static String label(String value) =>
      value == nailsFleasTicks ? 'Nails, fleas or ticks' : 'Groom';
}

/// Alias kept for the record cards, which talk about visits rather than
/// bookings. Same two values.
typedef VisitType = ServiceType;

/// One worked visit — Jess's "Ongoing Record" card.
///
/// Covers both of her cards: a full groom carries the lot, a nails/fleas/ticks
/// visit fills in far less. [visitType] says which.
class GroomSession {
  final int id;
  final int dogId;
  final String dogName;
  final String visitType;
  final String visitTypeDisplay;
  final DateTime startedAt;
  final List<PhaseTiming> timings;
  final int totalMinutes;
  final int? recordedMinutes;
  final DateTime? appliedToDogAt;

  /// The booking this visit belongs to, which the server resolves from the
  /// diary when the app doesn't name one — and marks off once it has.
  ///
  /// Null means nothing matched: no booking for this dog today. That is not an
  /// error, it is a groom done without one in the diary.
  final int? appointmentId;
  final DateTime? appointmentStartAt;
  final String appointmentStatus;

  /// The status the booking held before saving this visit closed it, or null
  /// if this save did not change one.
  ///
  /// Non-null is the app's cue to offer an undo. Marking a booking done off
  /// the back of writing a visit up is a fair inference and a poor thing to do
  /// silently — being one tap from reversible is what makes it fair to do
  /// without asking first.
  final String? appointmentStatusBefore;

  /// Whether saving this visit is what closed the booking.
  bool get closedTheBookingNow => appointmentStatusBefore != null;

  /// Whether the booking has been marked off.
  bool get closedTheBooking => appointmentStatus == 'COMPLETED';

  /// What to tell Jess about the booking this visit landed on.
  ///
  /// Her question was *"managed to add the session but wasn't automatically
  /// assigned to the appointment? Unless I'm doing it wrong?"* — she wasn't,
  /// and now that the server matches it, saying so on screen is what makes the
  /// difference visible without opening the diary to check.
  ///
  /// Null when there was nothing to match, which is not a failure: plenty of
  /// grooms happen with nothing in the diary.
  String? get bookingNote {
    if (appointmentId == null) return null;
    final when =
        appointmentStartAt == null ? "the day's booking" : formatTime(appointmentStartAt!);
    return closedTheBooking
        ? 'Marked $when as done in the diary.'
        : 'Filed against $when in the diary.';
  }

  final String healthCheckNotes;
  final bool mattingPaws;
  final bool mattingArmpits;
  final bool mattingEars;
  final bool mattingElsewhere;
  final String mattingNotes;
  final bool mattingFound;

  /// Null means bathing wasn't recorded — not that the dog behaved badly.
  final bool? bathedWellBehaved;
  /// Null means nobody wrote it down — not that the dryer went unused. It was
  /// a plain bool until Jess asked for it "like the bathed", and on a dog that
  /// will not tolerate one, which of the two it was is the point.
  final bool? highVelocityDryer;
  final String shampooUsed;
  final List<Equipment> equipmentUsed;

  /// What was actually done, as opposed to what the owner asked for at intake.
  final String finalBody;
  final String finalFeet;
  final String finalTail;
  final String finalFace;

  final bool nailsDone;
  final bool fleasTreated;
  final bool ticksRemoved;

  final String notes;
  final String sensitiveNotes;
  final String temperamentObserved;
  final String temperamentObservedDisplay;

  const GroomSession({
    required this.id,
    required this.dogId,
    required this.dogName,
    required this.startedAt,
    required this.timings,
    required this.totalMinutes,
    this.visitType = VisitType.groom,
    this.visitTypeDisplay = '',
    this.recordedMinutes,
    this.appliedToDogAt,
    this.appointmentId,
    this.appointmentStartAt,
    this.appointmentStatus = '',
    this.appointmentStatusBefore,
    this.healthCheckNotes = '',
    this.mattingPaws = false,
    this.mattingArmpits = false,
    this.mattingEars = false,
    this.mattingElsewhere = false,
    this.mattingNotes = '',
    this.mattingFound = false,
    this.bathedWellBehaved,
    this.highVelocityDryer,
    this.shampooUsed = '',
    this.equipmentUsed = const [],
    this.finalBody = '',
    this.finalFeet = '',
    this.finalTail = '',
    this.finalFace = '',
    this.nailsDone = false,
    this.fleasTreated = false,
    this.ticksRemoved = false,
    this.notes = '',
    this.sensitiveNotes = '',
    this.temperamentObserved = '',
    this.temperamentObservedDisplay = '',
  });

  factory GroomSession.fromJson(Map<String, dynamic> json) => GroomSession(
        id: json['id'] as int,
        dogId: (json['dog'] as num?)?.toInt() ?? 0,
        dogName: json['dog_name']?.toString() ?? '',
        visitType: json['visit_type']?.toString() ?? VisitType.groom,
        visitTypeDisplay: json['visit_type_display']?.toString() ?? '',
        startedAt: _dateTime(json['started_at']) ?? DateTime.now(),
        timings: ((json['timings'] as List?) ?? const [])
            .map((t) => PhaseTiming.fromJson(t as Map<String, dynamic>))
            .toList(),
        totalMinutes: (json['total_minutes'] as num?)?.toInt() ?? 0,
        recordedMinutes: (json['recorded_minutes'] as num?)?.toInt(),
        appliedToDogAt: _dateTime(json['applied_to_dog_at']),
        appointmentId: (json['appointment'] as num?)?.toInt(),
        appointmentStartAt: _dateTime(json['appointment_start_at']),
        appointmentStatus: json['appointment_status']?.toString() ?? '',
        appointmentStatusBefore: json['appointment_status_before']?.toString(),
        healthCheckNotes: json['health_check_notes']?.toString() ?? '',
        mattingPaws: json['matting_paws'] == true,
        mattingArmpits: json['matting_armpits'] == true,
        mattingEars: json['matting_ears'] == true,
        mattingElsewhere: json['matting_elsewhere'] == true,
        mattingNotes: json['matting_notes']?.toString() ?? '',
        mattingFound: json['matting_found'] == true,
        // Deliberately not coerced: a null means it wasn't recorded.
        bathedWellBehaved:
            json['bathed_well_behaved'] is bool ? json['bathed_well_behaved'] as bool : null,
        highVelocityDryer:
            json['high_velocity_dryer'] is bool ? json['high_velocity_dryer'] as bool : null,
        shampooUsed: json['shampoo_used']?.toString() ?? '',
        equipmentUsed: ((json['equipment_used_detail'] as List?) ?? const [])
            .map((e) => Equipment.fromJson(e as Map<String, dynamic>))
            .toList(),
        finalBody: json['final_body']?.toString() ?? '',
        finalFeet: json['final_feet']?.toString() ?? '',
        finalTail: json['final_tail']?.toString() ?? '',
        finalFace: json['final_face']?.toString() ?? '',
        nailsDone: json['nails_done'] == true,
        fleasTreated: json['fleas_treated'] == true,
        ticksRemoved: json['ticks_removed'] == true,
        notes: json['notes']?.toString() ?? '',
        sensitiveNotes: json['sensitive_notes']?.toString() ?? '',
        temperamentObserved: json['temperament_observed']?.toString() ?? '',
        temperamentObservedDisplay: json['temperament_observed_display']?.toString() ?? '',
      );

  bool get isGroom => visitType == VisitType.groom;

  /// Which of the three a nails visit covered, for a one-line summary.
  String get nailsSummary => [
        if (nailsDone) 'Nails',
        if (fleasTreated) 'Fleas',
        if (ticksRemoved) 'Ticks',
      ].join(' · ');

  /// Where matting was found, in the order the paper card lists it.
  List<String> get mattingPlaces => [
        if (mattingPaws) 'paws',
        if (mattingArmpits) 'armpits',
        if (mattingEars) 'ears',
        if (mattingElsewhere) 'elsewhere',
      ];
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

  /// A nails/fleas/ticks visit takes neither its length nor its price from the
  /// breed grid — that grid prices full grooms, and Jess's price list has
  /// nothing for this at all.
  ///
  /// Null means she hasn't set it yet, which is **not** zero. Show "Not set"
  /// and let her fill it in; never render a null as a price.
  final int? nailVisitMinutes;
  final num? nailVisitPrice;

  /// Gap left either side of a booking when looking for the next free slot.
  ///
  /// Zero by default, so nothing changes until Jess sets one.
  final int bookingSlotBufferMinutes;

  const AppSettings({
    required this.businessName,
    required this.contactPhone,
    required this.contactEmail,
    required this.invoicingVisibleToClients,
    this.nailVisitMinutes,
    this.nailVisitPrice,
    this.bookingSlotBufferMinutes = 0,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        businessName: json['business_name']?.toString() ?? 'Mojo and Co',
        contactPhone: json['contact_phone']?.toString() ?? '',
        contactEmail: json['contact_email']?.toString() ?? '',
        invoicingVisibleToClients: json['invoicing_visible_to_clients'] == true,
        bookingSlotBufferMinutes:
            (json['booking_slot_buffer_minutes'] as num?)?.toInt() ?? 0,
        nailVisitMinutes: (json['nail_visit_minutes'] as num?)?.toInt(),
        // Deliberately not defaulted: a null price is "not set", not free.
        nailVisitPrice:
            json['nail_visit_price'] == null ? null : _num(json['nail_visit_price']),
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

/// A login, as a superuser sees it when choosing who to send a reset link to.
class AccountSummary {
  final int id;
  final String username;
  final String email;
  final String fullName;
  final bool isStaff;
  final bool isSuperuser;
  final bool isActive;
  final DateTime? lastLogin;

  /// The client record this login is attached to, when there is one. Jess
  /// looks people up by who they are, not by what they typed at sign-up, so a
  /// list without this is unmatchable against her clients.
  final String? clientName;
  final String? clientUid;

  const AccountSummary({
    required this.id,
    required this.username,
    required this.email,
    required this.fullName,
    required this.isStaff,
    required this.isSuperuser,
    required this.isActive,
    this.lastLogin,
    this.clientName,
    this.clientUid,
  });

  factory AccountSummary.fromJson(Map<String, dynamic> json) => AccountSummary(
        id: json['id'] as int,
        username: json['username']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        fullName: json['full_name']?.toString() ?? '',
        isStaff: json['is_staff'] == true,
        isSuperuser: json['is_superuser'] == true,
        isActive: json['is_active'] != false,
        lastLogin: DateTime.tryParse(json['last_login']?.toString() ?? ''),
        clientName: json['client_name']?.toString(),
        clientUid: json['client_uid']?.toString(),
      );

  /// What to show under the username: the client they are, falling back to
  /// their own name, then their email.
  String get subtitle {
    if (clientName != null && clientName!.isNotEmpty) {
      return clientUid == null || clientUid!.isEmpty ? clientName! : '$clientName · $clientUid';
    }
    if (fullName.isNotEmpty) return fullName;
    return email.isEmpty ? 'No email on file' : email;
  }
}

/// A reset link that has just been issued.
///
/// [link] is carried once, in the response that created it, and never appears
/// in the history list — so this is the only chance to hand it over.
class IssuedResetLink {
  final String link;
  final String email;
  final bool emailed;
  final bool emailConfigured;
  final String? emailError;
  final DateTime? expiresAt;

  const IssuedResetLink({
    required this.link,
    required this.email,
    required this.emailed,
    required this.emailConfigured,
    this.emailError,
    this.expiresAt,
  });

  factory IssuedResetLink.fromJson(Map<String, dynamic> json) => IssuedResetLink(
        link: json['link']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        emailed: json['emailed'] == true,
        emailConfigured: json['email_configured'] == true,
        emailError: json['email_error']?.toString(),
        expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
      );
}

/// Someone locked out, asking for a way back in.
class PasswordHelpRequest {
  final int id;

  /// What they typed. Kept even when it matched nothing — someone typing the
  /// wrong thing is exactly who needs help, and Jess can usually tell who they
  /// meant from it.
  final String identifier;
  final String note;
  final String? username;
  final String? clientName;
  final String status;
  final DateTime? createdAt;

  const PasswordHelpRequest({
    required this.id,
    required this.identifier,
    required this.note,
    required this.status,
    this.username,
    this.clientName,
    this.createdAt,
  });

  factory PasswordHelpRequest.fromJson(Map<String, dynamic> json) => PasswordHelpRequest(
        id: json['id'] as int,
        identifier: json['identifier']?.toString() ?? '',
        note: json['note']?.toString() ?? '',
        username: json['username']?.toString(),
        clientName: json['client_name']?.toString(),
        status: json['status']?.toString() ?? 'PENDING',
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      );

  /// Whether the server could work out which account they meant. When it
  /// couldn't, there is nothing to issue a link against and Jess has to
  /// identify them herself.
  bool get isMatched => username != null && username!.isNotEmpty;
}
