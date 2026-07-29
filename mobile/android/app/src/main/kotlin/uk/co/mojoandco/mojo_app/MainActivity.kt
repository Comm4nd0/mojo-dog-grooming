package uk.co.mojoandco.mojo_app

import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * FlutterFragmentActivity, not FlutterActivity: local_auth shows the system
 * BiometricPrompt, which is a fragment and needs a FragmentActivity to attach
 * to. On a plain FlutterActivity the prompt fails at runtime with
 * "no_fragment_activity" — it builds and installs perfectly well, and only
 * falls over the first time someone tries to unlock.
 */
class MainActivity : FlutterFragmentActivity()
