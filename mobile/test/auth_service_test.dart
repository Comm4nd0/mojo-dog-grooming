import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/biometric_service.dart';

/// A biometric sensor that does what the test tells it to.
///
/// The real one is a platform prompt, so nothing about the lock could be
/// tested through it — and the lock is the part where a mistake means either
/// records shown to whoever picked up the phone, or an account nobody can
/// reach again.
class _FakeBiometrics implements BiometricAuthenticator {
  _FakeBiometrics({this.available = true, this.willPass = true});

  bool available;
  bool willPass;
  int prompts = 0;

  @override
  Future<BiometricCapability> capability() async => available
      ? const BiometricCapability(available: true, label: 'Face ID')
      : const BiometricCapability.none();

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return willPass;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> stored;
  late int meCalls;

  /// Stands in for the Keychain / EncryptedSharedPreferences.
  void installStorage() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final arguments = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'read':
          return stored[arguments['key']];
        case 'write':
          stored[arguments['key'] as String] = arguments['value'] as String;
          return null;
        case 'delete':
          stored.remove(arguments['key']);
          return null;
        case 'deleteAll':
          stored.clear();
          return null;
        case 'readAll':
          return stored;
        case 'containsKey':
          return stored.containsKey(arguments['key']);
      }
      return null;
    });
  }

  ApiClient buildApi() {
    return ApiClient(
      baseUrl: 'https://example.test/api',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/auth/users/me/')) {
          meCalls++;
          return http.Response(
            jsonEncode({
              'id': 7,
              'username': 'jess',
              'email': 'jess@example.com',
              'is_staff': true,
              'is_superuser': true,
              'client_id': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/auth/token/login/')) {
          return http.Response(
            jsonEncode({'auth_token': 'fresh-token'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/password-reset-requests/')) {
          return http.Response(
            jsonEncode({'detail': 'Thanks — Mojo and Co will be in touch.'}),
            202,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      }),
    );
  }

  void seedAccount({required bool biometrics, String username = 'jess'}) {
    stored['mojo_accounts'] = jsonEncode({
      'active': username,
      'accounts': [
        {
          'username': username,
          'token': 'saved-token',
          'is_staff': true,
          'biometrics': biometrics,
        }
      ],
    });
  }

  setUp(() {
    stored = <String, String>{};
    meCalls = 0;
    installStorage();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('biometric lock', () {
    test('a session with biometrics on comes back locked, and fetches nothing', () async {
      seedAccount(biometrics: true);
      final auth = AuthService(buildApi(), biometrics: _FakeBiometrics());

      await auth.restore();

      expect(auth.isLocked, isTrue);
      expect(
        meCalls,
        0,
        reason: 'records must not be fetched before the check passes',
      );
      // The username is known from what this device stored, so the lock screen
      // can say whose session it is without calling the API.
      expect(auth.user?.username, 'jess');
    });

    test('a session without biometrics comes back unlocked', () async {
      seedAccount(biometrics: false);
      final auth = AuthService(buildApi(), biometrics: _FakeBiometrics());

      await auth.restore();

      expect(auth.isLocked, isFalse);
      expect(auth.isSignedIn, isTrue);
      expect(meCalls, 1);
    });

    test('passing the check clears the lock and loads the real user', () async {
      seedAccount(biometrics: true);
      final biometrics = _FakeBiometrics();
      final auth = AuthService(buildApi(), biometrics: biometrics);
      await auth.restore();

      expect(await auth.unlock(), isTrue);

      expect(auth.isLocked, isFalse);
      expect(biometrics.prompts, 1);
      expect(meCalls, 1);
      expect(auth.isSuperuser, isTrue);
    });

    test('failing the check leaves it locked', () async {
      seedAccount(biometrics: true);
      final auth = AuthService(buildApi(), biometrics: _FakeBiometrics(willPass: false));
      await auth.restore();

      expect(await auth.unlock(), isFalse);

      expect(auth.isLocked, isTrue);
      expect(meCalls, 0);
    });

    test('unlocking does not switch the lock off for next time', () async {
      // Regression: every successful /users/me rebuilds the stored account
      // entry, which used to drop the biometric flag — so the lock worked
      // exactly once and then silently stopped.
      seedAccount(biometrics: true);
      final auth = AuthService(buildApi(), biometrics: _FakeBiometrics());
      await auth.restore();
      await auth.unlock();

      expect(auth.biometricsEnabledHere, isTrue);
      expect(
        jsonDecode(stored['mojo_accounts']!)['accounts'][0]['biometrics'],
        isTrue,
      );
    });

    test('switching to a locked account prompts, and refusing does not switch', () async {
      seedAccount(biometrics: false, username: 'jess');
      final biometrics = _FakeBiometrics(willPass: false);
      final auth = AuthService(buildApi(), biometrics: biometrics);
      await auth.restore();

      const other = SavedAccount(
        username: 'alice',
        token: 'alice-token',
        isStaff: false,
        biometricsEnabled: true,
      );

      await expectLater(auth.switchTo(other), throwsA(isA<ApiException>()));
      expect(biometrics.prompts, 1);
      expect(auth.user?.username, 'jess', reason: 'the session must not have moved');
    });
  });

  group('turning biometrics on', () {
    test('it prompts first and then persists', () async {
      seedAccount(biometrics: false);
      final biometrics = _FakeBiometrics();
      final auth = AuthService(buildApi(), biometrics: biometrics);
      await auth.restore();

      expect(await auth.setBiometricsEnabled(true), isTrue);

      expect(biometrics.prompts, 1);
      expect(auth.biometricsEnabledHere, isTrue);
      expect(jsonDecode(stored['mojo_accounts']!)['accounts'][0]['biometrics'], isTrue);
    });

    test('a refused prompt changes nothing', () async {
      // Otherwise the account is locked behind a check that never passes, and
      // the only way out is signing out and typing a password.
      seedAccount(biometrics: false);
      final auth = AuthService(buildApi(), biometrics: _FakeBiometrics(willPass: false));
      await auth.restore();

      expect(await auth.setBiometricsEnabled(true), isFalse);
      expect(auth.biometricsEnabledHere, isFalse);
    });

    test('hardware with nothing enrolled cannot turn it on', () async {
      seedAccount(biometrics: false);
      final biometrics = _FakeBiometrics(available: false);
      final auth = AuthService(buildApi(), biometrics: biometrics);
      await auth.restore();

      expect(await auth.setBiometricsEnabled(true), isFalse);
      expect(biometrics.prompts, 0, reason: 'nothing to prompt with');
      expect(auth.biometricsEnabledHere, isFalse);
    });

    test('turning it off needs no prompt', () async {
      seedAccount(biometrics: true);
      final biometrics = _FakeBiometrics();
      final auth = AuthService(buildApi(), biometrics: biometrics);
      await auth.restore();
      await auth.unlock();
      biometrics.prompts = 0;

      expect(await auth.setBiometricsEnabled(false), isTrue);
      expect(biometrics.prompts, 0);
      expect(auth.biometricsEnabledHere, isFalse);
    });
  });

  group('signing in', () {
    test('a fresh sign-in is never locked', () async {
      final auth = AuthService(buildApi(), biometrics: _FakeBiometrics());

      await auth.signIn('jess', 'a-password');

      expect(auth.isLocked, isFalse);
      expect(auth.isSignedIn, isTrue);
    });

    test('asking for password help returns what the server said', () async {
      final auth = AuthService(buildApi(), biometrics: _FakeBiometrics());

      final message = await auth.requestPasswordHelp(identifier: 'alice');

      expect(message, contains('in touch'));
      // Deliberately not "we found your account" — the server answers the same
      // whether or not it matched, and the app must not imply more.
      expect(message.toLowerCase(), isNot(contains('alice')));
    });
  });

  group('SavedAccount', () {
    test('the biometric flag survives a storage round trip', () {
      const account = SavedAccount(
        username: 'jess',
        token: 'tok',
        isStaff: true,
        biometricsEnabled: true,
      );
      final restored = SavedAccount.fromJson(jsonDecode(jsonEncode(account.toJson())));
      expect(restored.biometricsEnabled, isTrue);
      expect(restored.username, 'jess');
    });

    test('an entry written before this feature reads as off, not null', () {
      final restored = SavedAccount.fromJson({
        'username': 'jess',
        'token': 'tok',
        'is_staff': true,
      });
      expect(restored.biometricsEnabled, isFalse);
    });
  });
}
