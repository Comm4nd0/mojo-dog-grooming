import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/services/service_locator.dart';

void main() {
  group('the API base URL the app ships with', () {
    test('is https', () {
      // Every call carries the auth token in an Authorization header. On plain
      // http that header is readable by anyone on the salon wifi, and the
      // server-side http->https redirect does not help: the request that gets
      // redirected has already gone out in the clear.
      expect(apiBaseUrl, startsWith('https://'));
    });

    test('points at app.mojoandco.uk, not the interim sslip name', () {
      // The sslip.io host existed only while app.mojoandco.uk had no A record.
      // Caddy still answers to it so builds already on a phone keep working,
      // but a new build defaulting to it would extend the thing indefinitely.
      expect(apiBaseUrl, startsWith('https://app.mojoandco.uk/'));
      expect(apiBaseUrl, isNot(contains('sslip.io')));
    });

    test('ends at /api, so paths concatenate to a real endpoint', () {
      // ApiClient builds URLs as '$baseUrl$path' with path like '/users/me/'.
      // A trailing slash here would produce //users/me/.
      expect(apiBaseUrl, endsWith('/api'));
    });
  });
}
