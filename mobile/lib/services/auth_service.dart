import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';
import 'api_client.dart';

/// An account remembered on this device.
///
/// Jess tests the client side against real client logins, so the app keeps
/// several signed-in accounts and swaps the active token rather than making
/// her retype a password every time she wants to see the other half of the app.
class SavedAccount {
  final String username;
  final String token;
  final bool isStaff;

  const SavedAccount({
    required this.username,
    required this.token,
    required this.isStaff,
  });

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
        username: json['username']?.toString() ?? '',
        token: json['token']?.toString() ?? '',
        isStaff: json['is_staff'] == true,
      );

  Map<String, dynamic> toJson() => {
        'username': username,
        'token': token,
        'is_staff': isStaff,
      };
}

/// Login state and the token lifecycle.
///
/// Tokens live in secure storage (Keychain / EncryptedSharedPreferences),
/// never in plain preferences — each one grants full access to its account.
class AuthService extends ChangeNotifier {
  AuthService(this._api, {FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Pre-multi-account storage slot: a single bare token. Read once on the
  /// first launch after upgrading, then deleted.
  static const _tokenKey = 'mojo_auth_token';
  static const _accountsKey = 'mojo_accounts';

  final ApiClient _api;
  final FlutterSecureStorage _storage;

  CurrentUser? _user;
  bool _restoring = true;
  List<SavedAccount> _accounts = const [];
  String? _activeUsername;

  CurrentUser? get user => _user;
  bool get isSignedIn => _user != null;
  bool get isStaff => _user?.isStaff ?? false;
  bool get isRestoring => _restoring;

  /// Accounts remembered on this device, current one included.
  ///
  /// A copy rather than the live list: callers sort and filter these for
  /// display, and an unmodifiable view would throw the moment they did.
  List<SavedAccount> get accounts => List.of(_accounts);

  /// Reload a saved session at startup so Jess isn't asked to log in daily.
  Future<void> restore() async {
    _restoring = true;
    try {
      await _loadAccounts();
      final active = _activeAccount;
      if (active == null) return;
      _api.setToken(active.token);
      _user = await _fetchMe();
      await _rememberActive(active.token);
    } on ApiException catch (error) {
      // A rejected token is stale — clear it rather than looping on 401s.
      if (error.isUnauthorised) await _clearActive();
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
    _api.setToken(token);
    _user = await _fetchMe();
    await _rememberActive(token);
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

  /// Swap to another remembered account.
  ///
  /// The app root listens to this service, so the matching shell swaps itself
  /// in — a staff account lands on the diary, a client one on their bookings.
  Future<void> switchTo(SavedAccount account) async {
    if (account.token == _api.token) return;
    final previousToken = _api.token;
    final previousUser = _user;

    _api.setToken(account.token);
    try {
      _user = await _fetchMe();
    } catch (error) {
      // Roll back rather than strand the user signed out of everything.
      _api.setToken(previousToken);
      _user = previousUser;
      // A remembered token can be revoked from elsewhere — signing out on
      // another device, or the account being deleted. Drop the entry instead
      // of keeping one that will fail identically every time.
      if (error is ApiException && error.isUnauthorised) {
        await _forget(account.username);
        notifyListeners();
      }
      rethrow;
    }
    await _rememberActive(account.token);
    notifyListeners();
  }

  /// Forget an account without disturbing the current session.
  ///
  /// Local only — this device stops holding the token, but the server keeps
  /// honouring it until that account signs out itself. Signing out of the
  /// active account (below) does revoke it.
  Future<void> removeAccount(SavedAccount account) async {
    if (account.username == _user?.username) return signOut();
    await _forget(account.username);
    notifyListeners();
  }

  Future<void> signOut() async {
    try {
      await _api.post('/auth/token/logout/');
    } catch (_) {
      // Best effort — the local token is cleared regardless.
    }
    await _clearActive();
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

  SavedAccount? get _activeAccount {
    for (final account in _accounts) {
      if (account.username == _activeUsername) return account;
    }
    return _accounts.isEmpty ? null : _accounts.first;
  }

  Future<void> _loadAccounts() async {
    final raw = await _storage.read(key: _accountsKey);
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _accounts = ((decoded['accounts'] as List?) ?? const [])
          .map((entry) => SavedAccount.fromJson(entry as Map<String, dynamic>))
          .where((account) => account.token.isNotEmpty)
          .toList();
      _activeUsername = decoded['active']?.toString();
      return;
    }
    // First launch after the upgrade: adopt the old single token so the
    // existing session survives. The username isn't known until /users/me
    // answers, so it stays blank until _rememberActive fills it in.
    final legacy = await _storage.read(key: _tokenKey);
    if (legacy != null && legacy.isNotEmpty) {
      _accounts = [SavedAccount(username: '', token: legacy, isStaff: false)];
      _activeUsername = '';
    }
  }

  /// Record the signed-in user against its token, and make it the active one.
  ///
  /// Called after every successful `/users/me`, so the stored username and
  /// staff flag can't drift from what the server actually says.
  Future<void> _rememberActive(String token) async {
    final user = _user;
    if (user == null) return;
    _accounts = [
      // Drop any entry for this username, and the blank-username placeholder
      // the legacy migration leaves behind holding this same token.
      for (final account in _accounts)
        if (account.username != user.username && account.token != token) account,
      SavedAccount(username: user.username, token: token, isStaff: user.isStaff),
    ];
    _activeUsername = user.username;
    await _storage.delete(key: _tokenKey);
    await _persist();
  }

  /// Drop the active session, leaving the other remembered accounts alone.
  Future<void> _clearActive() async {
    final username = _user?.username ?? _activeUsername;
    if (username != null) {
      _accounts = [
        for (final account in _accounts)
          if (account.username != username) account,
      ];
    }
    _activeUsername = null;
    _api.setToken(null);
    _user = null;
    await _storage.delete(key: _tokenKey);
    await _persist();
  }

  Future<void> _forget(String username) async {
    _accounts = [
      for (final account in _accounts)
        if (account.username != username) account,
    ];
    await _persist();
  }

  Future<void> _persist() async {
    await _storage.write(
      key: _accountsKey,
      value: jsonEncode({
        'active': _activeUsername,
        'accounts': [for (final account in _accounts) account.toJson()],
      }),
    );
  }
}
