import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/service_locator.dart';
import '../widgets/common.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.isAddingAccount = false});

  /// Pushed over an existing session to add a second account, rather than
  /// shown as the app root because nobody is signed in. Adds a way back out
  /// and pops itself once the new account is in.
  final bool isAddingAccount;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _email = TextEditingController();

  bool _registering = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  /// Per-field messages from the server, keyed by API field name. The old
  /// screen only ever showed the first one in a banner, so "that username is
  /// taken" appeared above a form with no indication of which box to fix.
  Map<String, List<String>> _fieldErrors = const {};

  BiometricCapability _capability = const BiometricCapability.none();

  @override
  void initState() {
    super.initState();
    _loadCapability();
  }

  Future<void> _loadCapability() async {
    final capability = await getIt<AuthService>().biometricCapability();
    if (mounted) setState(() => _capability = capability);
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _email.dispose();
    super.dispose();
  }

  String? _serverError(String field) {
    final messages = _fieldErrors[field];
    return (messages == null || messages.isEmpty) ? null : messages.join(' ');
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _fieldErrors = const {};
    });
    try {
      final auth = getIt<AuthService>();
      if (_registering) {
        await auth.register(
          username: _username.text,
          email: _email.text,
          password: _password.text,
        );
      } else {
        await auth.signIn(_username.text, _password.text);
      }
      if (!mounted) return;
      await _offerBiometrics();
      // The app root listens to AuthService and swaps in the right shell. When
      // this screen was pushed over a session, it also has to get out of the
      // way, or it sits on top of the shell it just brought up.
      if (widget.isAddingAccount && mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      setState(() {
        _error = error.message;
        _fieldErrors = error.fieldErrors;
      });
      // Re-run validation so the server's complaints land under the right
      // fields rather than only in the banner.
      _formKey.currentState!.validate();
    } on NoConnectionException catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ask, once, whether to skip the password next time.
  ///
  /// Right after a successful sign-in is the only moment this is worth
  /// offering: it is the one time the password is fresh in mind and the
  /// nuisance of typing it is what they just did. Buried in a settings screen,
  /// nobody would ever find it.
  Future<void> _offerBiometrics() async {
    final auth = getIt<AuthService>();
    if (!_capability.available || auth.biometricsEnabledHere) return;

    final wanted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Use ${_capability.label} next time?'),
        content: Text(
          'Unlock Mojo and Co with ${_capability.label} instead of typing your '
          'password. You can turn it off again from the account menu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('NOT NOW'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('TURN ON'),
          ),
        ],
      ),
    );
    if (wanted != true) return;
    await auth.setBiometricsEnabled(true);
  }

  Future<void> _askForHelp() async {
    final sent = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ForgottenPasswordSheet(initialIdentifier: _username.text.trim()),
    );
    if (sent != null && mounted) showSnack(context, sent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.isAddingAccount ? AppBar(title: const Text('Add account')) : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Wordmark(),
                    const SizedBox(height: 40),
                    Text(
                      _registering ? 'Create an account' : 'Sign in',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _username,
                      decoration: InputDecoration(
                        // Signing in accepts either, and clients type whichever
                        // they remember — saying so is the difference between
                        // getting in and giving up.
                        labelText: _registering ? 'Username' : 'Username or email',
                        helperText: _registering ? 'Letters, numbers and . @ + - _' : null,
                        errorText: _serverError('username'),
                      ),
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      autofillHints: _registering
                          ? const [AutofillHints.newUsername]
                          : const [AutofillHints.username],
                      // Phone keyboards capitalise the first letter, and the
                      // server matches case-insensitively, but a capital in a
                      // *new* username is still a surprise waiting to happen.
                      textCapitalization: TextCapitalization.none,
                      validator: (value) =>
                          (value == null || value.trim().isEmpty) ? 'Enter your username' : null,
                    ),
                    if (_registering) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _email,
                        decoration: InputDecoration(
                          labelText: 'Email',
                          helperText: 'Mojo and Co use this to reach you if you get locked out',
                          errorText: _serverError('email'),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.email],
                        validator: (value) => (value == null || !value.contains('@'))
                            ? 'Enter a valid email address'
                            : null,
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        errorText: _serverError('password'),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          tooltip: _obscure ? 'Show password' : 'Hide password',
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      obscureText: _obscure,
                      autofillHints: _registering
                          ? const [AutofillHints.newPassword]
                          : const [AutofillHints.password],
                      textInputAction:
                          _registering ? TextInputAction.next : TextInputAction.done,
                      onFieldSubmitted: _registering ? null : (_) => _submit(),
                      validator: (value) => (value == null || value.length < 8)
                          ? 'Passwords are at least 8 characters'
                          : null,
                    ),
                    if (_registering) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _confirm,
                        decoration: const InputDecoration(labelText: 'Type your password again'),
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        // A typo in a password nobody can see means an account
                        // that cannot be signed into, found out about only on
                        // the next launch.
                        validator: (value) => value != _password.text
                            ? 'Those two are different'
                            : null,
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        color: AppColors.error.withValues(alpha: 0.08),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: AppColors.error, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(color: AppColors.error, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                            )
                          : Text(_registering ? 'CREATE ACCOUNT' : 'SIGN IN'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _registering = !_registering;
                                _error = null;
                                _fieldErrors = const {};
                              }),
                      child: Text(
                        _registering
                            ? 'I already have an account'
                            : 'New client? Create an account',
                      ),
                    ),
                    if (!_registering)
                      TextButton(
                        onPressed: _busy ? null : _askForHelp,
                        child: const Text('I\'ve forgotten my password'),
                      ),
                    if (!widget.isAddingAccount) ..._savedAccounts(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Accounts still remembered after signing out of another one. Without these
  /// they would be saved but unreachable — the switcher only exists inside a
  /// session, and this screen is what you get when there isn't one.
  List<Widget> _savedAccounts() {
    final accounts = getIt<AuthService>().accounts;
    if (accounts.isEmpty) return const [];
    return [
      const SizedBox(height: 20),
      const Divider(),
      Padding(
        padding: EdgeInsets.only(top: 10, bottom: 2),
        child: Text(
          'SIGNED IN BEFORE',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 3,
            fontWeight: FontWeight.w700,
            color: context.mojo.muted,
          ),
        ),
      ),
      for (final account in accounts)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            account.isStaff ? Icons.content_cut : Icons.person_outline,
            color: context.mojo.accent,
          ),
          title: Text(account.username),
          subtitle: Text(
            account.biometricsEnabled
                ? '${account.isStaff ? 'Staff' : 'Client'} · ${_capability.label}'
                : (account.isStaff ? 'Staff' : 'Client'),
          ),
          trailing: Icon(
            account.biometricsEnabled ? Icons.fingerprint : Icons.chevron_right,
            color: account.biometricsEnabled ? context.mojo.accent : null,
          ),
          onTap: _busy ? null : () => _useSaved(account),
        ),
    ];
  }

  Future<void> _useSaved(SavedAccount account) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // switchTo raises the biometric prompt itself when the account asked for
      // one, so a locked account cannot be reached round the back this way.
      await getIt<AuthService>().switchTo(account);
      // Success disposes this screen — the root swaps the shell in.
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } on NoConnectionException catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// "I've forgotten my password", from someone who cannot sign in.
///
/// This does not reset anything and deliberately does not say whether the name
/// was recognised — the server answers the same either way, and a sheet that
/// said "no such account" would undo that. What it does is put the request in
/// front of Jess, who knows her clients by name and sends them a link.
class _ForgottenPasswordSheet extends StatefulWidget {
  const _ForgottenPasswordSheet({this.initialIdentifier = ''});

  final String initialIdentifier;

  @override
  State<_ForgottenPasswordSheet> createState() => _ForgottenPasswordSheetState();
}

class _ForgottenPasswordSheetState extends State<_ForgottenPasswordSheet> {
  late final TextEditingController _identifier =
      TextEditingController(text: widget.initialIdentifier);
  final _note = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _identifier.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_identifier.text.trim().isEmpty) {
      setState(() => _error = 'Enter the username or email you sign in with.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final message = await getIt<AuthService>().requestPasswordHelp(
        identifier: _identifier.text,
        note: _note.text,
      );
      if (mounted) Navigator.pop(context, message);
    } on ApiException catch (error) {
      setState(() {
        _error = error.statusCode == 429
            ? 'You have asked a few times already — Mojo and Co have it. '
                'Give them a ring if it is urgent.'
            : error.message;
        _busy = false;
      });
    } on NoConnectionException catch (error) {
      setState(() {
        _error = error.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Forgotten your password?',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              const Text(
                'Mojo and Co will send you a link to set a new one. There is one '
                'groomer here and she knows her clients, so this goes to her '
                'rather than out automatically.',
                style: TextStyle(fontSize: 12.5, color: AppColors.inkSecondary),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _identifier,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Username or email',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                maxLength: 300,
                decoration: const InputDecoration(
                  labelText: 'Anything that helps (optional)',
                  hintText: 'e.g. your phone number, or your dog\'s name',
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _busy ? null : _send,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                      )
                    : const Text('SEND REQUEST'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          color: AppColors.primaryBright,
          alignment: Alignment.center,
          child: const Icon(Icons.pets, size: 34, color: Colors.black),
        ),
        const SizedBox(height: 18),
        Text(
          'Mojo and Co',
          style: AppColors.display(34, color: Theme.of(context).colorScheme.onSurface),
        ),
        const SizedBox(height: 6),
        Text(
          'DOG GROOMING',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 4,
            fontWeight: FontWeight.w700,
            color: context.mojo.accent,
          ),
        ),
      ],
    );
  }
}
