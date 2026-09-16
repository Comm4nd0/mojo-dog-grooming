import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Asking Google, on the phone, who the person is.
///
/// This is the only file that touches the plugin, so everything above it can
/// be tested with a fake. It hands back Google's ID token and nothing else —
/// the server is what checks that token and decides which login it opens, so
/// nothing the phone believes about the person is ever taken on trust.
abstract class GoogleIdTokenSource {
  /// Whether this build, on this platform, should offer Google at all.
  bool get platformSupported;

  /// Show Google's account picker and return an ID token for
  /// [serverClientId], or null if the person backed out.
  Future<String?> idToken({required String serverClientId});
}

/// Thrown when Google itself failed — as opposed to the person cancelling,
/// which is not an error and returns null.
class GoogleSignInFailure implements Exception {
  const GoogleSignInFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

class PluginGoogleIdTokenSource implements GoogleIdTokenSource {
  String? _initialisedFor;

  /// **Android only, for now, and deliberately.** Apple's App Review
  /// guideline 4.8 rejects an iOS app that offers a third-party sign-in such
  /// as Google without also offering Sign in with Apple. The App Store
  /// release has not happened yet, and a Google button on iOS would be the
  /// reason it didn't. iOS also needs its own client ID and URL scheme in
  /// Info.plist, which cannot exist until that client is made.
  @override
  bool get platformSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<String?> idToken({required String serverClientId}) async {
    final google = GoogleSignIn.instance;
    try {
      if (_initialisedFor != serverClientId) {
        await google.initialize(serverClientId: serverClientId);
        _initialisedFor = serverClientId;
      }
      if (!google.supportsAuthenticate()) {
        throw const GoogleSignInFailure("Google sign-in isn't available on this device.");
      }
      final account = await google.authenticate();
      final token = account.authentication.idToken;
      // Signed out of the plugin straight away: Mojo and Co keeps its own
      // session from here, and leaving Google's cached choice in place would
      // skip the account picker next time — which is how somebody on a shared
      // salon phone ends up in the previous person's account.
      await google.signOut();
      if (token == null || token.isEmpty) {
        throw const GoogleSignInFailure('Google did not return a sign-in token. Try again.');
      }
      return token;
    } on GoogleSignInException catch (error) {
      switch (error.code) {
        case GoogleSignInExceptionCode.canceled:
        case GoogleSignInExceptionCode.interrupted:
          return null;
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
          // The usual cause is the Android client in Google Cloud not having
          // this build's signing fingerprint. Nothing the person can fix.
          throw const GoogleSignInFailure(
            "Google sign-in isn't set up properly for this app yet. "
            'Sign in with your password for now.',
          );
        default:
          throw GoogleSignInFailure(
            error.description?.isNotEmpty == true
                ? 'Google sign-in failed: ${error.description}'
                : 'Google sign-in failed. Try again.',
          );
      }
    }
  }
}
