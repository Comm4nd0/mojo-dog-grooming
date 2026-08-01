import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../account_switcher.dart';
import 'equipment_screen.dart';
import 'intake_review_screen.dart';
import 'invoices_screen.dart';
import 'logins_screen.dart';
import 'settings_screen.dart';
import 'staff_shell.dart';
import 'todos_screen.dart';

/// Everything that isn't the dog list or the diary.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = getIt<AuthService>().user;
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          _tile(
            context,
            icon: Icons.checklist,
            title: 'To-do',
            subtitle: 'Shampoo to order, calls to make',
            builder: (_) => const TodosScreen(),
            // The docked sheet on the calendar showed an outstanding count,
            // and that was the one thing about it that worked. Moving the list
            // here without the badge would just make it easy to forget.
            badge: DataService.outstandingTodos,
          ),
          _tile(
            context,
            icon: Icons.assignment_outlined,
            title: 'Intake forms',
            subtitle: 'Review new client submissions and profile claims',
            builder: (_) => const IntakeReviewScreen(),
          ),
          _tile(
            context,
            icon: Icons.receipt_long_outlined,
            title: 'Invoices',
            subtitle: 'Raise invoices and record payments',
            builder: (_) => const InvoicesScreen(),
          ),
          _tile(
            context,
            icon: Icons.content_cut_outlined,
            title: 'Equipment',
            subtitle: 'Blades, dryers — sharpening and PAT testing',
            builder: (_) => const EquipmentScreen(),
          ),
          _tile(
            context,
            icon: Icons.settings_outlined,
            title: 'Settings',
            subtitle: 'Opening hours, temperament limits, breeds',
            builder: (_) => const SettingsScreen(),
          ),
          // Sending a reset link takes over an account, so it sits behind
          // superuser rather than ordinary staff access. The server checks the
          // same thing — hiding the tile is presentation, not protection.
          if (user?.isSuperuser == true)
            _tile(
              context,
              icon: Icons.key_outlined,
              title: 'Logins',
              subtitle: 'Send a password reset link, see who is locked out',
              builder: (_) => const LoginsScreen(),
            ),
          const Divider(height: 32),
          ListTile(
            leading: Icon(Icons.switch_account_outlined, color: context.mojo.accent),
            title: const Text('Switch account'),
            subtitle: const Text('Check what a client sees, without signing out'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showAccountSwitcher(context),
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: AppColors.error),
            title: const Text('Sign out', style: TextStyle(color: AppColors.error)),
            subtitle: Text(user?.username ?? ''),
            onTap: () => confirmSignOut(context),
          ),
          const SizedBox(height: 24),
          Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Mojo and Co',
                style: TextStyle(
                  fontSize: 11, letterSpacing: 3, color: context.mojo.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required WidgetBuilder builder,
    ValueListenable<int>? badge,
  }) {
    return ListTile(
      leading: Icon(icon, color: context.mojo.accent),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (badge != null)
            ValueListenableBuilder<int>(
              valueListenable: badge,
              builder: (context, count, _) => count == 0
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InfoTag(label: '$count'),
                    ),
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: builder)),
    );
  }
}
