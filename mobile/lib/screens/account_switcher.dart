import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/service_locator.dart';
import 'login_screen.dart';

/// The accounts remembered on this device, with a tap to switch between them.
///
/// Shared by the staff and client shells: Jess uses it to check what a client
/// actually sees without signing out of her own account and back in again.
Future<void> showAccountSwitcher(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => const _AccountSwitcherSheet(),
  );
}

class _AccountSwitcherSheet extends StatefulWidget {
  const _AccountSwitcherSheet();

  @override
  State<_AccountSwitcherSheet> createState() => _AccountSwitcherSheetState();
}

class _AccountSwitcherSheetState extends State<_AccountSwitcherSheet> {
  final _auth = getIt<AuthService>();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final current = _auth.user?.username;
    // `accounts` hands back a copy, so sorting it here is safe.
    final accounts = _auth.accounts
      ..sort((a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Row(
              children: [
                Text(
                  'ACCOUNTS',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w700,
                    color: AppColors.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          for (final account in accounts)
            ListTile(
              leading: Icon(
                account.isStaff ? Icons.content_cut : Icons.person_outline,
                color: account.username == current ? AppColors.primary : AppColors.inkSecondary,
              ),
              title: Text(
                account.username,
                style: TextStyle(
                  fontWeight:
                      account.username == current ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              subtitle: Text(account.isStaff ? 'Staff' : 'Client'),
              trailing: account.username == current
                  ? const Icon(Icons.check, color: AppColors.primary)
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Forget this account',
                      onPressed: _busy ? null : () => _forget(account),
                    ),
              onTap: _busy ? null : () => _switch(account),
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add, color: AppColors.primary),
            title: const Text('Add another account'),
            onTap: _busy ? null : _add,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _switch(SavedAccount account) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    if (account.username == _auth.user?.username) {
      navigator.pop();
      return;
    }

    setState(() => _busy = true);
    try {
      await _auth.switchTo(account);
      // Whatever was stacked above the shell belongs to the account we just
      // left — a staff dog profile must not survive into a client session.
      // This closes the sheet along with it.
      navigator.popUntil((route) => route.isFirst);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error is ApiException
                ? 'Could not switch: ${error.message}'
                : 'Could not switch: $error',
          ),
          backgroundColor: AppColors.error,
        ),
      );
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(SavedAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget ${account.username}?'),
        content: const Text(
          'This device will stop remembering the account. You can sign back in '
          'with the password at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('FORGET'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _auth.removeAccount(account);
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final navigator = Navigator.of(context);
    navigator.pop();
    await navigator.push(
      MaterialPageRoute(builder: (_) => const LoginScreen(isAddingAccount: true)),
    );
  }
}
