import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/service_locator.dart';

/// What the app shows when a remembered session is waiting on a fingerprint
/// or face check.
///
/// It prompts as soon as it appears, so the ordinary case is that nobody ever
/// reads this screen — they see the system sheet, pass it, and land on the
/// diary. It exists for the case where they don't: a cancelled prompt, a wet
/// hand, a sensor that won't read.
///
/// The way out is always here. "Use a password instead" signs out and returns
/// to the login form, because an account locked behind a check that cannot
/// pass, with no escape, is an account nobody can reach again.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _auth = getIt<AuthService>();

  bool _busy = false;
  bool _prompted = false;
  String? _message;
  BiometricCapability _capability = const BiometricCapability.none();

  @override
  void initState() {
    super.initState();
    // After the first frame: the prompt is a platform sheet over this route,
    // and raising it during build races the route being on screen at all.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final capability = await _auth.biometricCapability();
    if (!mounted) return;
    setState(() => _capability = capability);
    await _unlock();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final passed = await _auth.unlock();
      // Success swaps this screen out — the app root listens to AuthService.
      if (!passed && mounted) {
        setState(() => _message = _prompted
            ? 'That didn\'t match. Try again, or use your password.'
            : null);
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      _prompted = true;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _usePassword() async {
    setState(() => _busy = true);
    await _auth.signOut();
    // signOut notifies, so the root swaps in the login screen.
  }

  @override
  Widget build(BuildContext context) {
    final username = _auth.user?.username ?? '';
    final label = _capability.available ? _capability.label : 'your device unlock';

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    color: AppColors.primaryBright,
                    child: const Icon(Icons.lock_outline, size: 32, color: Colors.black),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Mojo and Co',
                    textAlign: TextAlign.center,
                    style: AppColors.display(28),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    username.isEmpty
                        ? 'Locked. Unlock with $label to carry on.'
                        : 'Locked as $username. Unlock with $label to carry on.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13.5, color: AppColors.inkSecondary),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppColors.error),
                    ),
                  ],
                  const SizedBox(height: 28),
                  ElevatedButton(
                    onPressed: _busy ? null : _unlock,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Text('UNLOCK'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : _usePassword,
                    child: const Text('Use a password instead'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
