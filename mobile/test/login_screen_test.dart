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
import 'package:mojo_app/services/service_locator.dart';

class _NoBiometrics implements BiometricAuthenticator {
  @override
  Future<BiometricCapability> capability() async => const BiometricCapability.none();

  @override
  Future<bool> authenticate(String reason) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late List<String> postedPaths;
  late Map<String, dynamic> lastBody;

  setUp(() {
    postedPaths = [];
    lastBody = const {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async => call.method == 'readAll' ? {} : null);

    final api = ApiClient(
      baseUrl: 'https://example.test/api',
      httpClient: MockClient((request) async {
        postedPaths.add(request.url.path);
        if (request.body.isNotEmpty) {
          lastBody = jsonDecode(request.body) as Map<String, dynamic>;
        }
        if (request.url.path.endsWith('/password-reset-requests/')) {
          return http.Response(
            jsonEncode({'detail': 'Thanks — Mojo and Co will be in touch.'}),
            202,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/auth/users/')) {
          // What the hardened registration serializer answers with.
          return http.Response(
            jsonEncode({'username': ['That username is taken. Try another.']}),
            400,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      }),
    );

    getIt.reset();
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<AuthService>(AuthService(api, biometrics: _NoBiometrics()));
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
    getIt.reset();
  });

  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('signing in accepts a username or an email, and says so', (tester) async {
    await pumpLogin(tester);
    // The server matches either; a label saying only "Username" is what makes
    // someone who signed up with their email give up at the first field.
    expect(find.text('Username or email'), findsOneWidget);
  });

  testWidgets('there is a way out for someone who has forgotten their password',
      (tester) async {
    await pumpLogin(tester);
    expect(find.text('I\'ve forgotten my password'), findsOneWidget);
  });

  testWidgets('asking for help posts the identifier and reports back', (tester) async {
    await pumpLogin(tester);
    await tester.enterText(find.byType(TextFormField).first, 'alice');
    await tester.tap(find.text('I\'ve forgotten my password'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SEND REQUEST'));
    await tester.pumpAndSettle();

    expect(postedPaths.last, endsWith('/password-reset-requests/'));
    expect(lastBody['identifier'], 'alice');
    expect(find.textContaining('in touch'), findsOneWidget);
  });

  testWidgets('registering asks for the password twice', (tester) async {
    await pumpLogin(tester);
    expect(find.text('Type your password again'), findsNothing);

    await tester.tap(find.text('New client? Create an account'));
    await tester.pumpAndSettle();

    expect(find.text('Type your password again'), findsOneWidget);
    // Nothing to forget yet — the link belongs to the sign-in side only.
    expect(find.text('I\'ve forgotten my password'), findsNothing);
  });

  testWidgets('a mistyped confirmation is caught before anything is sent',
      (tester) async {
    // A typo in a field nobody can see otherwise makes an account that cannot
    // be signed into, discovered only on the next launch.
    await pumpLogin(tester);
    await tester.tap(find.text('New client? Create an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'carol');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'carol@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'Grooming-2026!');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Type your password again'),
      'Grooming-2026',
    );
    await tester.ensureVisible(find.text('CREATE ACCOUNT'));
    await tester.tap(find.text('CREATE ACCOUNT'));
    await tester.pumpAndSettle();

    expect(find.text('Those two are different'), findsOneWidget);
    expect(postedPaths, isEmpty, reason: 'nothing should have been sent');
  });

  testWidgets('a server complaint lands under the field it is about', (tester) async {
    await pumpLogin(tester);
    await tester.tap(find.text('New client? Create an account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'alice');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'carol@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'Grooming-2026!');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Type your password again'),
      'Grooming-2026!',
    );
    await tester.ensureVisible(find.text('CREATE ACCOUNT'));
    await tester.tap(find.text('CREATE ACCOUNT'));
    await tester.pumpAndSettle();

    // Shown against the username box, not only in the banner at the bottom of
    // a form with no indication of which box to fix.
    expect(find.text('That username is taken. Try another.'), findsWidgets);
  });

  testWidgets('the password can be revealed', (tester) async {
    await pumpLogin(tester);
    expect(find.byTooltip('Show password'), findsOneWidget);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Hide password'), findsOneWidget);
  });

  group('the models behind the logins screen', () {
    test('an account shows the client it belongs to, not just a username', () {
      final account = AccountSummary.fromJson({
        'id': 3,
        'username': 'alice',
        'email': 'alice@example.com',
        'full_name': 'Alice Adams',
        'is_staff': false,
        'is_superuser': false,
        'is_active': true,
        'client_name': 'Alice Adams',
        'client_uid': 'MOJO-001',
      });
      expect(account.subtitle, 'Alice Adams · MOJO-001');
    });

    test('an account with no client record falls back to something usable', () {
      final account = AccountSummary.fromJson({
        'id': 4,
        'username': 'newbie',
        'email': 'new@example.com',
        'full_name': '',
        'is_staff': false,
        'is_superuser': false,
        'is_active': true,
      });
      expect(account.subtitle, 'new@example.com');
    });

    test('a request that matched nothing knows it', () {
      final unmatched = PasswordHelpRequest.fromJson({
        'id': 1,
        'identifier': 'alicce',
        'note': '',
        'status': 'PENDING',
      });
      expect(unmatched.isMatched, isFalse);
      // Kept regardless: someone typing the wrong thing is exactly who needs
      // help, and Jess can usually tell who they meant.
      expect(unmatched.identifier, 'alicce');
    });

    test('superuser comes down with the identity, so the tile can be gated', () {
      final user = CurrentUser.fromJson({
        'id': 1,
        'username': 'jess',
        'email': 'jess@example.com',
        'is_staff': true,
        'is_superuser': true,
      });
      expect(user.isSuperuser, isTrue);
    });

    test('a payload without the flag is not a superuser', () {
      final user = CurrentUser.fromJson({
        'id': 2,
        'username': 'alice',
        'email': 'alice@example.com',
        'is_staff': false,
      });
      expect(user.isSuperuser, isFalse);
    });
  });
}
