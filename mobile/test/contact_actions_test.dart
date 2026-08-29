import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/widgets/contact_actions.dart';

/// Opening a map is the one contact action that differs per platform, and it
/// failed for real once: `geo:` was sent everywhere, iOS has no handler for
/// it, and Jess got "Couldn't open a map for that address" on a perfectly
/// good postcode. These pin who gets which URI — macOS included, which has no
/// `geo:` handler any more than iOS does — and that the browser fallback is
/// always there.
void main() {
  test('a multi-line address folds into one query', () {
    expect(
      mapQuery('1 High Street\nHenley-on-Thames', 'RG9 6SN'),
      '1 High Street, Henley-on-Thames, RG9 6SN',
    );
  });

  test('Apple platforms lead with Apple Maps', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      final uris = mapUris('RG9 6SN', platform: platform);
      expect(uris.first.host, 'maps.apple.com', reason: '$platform');
      expect(uris.first.queryParameters['q'], 'RG9 6SN');
    }
  });

  test('Android leads with geo:', () {
    final uris = mapUris('RG9 6SN', platform: TargetPlatform.android);
    expect(uris.first.scheme, 'geo');
  });

  test('everything falls back to Google Maps in the browser', () {
    for (final platform in TargetPlatform.values) {
      final uris = mapUris('RG9 6SN', platform: platform);
      expect(uris.last.host, 'www.google.com', reason: '$platform');
    }
  });
}
