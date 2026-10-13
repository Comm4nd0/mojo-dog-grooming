import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted, account-specific Doguments snapshot and durable upload queue.
/// No client account is ever given a staff snapshot. Network/authentication
/// errors are handled by DataService; storage failure must never mean saved.
class OfflineStore extends ChangeNotifier {
  OfflineStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  String? _key;
  int generation = 0;
  Map<String, dynamic> _snapshot = {};
  Map<String, dynamic> _reads = {};
  List<Map<String, dynamic>> _pending = [];
  Future<void> _writes = Future.value();
  bool isOffline = false;
  bool syncing = false;
  String? syncError;

  bool get enabled => _key != null;
  DateTime? get savedAt =>
      DateTime.tryParse(_snapshot['saved_at']?.toString() ?? '');
  List<Map<String, dynamic>> get pending =>
      _pending.map((e) => Map<String, dynamic>.from(e)).toList();
  int get pendingCount => _pending.length;

  static String accountKey(String baseUrl, String username) =>
      base64UrlEncode(utf8.encode('$baseUrl\n$username'));

  Future<void> activate(String? scope) async {
    final next = scope == null ? null : 'mojo_offline_$scope';
    if (next == _key) return;
    final epoch = ++generation;
    _key = next;
    _snapshot = {};
    _reads = {};
    _pending = [];
    isOffline = false;
    syncing = false;
    syncError = null;
    notifyListeners();
    await _writes.catchError((Object _) {});
    if (next == null) return;
    final raw = await _storage.read(key: next);
    if (epoch != generation || raw == null) return;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    _snapshot = Map<String, dynamic>.from(data['snapshot'] as Map? ?? {});
    _reads = Map<String, dynamic>.from(data['reads'] as Map? ?? {});
    _pending = (data['pending'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    notifyListeners();
  }

  void status({bool? offline, bool? busy, String? error}) {
    if (offline != null) isOffline = offline;
    if (busy != null) syncing = busy;
    syncError = error;
    notifyListeners();
  }

  Future<void> saveSnapshot(Map<String, dynamic> snapshot) async {
    final epoch = generation;
    final previous = _snapshot;
    final previousReads = _reads;
    _snapshot = snapshot;
    _reads = {}; // Fresh complete snapshot replaces individually cached rows.
    try {
      await _persist();
    } catch (_) {
      if (epoch == generation) {
        _snapshot = previous;
        _reads = previousReads;
      }
      rethrow;
    }
    notifyListeners();
  }

  String _readKey(String path, Map<String, dynamic>? query) {
    final pairs =
        (query ?? {}).entries
            .where((e) => e.value != null)
            .map((e) => '${e.key}=${e.value}')
            .toList()
          ..sort();
    return '$path?${pairs.join('&')}';
  }

  Future<void> remember(
    String path,
    Map<String, dynamic>? query,
    dynamic data,
  ) async {
    if (!enabled) return;
    _reads[_readKey(path, query)] = data;
    await _persist();
  }

  dynamic read(String path, Map<String, dynamic>? query) {
    if (!enabled) return null;
    final exact = _reads[_readKey(path, query)];
    if (exact != null) return exact;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final kind = segments.first;
    if (kind == 'settings') return _snapshot['settings'];
    final table = switch (kind) {
      'dogs' => segments.length == 2 ? 'profiles' : 'dogs',
      'clients' => 'clients',
      'breeds' => 'breeds',
      'groom-sessions' => 'visits',
      'dog-photos' => 'photos',
      'dog-documents' => 'documents',
      'temperament-grades' => 'grades',
      'equipment' => 'equipment',
      _ => null,
    };
    if (table == null || !_snapshot.containsKey(table) || segments.length > 2) {
      return null;
    }
    var rows = (_snapshot[table] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (segments.length == 2) {
      final id = int.tryParse(segments[1]);
      if (id == null) return null;
      for (final row in rows) {
        if (row['id'] == id) return row;
      }
      return null;
    }
    final q = query ?? {};
    if (kind == 'dogs' && q['include_inactive'] != '1') {
      rows = rows.where((r) => r['is_active'] != false).toList();
    }
    for (final field in ['dog', 'client', 'visit_type']) {
      if (q[field] != null) {
        rows = rows.where((r) => '${r[field]}' == '${q[field]}').toList();
      }
    }
    if (q['unassigned'] == '1') {
      rows = rows.where((r) => r['dog'] == null).toList();
    }
    final search = q['search']?.toString().trim().toLowerCase() ?? '';
    if (search.isNotEmpty) {
      rows = rows
          .where(
            (r) =>
                [
                  'name',
                  'client_first_name',
                  'client_full_name',
                  'client_phone',
                  'client_uid',
                  'first_name',
                  'last_name',
                  'uid',
                  'phone',
                  'email',
                ].any(
                  (field) => '${r[field] ?? ''}'.toLowerCase().contains(search),
                ),
          )
          .toList();
    }
    return rows;
  }

  Future<void> enqueue(Map<String, dynamic> body, String dogName) async {
    if (!enabled) throw StateError('Sign in to keep a groom on this device.');
    final ref = body['client_reference'];
    final epoch = generation;
    if (_pending.any((e) => e['body']['client_reference'] == ref)) return;
    _pending.add({'body': body, 'dog_name': dogName});
    try {
      await _persist();
    } catch (_) {
      if (epoch == generation) {
        _pending.removeWhere((e) => e['body']['client_reference'] == ref);
      }
      rethrow;
    }
    notifyListeners();
  }

  Future<void> remove(String reference) async {
    final epoch = generation;
    final previous = _pending;
    _pending = _pending
        .where((e) => e['body']['client_reference'] != reference)
        .toList();
    try {
      await _persist();
    } catch (_) {
      if (epoch == generation) _pending = previous;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> reject(String reference, String message) async {
    for (final entry in _pending) {
      if (entry['body']['client_reference'] == reference) {
        entry['error'] = message;
      }
    }
    await _persist();
    notifyListeners();
  }

  Future<void> revise(
    String reference,
    Map<String, dynamic> changes, {
    String? dogName,
  }) async {
    if (syncing) throw StateError('Wait for the current upload to finish.');
    final entry = _pending.firstWhere(
      (e) => e['body']['client_reference'] == reference,
    );
    // Only a definite validation rejection permits changing the payload.
    // A lost response may already have committed and must replay unchanged.
    if (entry['error'] == null) {
      throw StateError('Connect and check this upload before editing it.');
    }
    final previous = Map<String, dynamic>.from(entry);
    entry['body'] = {
      ...Map<String, dynamic>.from(entry['body'] as Map),
      ...changes,
      'client_reference': reference,
    };
    if (dogName != null) entry['dog_name'] = dogName;
    entry.remove('error');
    try {
      await _persist();
    } catch (_) {
      entry
        ..clear()
        ..addAll(previous);
      rethrow;
    }
    notifyListeners();
  }

  Future<void> _persist() {
    final key = _key;
    if (key == null) return Future.value();
    final raw = jsonEncode({
      'snapshot': _snapshot,
      'reads': _reads,
      'pending': _pending,
    });
    final write = _writes
        .catchError((Object _) {})
        .then((_) => _storage.write(key: key, value: raw));
    _writes = write;
    return write;
  }
}

/// UUID v4 without an extra dependency. Kept with the draft before upload.
String newGroomReference() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
