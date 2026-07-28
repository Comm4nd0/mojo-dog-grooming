import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/service_locator.dart';

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
  final _email = TextEditingController();

  bool _registering = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
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
      // The app root listens to AuthService and swaps in the right shell. When
      // this screen was pushed over a session, it also has to get out of the
      // way, or it sits on top of the shell it just brought up.
      if (widget.isAddingAccount && mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } on NoConnectionException catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                      decoration: const InputDecoration(labelText: 'Username'),
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      validator: (value) =>
                          (value == null || value.trim().isEmpty) ? 'Enter your username' : null,
                    ),
                    if (_registering) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _email,
                        decoration: const InputDecoration(labelText: 'Email'),
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        validator: (value) => (value == null || !value.contains('@'))
                            ? 'Enter a valid email address'
                            : null,
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      validator: (value) => (value == null || value.length < 8)
                          ? 'Passwords are at least 8 characters'
                          : null,
                    ),
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
                              }),
                      child: Text(
                        _registering
                            ? 'I already have an account'
                            : 'New client? Create an account',
                      ),
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
      const Padding(
        padding: EdgeInsets.only(top: 10, bottom: 2),
        child: Text(
          'SIGNED IN BEFORE',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 3,
            fontWeight: FontWeight.w700,
            color: AppColors.inkSecondary,
          ),
        ),
      ),
      for (final account in accounts)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            account.isStaff ? Icons.content_cut : Icons.person_outline,
            color: AppColors.primary,
          ),
          title: Text(account.username),
          subtitle: Text(account.isStaff ? 'Staff' : 'Client'),
          trailing: const Icon(Icons.chevron_right),
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
        Text('Mojo and Co', style: AppColors.display(34)),
        const SizedBox(height: 6),
        Text(
          'DOG GROOMING',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 4,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }
}
