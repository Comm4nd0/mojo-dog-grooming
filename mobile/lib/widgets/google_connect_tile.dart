import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/google_sign_in_service.dart';
import '../services/service_locator.dart';

/// Connect Google to the login already signed in, or disconnect it.
///
/// This is the only way an existing client starts signing in with Google. The
/// login screen refuses a Google account whose address already has a login,
/// because registration never verified that address and the match proves
/// nothing about who holds the password — so the owner proves it by being
/// signed in here, and connects from inside.
///
/// Renders nothing for a staff login (the server refuses those outright), on a
/// platform that does not offer Google, or when the server has it switched off.
class GoogleConnectTile extends StatefulWidget {
  const GoogleConnectTile({super.key});

  @override
  State<GoogleConnectTile> createState() => _GoogleConnectTileState();
}

class _GoogleConnectTileState extends State<GoogleConnectTile> {
  final _auth = getIt<AuthService>();
  String? _clientId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_auth.isSignedIn || _auth.isStaff) return;
    final id = await _auth.googleServerClientId();
    if (mounted) setState(() => _clientId = id);
  }

  Future<void> _connect() async {
    final clientId = _clientId;
    if (clientId == null) return;
    await _run(() async {
      final connected = await _auth.connectGoogle(clientId);
      if (connected) _say('You can now sign in with ${_auth.user?.googleEmail ?? 'Google'}.');
    });
  }

  Future<void> _disconnect() async {
    final email = _auth.user?.googleEmail ?? 'Google';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Disconnect Google?'),
        content: Text("$email won't sign you in any more. Your password still will."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('KEEP IT'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('DISCONNECT'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _auth.disconnectGoogle();
      _say('Google disconnected.');
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (error) {
      _say(error.message, isError: true);
    } on NoConnectionException catch (error) {
      _say(error.toString(), isError: true);
    } on GoogleSignInFailure catch (error) {
      _say(error.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? AppColors.error : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.user;
    if (_clientId == null || user == null || user.isStaff) return const SizedBox.shrink();

    final connected = user.googleEmail;
    if (connected == null) {
      return ListTile(
        leading: Icon(Icons.account_circle_outlined, color: context.mojo.accent),
        title: const Text('Sign in with Google'),
        subtitle: const Text(
          'Connect a Google account to use instead of your password',
          style: TextStyle(fontSize: 12.5),
        ),
        onTap: _busy ? null : _connect,
      );
    }

    // A login made through Google has no password, so disconnecting would be
    // a way to lock yourself out. The server refuses it too; saying so here
    // beats a button that fails.
    final canDisconnect = user.hasPassword != false;
    return ListTile(
      leading: Icon(Icons.account_circle, color: context.mojo.accent),
      title: const Text('Signs in with Google'),
      subtitle: Text(
        canDisconnect ? connected : '$connected · the only way into this account',
        style: const TextStyle(fontSize: 12.5),
      ),
      trailing: canDisconnect
          ? TextButton(
              onPressed: _busy ? null : _disconnect,
              child: const Text('DISCONNECT'),
            )
          : null,
    );
  }
}
