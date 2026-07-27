import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';
import 'api_client.dart';

/// Login state and the token lifecycle.
///
/// The token lives in secure storage (Keychain / EncryptedSharedPreferences),
/// never in plain preferences — it grants full access to the account.
class AuthService extends ChangeNotifier {
  AuthService(this._api, {FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'mojo_auth_token';

  final ApiClient _api;
  final FlutterSecureStorage _storage;

  CurrentUser? _user;
  bool _restoring = true;

  CurrentUser? get user => _user;
  bool get isSignedIn => _user != null;
  bool get isStaff => _user?.isStaff ?? false;
  bool get isRestoring => _restoring;

  /// Reload a saved session at startup so Jess isn't asked to log in daily.
  Future<void> restore() async {
    _restoring = true;
    try {
      final token = await _storage.read(key: _tokenKey);
      if (token == null || token.isEmpty) return;
      _api.setToken(token);
      _user = await _fetchMe();
    } on ApiException catch (error) {
      // A rejected token is stale — clear it rather than looping on 401s.
      if (error.isUnauthorised) await _clear();
    } on NoConnectionException {
      // Offline at startup: keep the token, let the user retry.
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  Future<void> signIn(String username, String password) async {
    final response = await _api.post('/auth/token/login/', {
      'username': username.trim(),
      'password': password,
    });
    final token = (response as Map<String, dynamic>)['auth_token']?.toString();
    if (token == null || token.isEmpty) {
      throw const ApiException(500, 'The server did not return a sign-in token.');
    }
    await _storage.write(key: _tokenKey, value: token);
    _api.setToken(token);
    _user = await _fetchMe();
    notifyListeners();
  }

  Future<void> register({
    required String username,
    required String email,
    required String password,
  }) async {
    await _api.post('/auth/users/', {
      'username': username.trim(),
      'email': email.trim(),
      'password': password,
    });
    await signIn(username, password);
  }

  Future<void> signOut() async {
    try {
      await _api.post('/auth/token/logout/');
    } catch (_) {
      // Best effort — the local token is cleared regardless.
    }
    await _clear();
    notifyListeners();
  }

  /// Re-read the current user, e.g. after a profile claim is approved.
  Future<void> refreshUser() async {
    if (_api.token == null) return;
    _user = await _fetchMe();
    notifyListeners();
  }

  Future<CurrentUser> _fetchMe() async {
    final payload = await _api.get('/auth/users/me/');
    return CurrentUser.fromJson(payload as Map<String, dynamic>);
  }

  Future<void> _clear() async {
    await _storage.delete(key: _tokenKey);
    _api.setToken(null);
    _user = null;
  }
}
