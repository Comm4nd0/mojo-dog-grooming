import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/services/api_client.dart';

/// `ApiClient` had no tests at all beyond an assertion about the base URL
/// constant, which left its error mapping — the part every screen's failure
/// path runs through — entirely unexercised.
void main() {
  ApiClient clientReturning(
    Future<http.Response> Function(http.Request request) handler, {
    Duration timeout = const Duration(milliseconds: 100),
  }) =>
      ApiClient(
        baseUrl: 'https://example.test/api',
        httpClient: MockClient(handler),
        timeout: timeout,
      );

  group('timeouts', () {
    test('a request that never answers gives up as a connection failure', () async {
      // The real failure this guards: a phone that has drifted out of range of
      // the salon wifi holds the socket open rather than refusing. With no
      // timeout the future never completed, and every screen sits at
      // `_loading = true` until its fetch returns — so the spinner span
      // forever with no way back but force-quitting the app.
      final api = clientReturning((_) => Completer<http.Response>().future);

      await expectLater(
        api.get('/dogs/'),
        throwsA(isA<NoConnectionException>()),
      );
    });

    test('a slow but answering request still succeeds', () async {
      final api = clientReturning(
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response(jsonEncode({'ok': true}), 200);
        },
        timeout: const Duration(seconds: 5),
      );

      expect(await api.get('/dogs/'), {'ok': true});
    });
  });

  group('error mapping', () {
    test('DRF per-field errors reach fieldErrors so forms can bind them', () async {
      final api = clientReturning(
        (_) async => http.Response(
          jsonEncode({
            'preferred_start_at': ['Pick a time in the future.'],
            'kind': ['This field is required.'],
          }),
          400,
        ),
      );

      try {
        await api.post('/appointment-change-requests/', {});
        fail('expected an ApiException');
      } on ApiException catch (error) {
        expect(error.statusCode, 400);
        expect(error.fieldErrors['preferred_start_at'], ['Pick a time in the future.']);
        expect(error.fieldErrors['kind'], ['This field is required.']);
      }
    });

    test('a {"detail": ...} body becomes the message', () async {
      final api = clientReturning(
        (_) async => http.Response(
          jsonEncode({'detail': 'You can only ask about your own bookings.'}),
          403,
        ),
      );

      try {
        await api.post('/appointment-change-requests/', {});
        fail('expected an ApiException');
      } on ApiException catch (error) {
        expect(error.isForbidden, isTrue);
        expect(error.toString(), 'You can only ask about your own bookings.');
      }
    });

    test('an empty 204 is not an error', () async {
      // `delete` returns void, so the assertion is that it completes at all —
      // an empty body must not be mistaken for a failure to decode.
      final api = clientReturning((_) async => http.Response('', 204));
      await expectLater(api.delete('/dog-photos/1/'), completes);
    });

    test('an empty body on a 4xx still raises', () async {
      final api = clientReturning((_) async => http.Response('', 403));
      await expectLater(api.get('/dogs/'), throwsA(isA<ApiException>()));
    });
  });

  group('resultsOf', () {
    test('unwraps a paginated response', () {
      expect(
        ApiClient.resultsOf({
          'count': 2,
          'results': [
            {'id': 1},
            {'id': 2},
          ],
        }),
        hasLength(2),
      );
    });

    test('tolerates a bare list, which unpaginated endpoints return', () {
      expect(
        ApiClient.resultsOf([
          {'id': 1},
        ]),
        hasLength(1),
      );
    });
  });

  group('getAll', () {
    // The breed list asked for 200 a page and got 100 for as long as the app
    // existed: DRF ignores `page_size` unless told to honour it, and nothing
    // on the phone noticed the `next` link. A reference list is only useful
    // whole, so this walks pages until the server says there are no more.
    test('walks every page and stops when there is no next', () async {
      final pagesAsked = <String?>[];
      final api = clientReturning((request) async {
        pagesAsked.add(request.url.queryParameters['page']);
        final page = int.parse(request.url.queryParameters['page'] ?? '1');
        return http.Response(
          jsonEncode({
            'count': 5,
            'next': page < 3 ? 'https://example.test/api/breeds/?page=${page + 1}' : null,
            'previous': null,
            'results': page < 3 ? [{'id': page * 2 - 1}, {'id': page * 2}] : [{'id': 5}],
          }),
          200,
        );
      });

      final rows = await api.getAll('/breeds/', query: {'search': 'poo'}, pageSize: 2);

      expect(rows.map((r) => r['id']), [1, 2, 3, 4, 5]);
      expect(pagesAsked, ['1', '2', '3']);
    });

    test('asks by page number, never by following the next URL', () async {
      // The `next` link is built from whatever host header reached gunicorn;
      // behind a proxy that is not always one the phone can reach. Here it
      // points somewhere unreachable and must be ignored.
      final hosts = <String>{};
      final api = clientReturning((request) async {
        hosts.add(request.url.host);
        final page = request.url.queryParameters['page'];
        return http.Response(
          jsonEncode({
            'count': 2,
            'next': page == '1' ? 'http://web:8000/api/breeds/?page=2' : null,
            'results': [{'id': page}],
          }),
          200,
        );
      });

      final rows = await api.getAll('/breeds/');

      expect(rows.map((r) => r['id']), ['1', '2']);
      expect(hosts, {'example.test'});
    });

    test('a bare list is one page', () async {
      final api = clientReturning(
        (_) async => http.Response(jsonEncode([{'id': 1}]), 200),
      );
      expect((await api.getAll('/things/')).length, 1);
    });
  });
}
