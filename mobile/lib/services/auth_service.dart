import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';
import 'api_client.dart';
import 'biometric_service.dart';

/// An account remembered on this device.
///
/// Jess tests the client side against real client logins, so the app keeps
/// several signed-in accounts and swaps the active token rather than making
/// her retype a password every time she wants to see the other half of the app.
class SavedAccount {
  final String username;
  final String token;
  final bool isStaff;

  /// Whether this account asked for a fingerprint or face check before its
  /// records are shown. Per account, not per device: Jess can lock her staff
  /// login behind Face ID while the test client login she flips into all day
  /// stays open.
  final bool biometricsEnabled;

  const SavedAccount({
    required this.username,
    required this.token,
    required this.isStaff,
    this.biometricsEnabled = false,
  });

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
        username: json['username']?.toString() ?? '',
        token: json['token']?.toString() ?? '',
        isStaff: json['is_staff'] == true,
        biometricsEnabled: json['biometrics'] == true,
      );

  Map<String, dynamic> toJson() => {
        'username': username,
        'token': token,
        'is_staff': isStaff,
        'biometrics': biometricsEnabled,
      };

  SavedAccount copyWith({bool? biometricsEnabled}) => SavedAccount(
        username: username,
        token: token,
        isStaff: isStaff,
        biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
      );
}

/// Login state and the token lifecycle.
///
/// Tokens live in secure storage (Keychain / EncryptedSharedPreferences),
/// never in plain preferences — each one grants full access to its account.
class AuthService extends ChangeNotifier {
  AuthService(this._api, {FlutterSecureStorage? storage, BiometricAuthenticator? biometrics})
      : _storage = storage ?? const FlutterSecureStorage(),
        _biometrics = biometrics ?? LocalAuthBiometricAuthenticator();

  /// Pre-multi-account storage slot: a single bare token. Read once on the
  /// first launch after upgrading, then deleted.
  static const _tokenKey = 'mojo_auth_token';
  static const _accountsKey = 'mojo_accounts';

  final ApiClient _api;
  final FlutterSecureStorage _storage;
  final BiometricAuthenticator _biometrics;

  CurrentUser? _user;
  bool _restoring = true;
  bool _locked = false;
  List<SavedAccount> _accounts = const [];
  String? _activeUsername;

  CurrentUser? get user => _user;
  bool get isSignedIn => _user != null;
  bool get isStaff => _user?.isStaff ?? false;
  bool get isSuperuser => _user?.isSuperuser ?? false;
  bool get isRestoring => _restoring;

  /// A session was restored but is waiting on a fingerprint or face.
  ///
  /// Separate from [isSignedIn] on purpose: the token is valid and the user
  /// is known, they simply haven't proved they are the one holding the phone,
  /// so the app root shows a lock screen rather than the login form. Sending
  /// them back to the login form would ask for a password they enabled
  /// biometrics precisely to stop typing.
  bool get isLocked => _locked;

  /// Accounts remembered on this device, current one included.
  ///
  /// A copy rather than the live list: callers sort and filter these for
  /// display, and an unmodifiable view would throw the moment they did.
  List<SavedAccount> get accounts => List.of(_accounts);

  SavedAccount? get activeAccount => _activeAccount;

  Future<BiometricCapability> biometricCapability() => _biometrics.capability();

  /// Reload a saved session at startup so Jess isn't asked to log in daily.
  Future<void> restore() async {
    _restoring = true;
    try {
      await _loadAccounts();
      final active = _activeAccount;
      if (active == null) return;
      // Lock before the network call, not after: an account that asked for a
      // biometric check must not have its records fetched — never mind shown —
      // on the strength of holding the phone.
      _locked = active.biometricsEnabled;
      _api.setToken(active.token);
      if (_locked) {
        _user = await _restoreLockedUser(active);
        return;
      }
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

  /// Enough of an identity to draw the lock screen, without calling the API.
  ///
  /// Built from what this device already stored rather than from `/users/me`,
  /// so nothing is fetched until the lock is cleared.
  Future<CurrentUser> _restoreLockedUser(SavedAccount account) async => CurrentUser(
        id: 0,
        username: account.username,
        email: '',
        isStaff: account.isStaff,
      );

  /// Clear a biometric lock. Returns false if the check was cancelled or failed.
  Future<bool> unlock() async {
    if (!_locked) return true;
    final account = _activeAccount;
    if (account == null) return false;

    final passed = await _biometrics.authenticate('Unlock Mojo and Co');
    if (!passed) return false;

    _locked = false;
    try {
      // The stored identity was a placeholder; this is the first real call of
      // the session and also the point a revoked token is found out about.
      _user = await _fetchMe();
      await _rememberActive(account.token);
    } on ApiException catch (error) {
      if (error.isUnauthorised) {
        await _clearActive();
        notifyListeners();
        return false;
      }
      rethrow;
    }
    notifyListeners();
    return true;
  }

  /// Turn the fingerprint or face check on or off for the current account.
  ///
  /// Turning it on prompts first: an unenrolled or misbehaving sensor would
  /// otherwise lock the account behind a check that can never pass, and the
  /// only way out would be signing out and typing a password.
  Future<bool> setBiometricsEnabled(bool enabled) async {
    final account = _activeAccount;
    if (account == null) return false;

    if (enabled) {
      final capability = await _biometrics.capability();
      if (!capability.available) return false;
      final passed = await _biometrics.authenticate(
        'Confirm it\'s you, to use ${capability.label} for Mojo and Co',
      );
      if (!passed) return false;
    }

    _accounts = [
      for (final entry in _accounts)
        if (entry.username == account.username)
          entry.copyWith(biometricsEnabled: enabled)
        else
          entry,
    ];
    await _persist();
    notifyListeners();
    return true;
  }

  bool get biometricsEnabledHere => _activeAccount?.biometricsEnabled ?? false;

  Future<void> signIn(String username, String password) async {
    final response = await _api.post('/auth/token/login/', {
      'username': username.trim(),
      'password': password,
    });
    final token = (response as Map<String, dynamic>)['auth_token']?.toString();
    if (token == null || token.isEmpty) {
      throw const ApiException(500, 'The server did not return a sign-in token.');
    }
    _locked = false;
    _api.setToken(token);
    _user = await _fetchMe();
    await _rememberActive(token);
    notifyListeners();
  }

  Future<void> register({
    required String username,
    required String email,
    required String password,
    String firstName = '',
    String lastName = '',
  }) async {
    await _api.post('/auth/users/', {
      'username': username.trim(),
      'email': email.trim(),
      'password': password,
      if (firstName.trim().isNotEmpty) 'first_name': firstName.trim(),
      if (lastName.trim().isNotEmpty) 'last_name': lastName.trim(),
    });
    await signIn(username, password);
  }

  /// Ask Mojo and Co for a way back in, from the login screen.
  ///
  /// Not a reset — the server records the request for Jess, who checks it is
  /// really them and sends a link. The reply is the same whether or not the
  /// name matched anything, so nothing here can be used to find out who has
  /// an account, and the app must not pretend otherwise in what it shows.
  Future<String> requestPasswordHelp({required String identifier, String note = ''}) async {
    final payload = await _api.post('/password-reset-requests/', {
      'identifier': identifier.trim(),
      'note': note.trim(),
    });
    return (payload is Map<String, dynamic> ? payload['detail']?.toString() : null) ??
        'Thanks — Mojo and Co will be in touch.';
  }

  /// Swap to another remembered account.
  ///
  /// The app root listens to this service, so the matching shell swaps itself
  /// in — a staff account lands on the diary, a client one on their bookings.
  Future<void> switchTo(SavedAccount account) async {
    if (account.token == _api.token) return;
    // An account behind a biometric check stays behind it however it is
    // reached — otherwise the switcher is a way straight past the lock.
    if (account.biometricsEnabled) {
      final passed = await _biometrics.authenticate('Unlock ${account.username}');
      if (!passed) throw const ApiException(401, 'Unlock cancelled.');
    }

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
    // Carry the biometric preference across. This runs after every successful
    // /users/me — including the one right after unlocking — so rebuilding the
    // entry without it would switch the lock off the moment it was used.
    final wasEnabled = _accounts
        .any((account) => account.username == user.username && account.biometricsEnabled);
    _accounts = [
      // Drop any entry for this username, and the blank-username placeholder
      // the legacy migration leaves behind holding this same token.
      for (final account in _accounts)
        if (account.username != user.username && account.token != token) account,
      SavedAccount(
        username: user.username,
        token: token,
        isStaff: user.isStaff,
        biometricsEnabled: wasEnabled,
      ),
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
    _locked = false;
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
