import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/contact_actions.dart';
import 'client_form_screen.dart';
import 'dog_form_screen.dart';
import 'dog_profile_screen.dart';

class ClientProfileScreen extends StatefulWidget {
  const ClientProfileScreen({super.key, required this.clientId});

  final int clientId;

  @override
  State<ClientProfileScreen> createState() => _ClientProfileScreenState();
}

class _ClientProfileScreenState extends State<ClientProfileScreen> {
  final _data = getIt<DataService>();

  ClientRecord? _client;
  List<DogSummary> _dogs = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = await _data.getClient(widget.clientId);
      final dogs = await _data.getDogs();
      if (!mounted) return;
      setState(() {
        _client = client;
        _dogs = dogs.where((dog) => dog.clientId == widget.clientId).toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(String field, bool value) async {
    await _data.updateClient(widget.clientId, {field: value});
    _load();
  }

  Future<void> _sendIntakeForm() async {
    final client = _client!;
    if (client.email.isEmpty) {
      showSnack(context, 'Add an email address for this client first.', isError: true);
      return;
    }
    try {
      final token = await _data.createIntakeInvite(email: client.email, clientId: client.id);
      if (!mounted) return;
      // Derived from the configured API base so the link always points at
      // whichever host the app is actually talking to.
      final link = '${apiBaseUrl.replaceFirst(RegExp(r'/api/?$'), '')}/intake/$token';
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Intake form link'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send this to ${client.email}. It works once and then expires.'),
              const SizedBox(height: 12),
              SelectableText(link, style: const TextStyle(fontSize: 12.5)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('DONE')),
          ],
        ),
      );
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    return Scaffold(
      appBar: AppBar(
        title: Text(client?.fullName ?? 'Client'),
        actions: [
          if (client != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => ClientFormScreen(client: client)),
                );
                if (saved == true) _load();
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : _content(client!),
    );
  }

  Widget _content(ClientRecord client) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
            color: context.mojo.tintWash,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(client.fullName, style: AppColors.display(26)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // Staff-only screen, but the field is nullable now that
                    // the server withholds it from clients.
                    if ((client.uid ?? '').isNotEmpty)
                      InfoTag(label: client.uid!, icon: Icons.tag),
                    if (client.chatty == true)
                      const InfoTag(label: 'Chatty', icon: Icons.chat_bubble_outline),
                    if (client.hasLogin)
                      const InfoTag(label: 'Has login', icon: Icons.person_outline),
                    if (client.leafletReceived == true)
                      const InfoTag(label: 'Leaflet given', icon: Icons.description_outlined),
                  ],
                ),
              ],
            ),
          ),
          const SectionHeader(title: 'Contact'),
          ContactRow(
            label: 'Phone',
            value: client.phone,
            icon: Icons.call_outlined,
            tooltip: 'Ring ${client.fullName}',
            onTap: () => callNumber(context, client.phone),
          ),
          ContactRow(
            label: 'Email',
            value: client.email,
            icon: Icons.mail_outlined,
            tooltip: 'Email ${client.fullName}',
            onTap: () => emailAddress(context, client.email),
          ),
          ContactRow(
            label: 'Address',
            value: [client.address, client.postcode]
                .where((part) => part.trim().isNotEmpty)
                .join('\n'),
            icon: Icons.map_outlined,
            tooltip: 'Open in maps',
            onTap: () => openMap(context, client.address, client.postcode),
          ),
          // Postcode on its own only when there is no address to fold it into
          // — otherwise it appears twice.
          if (client.address.trim().isEmpty)
            DetailRow(label: 'Postcode', value: client.postcode),

          const SectionHeader(title: 'In an emergency'),
          DetailRow(label: 'Contact', value: client.emergencyContactName),
          ContactRow(
            label: 'Their number',
            value: client.emergencyContactPhone,
            icon: Icons.call_outlined,
            tooltip: 'Ring ${client.emergencyContactName}',
            onTap: () => callNumber(context, client.emergencyContactPhone),
          ),
          if (client.emergencyContactName.trim().isEmpty &&
              client.emergencyContactPhone.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                'Not on file. Worth asking next time they are in.',
                style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
              ),
            ),

          _consentsSection(client),

          const SectionHeader(title: 'Staff flags'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Not visible to the client',
              style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
            ),
          ),
          SwitchListTile(
            value: client.chatty ?? false,
            onChanged: (value) => _toggle('chatty', value),
            title: const Text('Chatty'),
            subtitle: const Text('Allow extra time at drop-off and collection'),
          ),
          SwitchListTile(
            value: client.leafletReceived ?? false,
            onChanged: (value) => _toggle('leaflet_received', value),
            title: const Text('Leaflet received'),
          ),
          if ((client.notes ?? '').isNotEmpty) DetailRow(label: 'Notes', value: client.notes),

          SectionHeader(
            title: 'Dogs',
            action: TextButton.icon(
              onPressed: () async {
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => DogFormScreen(presetClientId: client.id)),
                );
                if (saved == true) _load();
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('ADD'),
            ),
          ),
          if (_dogs.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'No dogs yet.',
                style: TextStyle(color: context.mojo.muted, fontSize: 13),
              ),
            )
          else
            for (final dog in _dogs)
              ListTile(
                leading: Icon(Icons.pets_outlined, color: context.mojo.accent),
                // Raised, but not to the size used where a dogs list is the
                // whole screen — these sit under a section header on someone
                // else's profile and shouldn't out-shout the client's own name.
                title: Text(dog.name, style: AppColors.display(19, weight: FontWeight.w600)),
                subtitle: Text(
                  '${dog.breedLabel} · ${formatDuration(dog.groomMinutes)} · '
                  '${formatMoney(dog.price)}',
                ),
                trailing: TemperamentChip(
                  temperament: dog.temperament,
                  label: dog.temperamentDisplay,
                  compact: true,
                ),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => DogProfileScreen(dogId: dog.id)),
                  );
                  if (mounted) _load();
                },
              ),

          const SectionHeader(title: 'Intake'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: OutlinedButton.icon(
              onPressed: _sendIntakeForm,
              icon: const Icon(Icons.mail_outline, size: 18),
              label: const Text('CREATE INTAKE FORM LINK'),
            ),
          ),
        ],
      ),
    );
  }

  /// What this client agreed to on their booking form, and when.
  ///
  /// Read-only on purpose: a consent is a record of what somebody signed on a
  /// particular day, and something Jess could edit afterwards would be worth
  /// nothing. Changing an answer means asking again.
  Widget _consentsSection(ClientRecord client) {
    if (client.consents.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Agreed terms'),
        for (final consent in client.consents)
          ListTile(
            dense: true,
            leading: Icon(
              consent.agreed ? Icons.check_circle_outline : Icons.cancel_outlined,
              size: 20,
              color: consent.agreed ? context.mojo.accent : context.mojo.muted,
            ),
            title: Text(consent.kindDisplay, style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(
              consent.signedAt == null
                  ? consent.signedName
                  : '${consent.signedName} · ${formatDate(consent.signedAt!)}',
              style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
            ),
          ),
      ],
    );
  }
}
