import 'package:flutter/material.dart';

import 'constants/app_colors.dart';
import 'screens/client/client_shell.dart';
import 'screens/lock_screen.dart';
import 'screens/login_screen.dart';
import 'screens/staff/staff_shell.dart';
import 'services/auth_service.dart';
import 'services/service_locator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  setupLocator();
  runApp(const MojoApp());
}

class MojoApp extends StatefulWidget {
  const MojoApp({super.key});

  @override
  State<MojoApp> createState() => _MojoAppState();
}

class _MojoAppState extends State<MojoApp> {
  final AuthService _auth = getIt<AuthService>();

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _auth.restore();
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mojo and Co',
      debugShowCheckedModeBanner: false,
      theme: AppColors.lightTheme(),
      darkTheme: AppColors.darkTheme(),
      home: _home(),
    );
  }

  Widget _home() {
    if (_auth.isRestoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // A restored session waiting on a fingerprint or face. Checked before
    // isSignedIn: the token is valid and the user is known, so sending them to
    // the login form would ask for the password they turned biometrics on to
    // stop typing.
    if (_auth.isLocked) return const LockScreen();
    if (!_auth.isSignedIn) return const LoginScreen();
    // Staff and clients get entirely different shells — a client never sees
    // the management surface at all.
    return _auth.isStaff ? const StaffShell() : const ClientShell();
  }
}
