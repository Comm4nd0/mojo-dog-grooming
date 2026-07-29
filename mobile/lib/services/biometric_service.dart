import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// What biometric hardware this device offers, and whether it is usable.
///
/// [available] is deliberately not the same question as "has hardware": a
/// phone with a fingerprint reader that has never been enrolled, or one where
/// the user has since removed every finger, reports hardware and then fails
/// every prompt. Only enrolled biometrics count.
class BiometricCapability {
  const BiometricCapability({required this.available, required this.label});

  const BiometricCapability.none() : available = false, label = 'Biometrics';

  final bool available;

  /// What to call it on screen — "Face ID" on an iPhone, "fingerprint" on most
  /// Android hardware. Calling Face ID "biometrics" in the UI reads as a
  /// different feature to the one the platform taught the user about.
  final String label;
}

/// The device's own unlock check, wrapped so the app can be tested without it.
///
/// This is a *local* gate, and it is worth being precise about what it buys.
/// The API token already lives in the Keychain / EncryptedSharedPreferences and
/// is what actually authenticates to the server; a biometric prompt does not
/// re-authenticate against Mojo and Co and cannot revoke anything. What it does
/// is stop someone holding an unlocked phone from reading a client list or a
/// diary — which is the realistic threat for an app that lives in a grooming
/// salon and gets handed across a counter.
abstract class BiometricAuthenticator {
  Future<BiometricCapability> capability();

  /// Prompt for a fingerprint or face. Returns false if the user cancelled,
  /// failed, or the platform refused — never throws for those.
  Future<bool> authenticate(String reason);
}

class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<BiometricCapability> capability() async {
    try {
      if (!await _auth.isDeviceSupported()) return const BiometricCapability.none();
      // canCheckBiometrics is true for unenrolled hardware too, so the
      // enrolled list is what decides.
      final enrolled = await _auth.getAvailableBiometrics();
      if (enrolled.isEmpty) return const BiometricCapability.none();
      return BiometricCapability(available: true, label: _label(enrolled));
    } on PlatformException catch (error) {
      debugPrint('Biometric capability check failed: ${error.code}');
      return const BiometricCapability.none();
    } on MissingPluginException {
      // Running somewhere the plugin isn't registered — tests, or a desktop
      // build. Treat it as "no biometrics" rather than crashing the app root.
      return const BiometricCapability.none();
    }
  }

  static String _label(List<BiometricType> enrolled) {
    if (enrolled.contains(BiometricType.face)) return 'Face ID';
    if (enrolled.contains(BiometricType.iris)) return 'iris unlock';
    if (enrolled.contains(BiometricType.fingerprint)) return 'fingerprint';
    // strong/weak carry no hint of which sensor it is.
    return 'biometrics';
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          // Falls back to the device PIN or passcode when a face or finger
          // won't read. Without this a wet hand locks someone out of the app
          // entirely, and their only way forward is signing out.
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException catch (error) {
      debugPrint('Biometric prompt failed: ${error.code}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
