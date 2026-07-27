import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
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
            color: AppColors.surfaceTint.withValues(alpha: 0.4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(client.fullName, style: AppColors.display(26)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    InfoTag(label: client.uid, icon: Icons.tag),
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
          DetailRow(label: 'Phone', value: client.phone),
          DetailRow(label: 'Email', value: client.email),
          DetailRow(label: 'Address', value: client.address),
          DetailRow(label: 'Postcode', value: client.postcode),

          const SectionHeader(title: 'Staff flags'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Not visible to the client',
              style: TextStyle(fontSize: 11.5, color: AppColors.inkSecondary),
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
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'No dogs yet.',
                style: TextStyle(color: AppColors.inkSecondary, fontSize: 13),
              ),
            )
          else
            for (final dog in _dogs)
              ListTile(
                leading: const Icon(Icons.pets_outlined, color: AppColors.primary),
                title: Text(dog.name),
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
}
