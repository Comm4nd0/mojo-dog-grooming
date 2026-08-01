import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../account_switcher.dart';
import '../staff/staff_shell.dart';

/// Where a newly signed-up client lands.
///
/// They give their name, email and postcode; Jess confirms the match before
/// anything is linked. Nothing is granted automatically — approving a claim
/// hands over that client's dogs, bookings and history.
class ClaimProfileScreen extends StatefulWidget {
  const ClaimProfileScreen({super.key});

  @override
  State<ClaimProfileScreen> createState() => _ClaimProfileScreenState();
}

class _ClaimProfileScreenState extends State<ClaimProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _data = getIt<DataService>();
  final _auth = getIt<AuthService>();

  final _name = TextEditingController();
  final _email = TextEditingController();
  final _postcode = TextEditingController();

  bool _busy = false;
  bool _submitted = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _email.text = _auth.user?.email ?? '';
    _checkExisting();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _postcode.dispose();
    super.dispose();
  }

  /// A claim already lodged shouldn't show an empty form again.
  Future<void> _checkExisting() async {
    try {
      final claims = await _data.getClaimRequests();
      if (!mounted) return;
      setState(() {
        _submitted = claims.any((claim) => claim.status == 'PENDING');
        _checking = false;
      });
    } catch (_) {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await _data.submitClaim(
        name: _name.text.trim(),
        email: _email.text.trim(),
        postcode: _postcode.text.trim(),
      );
      if (mounted) setState(() => _submitted = true);
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link your profile'),
        actions: [
          // A client login with no linked record can go nowhere else, so the
          // way back to a staff account has to be reachable from here too.
          IconButton(
            icon: const Icon(Icons.switch_account_outlined),
            tooltip: 'Switch account',
            onPressed: () => showAccountSwitcher(context),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => confirmSignOut(context),
          ),
        ],
      ),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : _submitted
              ? _waiting()
              : _form(),
    );
  }

  Widget _waiting() {
    return EmptyState(
      icon: Icons.hourglass_empty,
      title: 'Request sent',
      message: 'Mojo and Co will check your details and set your account up. '
          'You will see your dogs and bookings here once they do.',
      action: OutlinedButton(
        onPressed: () async {
          await _auth.refreshUser();
          if (mounted) setState(() {});
        },
        child: const Text('CHECK AGAIN'),
      ),
    );
  }

  Widget _form() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        children: [
          Text('Almost there', style: AppColors.display(26)),
          const SizedBox(height: 10),
          // Not everyone who lands here is on file — someone can sign up
          // without Jess having entered them, and telling them a record exists
          // when it doesn't reads as a mistake on their first screen.
          const Text(
            'Send Mojo and Co your details. If they already hold a record for '
            'you it will be linked to this account; if not, they will set one '
            'up for you.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 28),
          MojoTextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Your full name *'),
            textCapitalization: TextCapitalization.words,
            validator: (value) =>
                (value == null || value.trim().isEmpty) ? 'Enter your name' : null,
          ),
          const SizedBox(height: 14),
          MojoTextField(
            controller: _email,
            decoration: const InputDecoration(labelText: 'Email *'),
            keyboardType: TextInputType.emailAddress,
            validator: (value) =>
                (value == null || !value.contains('@')) ? 'Enter a valid email' : null,
          ),
          const SizedBox(height: 14),
          MojoTextField(
            controller: _postcode,
            decoration: const InputDecoration(labelText: 'Postcode *'),
            textCapitalization: TextCapitalization.characters,
            validator: (value) =>
                (value == null || value.trim().isEmpty) ? 'Enter your postcode' : null,
          ),
          const SizedBox(height: 28),
          ElevatedButton(
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'SENDING…' : 'REQUEST ACCESS'),
          ),
          const SizedBox(height: 16),
          Text(
            'Your request is checked by Mojo and Co before anything is shared.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.mojo.muted),
          ),
        ],
      ),
    );
  }
}
