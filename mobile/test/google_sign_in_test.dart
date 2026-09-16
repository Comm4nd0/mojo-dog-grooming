import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/screens/login_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/biometric_service.dart';
import 'package:mojo_app/services/google_sign_in_service.dart';
import 'package:mojo_app/services/service_locator.dart';
import 'package:mojo_app/widgets/google_connect_tile.dart';

/// Sign in with Google, on the app's side.
///
/// Google's own picker is a platform sheet, so it is stood in for; what is
/// tested is everything the app does around it — whether the button shows at
/// all, what it sends, and that what the server refuses is shown in the
/// server's own words.
class _FakeGoogle implements GoogleIdTokenSource {
  _FakeGoogle({this.supported = true, this.token = 'google-id-token', this.failure});

  bool supported;
  String? token;
  GoogleSignInFailure? failure;
  final List<String> askedFor = [];

  @override
  bool get platformSupported => supported;

  @override
  Future<String?> idToken({required String serverClientId}) async {
    askedFor.add(serverClientId);
    if (failure != null) throw failure!;
    return token;
  }
}

class _NoBiometrics implements BiometricAuthenticator {
  @override
  Future<BiometricCapability> capability() async => const BiometricCapability.none();

  @override
  Future<bool> authenticate(String reason) async => false;
}

const _json = {'content-type': 'application/json'};
const _webClient = 'web-123.apps.googleusercontent.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late List<http.Request> requests;
  late bool googleOn;
  late http.Response Function() googleAnswer;
  late Map<String, dynamic> me;

  ApiClient buildApi() => ApiClient(
        baseUrl: 'https://example.test/api',
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/auth/google/') && request.method == 'GET') {
            return http.Response(
              jsonEncode({'enabled': googleOn, 'server_client_id': googleOn ? _webClient : null}),
              200,
              headers: _json,
            );
          }
          if (path.endsWith('/auth/google/') && request.method == 'POST') {
            return googleAnswer();
          }
          if (path.endsWith('/auth/google/connect/')) {
            if (request.method == 'POST') me = {...me, 'google_email': 'carol@gmail.com'};
            if (request.method == 'DELETE') me = {...me, 'google_email': null};
            return http.Response(request.method == 'DELETE' ? '' : '{}',
                request.method == 'DELETE' ? 204 : 201,
                headers: _json);
          }
          if (path.endsWith('/auth/token/login/')) {
            return http.Response(jsonEncode({'auth_token': 'password-session'}), 200, headers: _json);
          }
          if (path.endsWith('/auth/users/me/')) {
            return http.Response(jsonEncode(me), 200, headers: _json);
          }
          return http.Response('{}', 200, headers: _json);
        }),
      );

  setUp(() {
    requests = [];
    googleOn = true;
    googleAnswer = () => http.Response(
          jsonEncode({'auth_token': 'google-session', 'created': true}),
          201,
          headers: _json,
        );
    me = {
      'id': 9,
      'username': 'carol',
      'email': 'carol@gmail.com',
      'is_staff': false,
      'is_superuser': false,
      'client_id': null,
      'google_email': 'carol@gmail.com',
      'has_password': false,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storage, (call) async => call.method == 'readAll' ? {} : null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storage, null);
    getIt.reset();
  });

  group('the service', () {
    test('asks nothing of the server on a platform that does not offer Google', () async {
      final auth = AuthService(buildApi(), biometrics: _NoBiometrics(), google: _FakeGoogle(supported: false));
      expect(await auth.googleServerClientId(), isNull);
      expect(requests, isEmpty);
    });

    test('offers Google only once the server has it switched on', () async {
      final auth = AuthService(buildApi(), biometrics: _NoBiometrics(), google: _FakeGoogle());
      googleOn = false;
      expect(await auth.googleServerClientId(), isNull);
      googleOn = true;
      expect(await auth.googleServerClientId(), _webClient);
    });

    test('backing out of Google sends nothing and signs nobody in', () async {
      final google = _FakeGoogle(token: null);
      final auth = AuthService(buildApi(), biometrics: _NoBiometrics(), google: google);
      expect(await auth.signInWithGoogle(_webClient), isFalse);
      expect(google.askedFor, [_webClient]);
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
      expect(auth.isSignedIn, isFalse);
    });

    test('signs in with the token the server hands back, like a password would', () async {
      final auth = AuthService(buildApi(), biometrics: _NoBiometrics(), google: _FakeGoogle());
      expect(await auth.signInWithGoogle(_webClient), isTrue);

      final post = requests.singleWhere((r) => r.method == 'POST');
      expect(jsonDecode(post.body), {'id_token': 'google-id-token'});
      expect(auth.isSignedIn, isTrue);
      expect(auth.user!.username, 'carol');
      expect(auth.user!.googleEmail, 'carol@gmail.com');
      expect(auth.user!.hasPassword, isFalse);
      expect(auth.accounts.single.token, 'google-session');
      final me = requests.lastWhere((r) => r.url.path.endsWith('/auth/users/me/'));
      expect(me.headers['Authorization'], 'Token google-session');
    });

    test('an older server that does not say whether there is a password is not "no"', () {
      final user = CurrentUser.fromJson({'id': 1, 'username': 'x', 'email': '', 'is_staff': false});
      expect(user.hasPassword, isNull);
      expect(user.googleEmail, isNull);
    });
  });

  group('the login screen', () {
    Future<AuthService> pump(WidgetTester tester, {_FakeGoogle? google}) async {
      final api = buildApi();
      final auth = AuthService(api, biometrics: _NoBiometrics(), google: google ?? _FakeGoogle());
      getIt.registerSingleton<ApiClient>(api);
      getIt.registerSingleton<AuthService>(auth);
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
      await tester.pumpAndSettle();
      return auth;
    }

    testWidgets('shows no Google button while the server has it off', (tester) async {
      googleOn = false;
      await pump(tester);
      expect(find.text('CONTINUE WITH GOOGLE'), findsNothing);
    });

    testWidgets('shows no Google button on a platform that does not offer it', (tester) async {
      await pump(tester, google: _FakeGoogle(supported: false));
      expect(find.text('CONTINUE WITH GOOGLE'), findsNothing);
    });

    testWidgets('signs in with Google', (tester) async {
      final auth = await pump(tester);
      await tester.tap(find.text('CONTINUE WITH GOOGLE'));
      await tester.pumpAndSettle();
      expect(auth.isSignedIn, isTrue);
    });

    testWidgets("shows the server's own words when it refuses", (tester) async {
      googleAnswer = () => http.Response(
            jsonEncode({
              'code': 'account_exists',
              'detail': 'There is already a Mojo and Co account for carol@gmail.com. '
                  'Sign in with your password, then connect Google from the account menu.',
            }),
            409,
            headers: _json,
          );
      final auth = await pump(tester);
      await tester.tap(find.text('CONTINUE WITH GOOGLE'));
      await tester.pumpAndSettle();
      expect(find.textContaining('connect Google from the account menu'), findsOneWidget);
      expect(auth.isSignedIn, isFalse);
    });

    testWidgets('a Google configuration failure says so rather than nothing', (tester) async {
      await pump(
        tester,
        google: _FakeGoogle(failure: const GoogleSignInFailure("Google sign-in isn't set up properly")),
      );
      await tester.tap(find.text('CONTINUE WITH GOOGLE'));
      await tester.pumpAndSettle();
      expect(find.textContaining("isn't set up properly"), findsOneWidget);
    });
  });

  group('the account menu', () {
    Future<void> pumpTile(WidgetTester tester, Map<String, dynamic> user) async {
      me = user;
      final api = buildApi();
      final auth = AuthService(api, biometrics: _NoBiometrics(), google: _FakeGoogle());
      getIt.registerSingleton<ApiClient>(api);
      getIt.registerSingleton<AuthService>(auth);
      await auth.signIn('whoever', 'pw');
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: GoogleConnectTile())));
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> client({String? google, bool hasPassword = true}) => {
          'id': 3,
          'username': 'alice',
          'email': 'alice@example.com',
          'is_staff': false,
          'is_superuser': false,
          'client_id': 1,
          'google_email': google,
          'has_password': hasPassword,
        };

    testWidgets('never offers Google to a staff login', (tester) async {
      await pumpTile(tester, {...client(), 'is_staff': true});
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('a client connects Google from here', (tester) async {
      await pumpTile(tester, client());
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method == 'POST' && r.url.path.endsWith('/auth/google/connect/')),
          hasLength(1));
      expect(find.text('Signs in with Google'), findsOneWidget);
    });

    testWidgets('disconnecting asks first', (tester) async {
      await pumpTile(tester, client(google: 'alice@gmail.com'));
      await tester.tap(find.text('DISCONNECT'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect Google?'), findsOneWidget);
      await tester.tap(find.text('DISCONNECT').last);
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
      expect(find.text('Sign in with Google'), findsOneWidget);
    });

    testWidgets('an account with no password cannot cut its only way in', (tester) async {
      await pumpTile(tester, client(google: 'carol@gmail.com', hasPassword: false));
      expect(find.text('DISCONNECT'), findsNothing);
      expect(find.textContaining('the only way into this account'), findsOneWidget);
    });
  });
}
