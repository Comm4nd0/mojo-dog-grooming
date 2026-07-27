import 'package:get_it/get_it.dart';

import 'api_client.dart';
import 'auth_service.dart';
import 'data_service.dart';

final GetIt getIt = GetIt.instance;

/// Where the API lives.
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
