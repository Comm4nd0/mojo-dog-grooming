import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/auth_service.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/groom_timer_service.dart';
import 'package:mojo_app/services/offline_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> disk;
  var failWrites = false;
  setUp(() {
    disk = {};
    failWrites = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          switch (call.method) {
            case 'read':
              return disk[args['key']];
            case 'write':
              if (failWrites) throw PlatformException(code: 'disk-full');
              disk[args['key'] as String] = args['value'] as String;
              return null;
            case 'delete':
              disk.remove(args['key']);
              return null;
          }
          return null;
        });
  });

  Map<String, dynamic> snapshot() => {
    'saved_at': '2026-10-13T12:00:00Z',
    'dogs': [
      {
        'id': 7,
        'name': 'Bunny',
        'client': 2,
        'client_full_name': 'Alice Adams',
        'is_active': true,
      },
      {'id': 8, 'name': 'Teddy', 'client': 3, 'is_active': false},
    ],
    'profiles': [
      {
        'id': 7,
        'name': 'Bunny',
        'client': 2,
        'temperament_notes': 'Private handling note',
      },
    ],
    'visits': [],
    'photos': [],
    'documents': [],
    'grades': [],
    'equipment': [],
    'breeds': [],
    'clients': [],
    'settings': {},
  };

  ApiClient api(Future<http.Response> Function(http.Request) handler) =>
      ApiClient(baseUrl: 'https://test/api', httpClient: MockClient(handler));
  http.Response json(Object value, [int status = 200]) =>
      http.Response(jsonEncode(value), status);
  Future<OfflineStore> store([String scope = 'staff-7']) async {
    final value = OfflineStore();
    await value.activate(scope);
    return value;
  }

  test(
    'saved Doguments survives restart, searches offline, and separates accounts',
    () async {
      final first = await store();
      await first.saveSnapshot(snapshot());
      final restored = await store();
      final data = DataService(
        api((_) async => throw const SocketException('offline')),
        offline: restored,
      );
      expect((await data.getDogs()).single.name, 'Bunny');
      expect((await data.getDogs(search: 'alice')).single.name, 'Bunny');
      expect(await data.getDogs(search: 'unknown'), isEmpty);
      expect(await data.getDogs(includeInactive: true), hasLength(2));
      expect((await data.getDog(7)).temperamentNotes, 'Private handling note');
      expect(restored.isOffline, isTrue);
      await restored.activate('another-staff');
      expect(restored.read('/dogs/7/', null), isNull);
      await restored.activate(
        null,
      ); // Client login and sign-out use no staff scope.
      expect(restored.read('/dogs/7/', null), isNull);
      await restored.activate('staff-7');
      expect(restored.read('/dogs/7/', null)['name'], 'Bunny');
    },
  );

  test(
    'offline finish is durable and reconnect retries the same reference and date',
    () async {
      final saved = await store();
      await saved.saveSnapshot(snapshot());
      final connection = api(
        (_) async => throw const SocketException('offline'),
      );
      final data = DataService(connection, offline: saved);
      final started = DateTime.utc(2026, 10, 10, 9);
      final reference = newGroomReference();
      final visit = await data.createGroomSession(
        dogId: 7,
        dogName: 'Bunny',
        startedAt: started,
        clientReference: reference,
        applyToDog: true,
        completeCard: true,
        timings: [const PhaseTiming(phase: 'PREP', durationSeconds: 600)],
        record: {
          'notes': 'Good girl',
          'bathed': null,
          'health_check_done': true,
        },
      );
      expect(visit.pendingSync, isTrue);
      expect(saved.pendingCount, 1);
      final restored = await store();
      final requests = <Map<String, dynamic>>[];
      final online = DataService(
        api((request) async {
          if (request.url.path.endsWith('/auth/users/me/')) {
            return json({'is_staff': true});
          }
          if (request.method == 'POST') {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return json({'id': 41});
          }
          return json(snapshot());
        }),
        offline: restored,
      );
      await online.syncOffline();
      expect(restored.pendingCount, 0);
      expect(requests.single['client_reference'], reference);
      expect(requests.single['started_at'], started.toIso8601String());
      expect(requests.single['apply_to_dog'], isTrue);
      expect(requests.single['complete_card'], isTrue);
      expect(requests.single['bathed'], isNull);
      expect(requests.single['health_check_done'], isTrue);
      expect((await store()).pendingCount, 0);
    },
  );

  test('lost server response keeps upload for idempotent retry', () async {
    final saved = await store();
    final server = <String, int>{};
    var dropResponse = true;
    final data = DataService(
      api((request) async {
        if (request.url.path.endsWith('/auth/users/me/')) {
          return json({'is_staff': true});
        }
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final ref = body['client_reference'] as String;
          server.putIfAbsent(ref, () => server.length + 1);
          if (dropResponse) throw const SocketException('response lost');
          return json({'id': server[ref]});
        }
        return json(snapshot());
      }),
      offline: saved,
    );
    final result = await data.createGroomSession(
      dogId: 0,
      dogName: 'Walk-in spaniel',
      timings: [],
    );
    expect(result.isWalkIn, isTrue);
    expect(result.pendingSync, isTrue);
    expect((await data.getWalkIns()).single.dogName, 'Walk-in spaniel');
    dropResponse = false;
    await data.syncOffline();
    expect(server, hasLength(1));
    expect(saved.pendingCount, 0);
  });

  test(
    'disk failure does not claim a groom is saved or send an untracked upload',
    () async {
      final saved = await store();
      var calls = 0;
      final data = DataService(
        api((_) async {
          calls++;
          return json({'id': 1});
        }),
        offline: saved,
      );
      failWrites = true;
      await expectLater(
        data.createGroomSession(dogId: 7, dogName: 'Bunny', timings: []),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, 0);
      expect(saved.pendingCount, 0);
    },
  );

  test(
    'one rejected upload can be repaired without holding up other grooms',
    () async {
      final saved = await store();
      final bad = newGroomReference();
      final good = newGroomReference();
      await saved.enqueue({
        'client_reference': bad,
        'dog': 99,
        'notes': 'Keep this card',
      }, 'Bunny');
      await saved.enqueue({'client_reference': good, 'dog': 8}, 'Teddy');
      await expectLater(saved.revise(bad, {'dog': 7}), throwsStateError);
      final uploaded = <String>[];
      final data = DataService(
        api((request) async {
          if (request.url.path.endsWith('/auth/users/me/')) {
            return json({'is_staff': true});
          }
          if (request.method == 'POST') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['dog'] == 99) {
              return json({
                'dog': ['This dog no longer exists.'],
              }, 400);
            }
            uploaded.add(body['client_reference'] as String);
            return json({'id': 12});
          }
          return json(snapshot());
        }),
        offline: saved,
      );
      await data.syncOffline();
      expect(uploaded, [good]);
      expect(
        data.pendingGrooms.single.pendingError,
        contains('no longer exists'),
      );
      expect((await store()).pending.single['error'], isNotNull);
      await data.revisePendingGroom(bad, {'dog': 7});
      expect(saved.pending.single['body']['notes'], 'Keep this card');
      await data.syncOffline();
      expect(uploaded, [good, bad]);
      expect(saved.pendingCount, 0);
    },
  );

  test(
    'failed snapshot write during account switch cannot restore old private records',
    () async {
      final saved = await store();
      await saved.saveSnapshot(snapshot());
      final write = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'write') await write.future;
            return null;
          });
      final saving = saved.saveSnapshot(snapshot());
      final failed = expectLater(saving, throwsA(isA<PlatformException>()));
      final switching = saved.activate('another-account');
      write.completeError(PlatformException(code: 'disk-full'));
      await failed;
      await switching;
      expect(saved.read('/dogs/7/', null), isNull);
      expect(saved.savedAt, isNull);
    },
  );

  test(
    'validation error is shown instead of being claimed as an offline save',
    () async {
      final saved = await store();
      final data = DataService(
        api(
          (_) async => json({
            'dog': ['No longer exists'],
          }, 400),
        ),
        offline: saved,
      );
      await expectLater(
        data.createGroomSession(dogId: 7, dogName: 'Bunny', timings: []),
        throwsA(isA<ApiException>()),
      );
      expect(saved.pendingCount, 0);
    },
  );

  test('401 never falls back to private cached data', () async {
    final saved = await store();
    await saved.saveSnapshot(snapshot());
    final data = DataService(
      api((_) async => json({'detail': 'Token revoked'}, 401)),
      offline: saved,
    );
    await expectLater(data.getDog(7), throwsA(isA<ApiException>()));
    expect(saved.enabled, isFalse);
    expect(saved.read('/dogs/7/', null), isNull);
  });

  test('a client without a staff cache can retry after a network failure', () async {
    final saved = OfflineStore();
    var connected = false;
    final data = DataService(api((_) async {
      if (!connected) throw const SocketException('offline');
      return json({'id': 7, 'name': 'Bunny'});
    }), offline: saved);
    await expectLater(data.getDog(7), throwsA(isA<NoConnectionException>()));
    connected = true;
    expect((await data.getDog(7)).name, 'Bunny');
    expect(saved.enabled, isFalse);
  });

  test('demoted staff account cannot upload queued grooms', () async {
    final saved = await store();
    await saved.enqueue({
      'client_reference': newGroomReference(),
      'dog': 7,
    }, 'Bunny');
    var posts = 0;
    final data = DataService(
      api((request) async {
        if (request.method == 'POST') posts++;
        return json({'is_staff': false});
      }),
      offline: saved,
    );
    await data.syncOffline();
    expect(posts, 0);
    expect(saved.enabled, isFalse);
    expect(
      (await store()).pendingCount,
      1,
    ); // Kept, never destroyed on rejection.
  });

  test('late staff response cannot become another account\'s cache', () async {
    final saved = await store();
    final response = Completer<http.Response>();
    final data = DataService(api((_) => response.future), offline: saved);
    final loading = data.getDog(7);
    await saved.activate('someone-else');
    response.complete(json({'id': 7, 'temperament_notes': 'private'}));
    await expectLater(loading, throwsA(isA<ApiException>()));
    expect(saved.read('/dogs/7/', null), isNull);
  });

  test(
    'timer scopes preserve separate walk-ins, their drafts, references and starts',
    () async {
      final timer = GroomTimerService(accountScoped: true);
      await timer.activateAccount('staff-a');
      final one = timer.openWalkIn('Brown spaniel');
      final two = timer.openWalkIn('White terrier');
      expect(one.dogId, isNot(two.dogId));
      timer.setMinutes(one.dogId, 'WASH', 15);
      timer.setDraft(one.dogId, {'health_check_notes': 'Private'});
      await timer.flush();
      await timer.activateAccount(null);
      expect(timer.sessions, isEmpty);
      await timer.activateAccount('staff-b');
      expect(timer.sessions, isEmpty);
      await timer.activateAccount('staff-a');
      expect(timer.sessions, hasLength(2));
      final restored = timer.sessionFor(one.dogId)!;
      expect(restored.totalMinutes, 15);
      expect(restored.draft['health_check_notes'], 'Private');
      expect(restored.clientReference, one.clientReference);
      expect(restored.startedAt, one.startedAt);
      timer.dispose();
    },
  );

  test('app opens a previously signed-in staff account offline', () async {
    disk['mojo_accounts'] = jsonEncode({
      'active': 'jess',
      'accounts': [
        {
          'username': 'jess',
          'user_id': 7,
          'token': 'test-token',
          'is_staff': true,
          'biometrics': false,
        },
      ],
    });
    String? activeScope;
    final auth = AuthService(
      api((_) async => throw const SocketException('offline')),
      onAccountChanged: (scope, staff) async {
        activeScope = staff ? scope : null;
      },
    );
    await auth.restore();
    expect(auth.isSignedIn, isTrue);
    expect(auth.isStaff, isTrue);
    expect(auth.user!.id, 7);
    expect(activeScope, '7:jess');
  });
}
