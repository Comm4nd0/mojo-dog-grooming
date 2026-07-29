import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/service_locator.dart';

/// Turns the fingerprint or face check on and off for the current account.
///
/// Shown wherever both halves of the app can reach it — the account switcher —
/// rather than in a settings screen, because clients have no settings screen at
/// all and this is as much for them as for Jess.
///
/// It renders nothing on hardware with no enrolled biometrics. A switch that
/// can never be turned on is worse than no switch: it reads as broken.
class BiometricToggle extends StatefulWidget {
  const BiometricToggle({super.key});

  @override
  State<BiometricToggle> createState() => _BiometricToggleState();
}

class _BiometricToggleState extends State<BiometricToggle> {
  final _auth = getIt<AuthService>();

  BiometricCapability _capability = const BiometricCapability.none();
  bool _checked = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final capability = await _auth.biometricCapability();
    if (!mounted) return;
    setState(() {
      _capability = capability;
      _checked = true;
    });
  }

  Future<void> _set(bool value) async {
    setState(() => _busy = true);
    // Turning it on prompts first, inside AuthService: an account locked
    // behind a check that never passes would need signing out to escape.
    final applied = await _auth.setBiometricsEnabled(value);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!applied && value) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_capability.label} wasn\'t confirmed, so nothing changed.'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked || !_capability.available || !_auth.isSignedIn) {
      return const SizedBox.shrink();
    }
    final enabled = _auth.biometricsEnabledHere;
    return SwitchListTile(
      value: enabled,
      onChanged: _busy ? null : _set,
      secondary: const Icon(Icons.fingerprint, color: AppColors.primary),
      title: Text('Unlock with ${_capability.label}'),
      subtitle: Text(
        enabled
            ? 'Asked for every time this app is opened as ${_auth.user?.username ?? "you"}'
            : 'Skip typing your password on this device',
        style: const TextStyle(fontSize: 12.5),
      ),
    );
  }
}
