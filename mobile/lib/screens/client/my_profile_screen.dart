import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/contact_actions.dart';
import '../account_switcher.dart';
import '../staff/staff_shell.dart';

/// A client's own details, editable by them, plus their invoices if Jess has
/// switched that on.
class MyProfileScreen extends StatefulWidget {
  const MyProfileScreen({super.key});

  @override
  State<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends State<MyProfileScreen> {
  final _data = getIt<DataService>();
  final _auth = getIt<AuthService>();

  ClientRecord? _client;
  List<Invoice> _invoices = const [];
  AppSettings? _settings;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final clientId = _auth.user?.clientId;
      final settings = await _data.getSettings();
      ClientRecord? client;
      if (clientId != null) client = await _data.getClient(clientId);

      // Invoices only exist for a client when Jess has made them visible;
      // the server returns an empty list otherwise.
      List<Invoice> invoices = const [];
      if (settings.invoicingVisibleToClients) {
        invoices = await _data.getInvoices();
      }

      if (!mounted) return;
      setState(() {
        _client = client;
        _settings = settings;
        _invoices = invoices;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _edit() async {
    final client = _client!;
    final phone = TextEditingController(text: client.phone);
    final email = TextEditingController(text: client.email);
    final address = TextEditingController(text: client.address);
    final postcode = TextEditingController(text: client.postcode);

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('My details', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              MojoTextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'Phone'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 14),
              MojoTextField(
                controller: email,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 14),
              MojoTextField(
                controller: address,
                decoration: const InputDecoration(labelText: 'Address'),
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 14),
              MojoTextField(
                controller: postcode,
                decoration: const InputDecoration(labelText: 'Postcode'),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('SAVE'),
              ),
            ],
          ),
        ),
      ),
    );

    if (saved == true) {
      try {
        await _data.updateClient(client.id, {
          'phone': phone.text.trim(),
          'email': email.text.trim(),
          'address': address.text.trim(),
          'postcode': postcode.text.trim(),
        });
        _load();
      } catch (error) {
        if (mounted) showSnack(context, error.toString(), isError: true);
      }
    }
    for (final controller in [phone, email, address, postcode]) {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My details'),
        actions: [
          if (_client != null)
            IconButton(icon: const Icon(Icons.edit_outlined), onPressed: _edit),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : ListView(
                  children: [
                    if (_client != null) ...[
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                        color: context.mojo.tintWash,
                        child: Text(_client!.fullName, style: AppColors.display(26)),
                      ),
                      const SectionHeader(title: 'Contact'),
                      DetailRow(label: 'Phone', value: _client!.phone),
                      DetailRow(label: 'Email', value: _client!.email),
                      DetailRow(label: 'Address', value: _client!.address),
                      DetailRow(label: 'Postcode', value: _client!.postcode),
                    ],
                    if (_settings?.invoicingVisibleToClients ?? false) ...[
                      const SectionHeader(title: 'Invoices'),
                      if (_invoices.isEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Nothing outstanding.',
                            style: TextStyle(color: context.mojo.muted, fontSize: 13),
                          ),
                        )
                      else
                        for (final invoice in _invoices)
                          ListTile(
                            title: Text(invoice.number),
                            subtitle: Text(
                              invoice.issueDate == null
                                  ? ''
                                  : formatDate(invoice.issueDate!),
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(formatMoney(invoice.total),
                                    style: const TextStyle(fontWeight: FontWeight.w700)),
                                InfoTag(
                                  label: invoice.status,
                                  color: invoice.status == 'PAID'
                                      ? AppColors.success
                                      : AppColors.warning,
                                ),
                              ],
                            ),
                          ),
                    ],
                    const SizedBox(height: 32),
                    Center(
                      child: Column(
                        children: [
                          Text(
                            _settings?.businessName ?? 'Mojo and Co',
                            style: AppColors.display(18),
                          ),
                          const SizedBox(height: 4),
                          // Tappable: this is the number a client reaches for
                          // when they want to ring the salon, so make it ring
                          // rather than making them copy it out.
                          if ((_settings?.contactPhone ?? '').isNotEmpty)
                            TextButton.icon(
                              onPressed: () =>
                                  callNumber(context, _settings!.contactPhone),
                              icon: const Icon(Icons.call_outlined, size: 16),
                              label: Text(_settings!.contactPhone),
                              style: TextButton.styleFrom(
                                foregroundColor: context.mojo.accent,
                                textStyle: const TextStyle(fontSize: 13),
                              ),
                            ),
                          if ((_settings?.contactEmail ?? '').isNotEmpty)
                            TextButton.icon(
                              onPressed: () =>
                                  emailAddress(context, _settings!.contactEmail),
                              icon: const Icon(Icons.mail_outlined, size: 16),
                              label: Text(_settings!.contactEmail),
                              style: TextButton.styleFrom(
                                foregroundColor: context.mojo.accent,
                                textStyle: const TextStyle(fontSize: 13),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
    );
  }
}
