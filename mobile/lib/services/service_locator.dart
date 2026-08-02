import 'package:get_it/get_it.dart';

import 'api_client.dart';
import 'auth_service.dart';
import 'data_service.dart';

final GetIt getIt = GetIt.instance;

/// Where the API lives.
///
/// HTTPS, and not negotiable: the token that authenticates every call rides in
/// an Authorization header, so plain HTTP would hand it to anyone on the same
/// wifi as the salon. `DJANGO_SECURE_HTTPS` redirects http to https server-side
/// as well, but a redirect is a round trip that already carried the header.
///
/// This used to default to https://mojo.178-104-29-66.sslip.io/api, an interim
/// name that existed only because app.mojoandco.uk had no A record and Caddy
/// therefore could not get a certificate for it. The record exists now. Caddy
/// still answers to the old name for builds already on a phone — see the
/// Caddyfile — but nothing new should use it.
///
/// Override at build time for a device pointed at a dev machine:
///   flutter run --dart-define=MOJO_API_BASE=http://192.168.1.20:8000/api
const String apiBaseUrl = String.fromEnvironment(
  'MOJO_API_BASE',
  defaultValue: 'https://app.mojoandco.uk/api',
);

/// Registers services. Call once from `main()` before `runApp`.
void setupLocator({String? baseUrl}) {
  if (getIt.isRegistered<DataService>()) return; // Idempotent across hot restarts.

  final api = ApiClient(baseUrl: baseUrl ?? apiBaseUrl);
  getIt.registerSingleton<ApiClient>(api);
  getIt.registerSingleton<AuthService>(AuthService(api));
  getIt.registerSingleton<DataService>(DataService(api));
}
