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
}
