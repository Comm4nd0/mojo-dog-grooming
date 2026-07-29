import 'dart:async';

import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import 'client_form_screen.dart';
import 'client_profile_screen.dart';
import 'dog_form_screen.dart';
import 'dog_profile_screen.dart';

/// The Doguments list: every dog, with a whole-profile summary per row.
///
/// Search covers dog name, owner name, client UID and phone number. It filters
/// the loaded list immediately and re-queries the server after a short pause,
/// so typing stays responsive on a long list without hammering the API.
class DogumentsScreen extends StatefulWidget {
  const DogumentsScreen({super.key});

  @override
  State<DogumentsScreen> createState() => _DogumentsScreenState();
}

class _DogumentsScreenState extends State<DogumentsScreen> {
  final _data = getIt<DataService>();
  final _searchController = TextEditingController();

  List<DogSummary> _dogs = const [];
  String _query = '';
  bool _loading = true;
  Object? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({String? search}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dogs = await _data.getDogs(search: search);
      if (!mounted) return;
      setState(() {
        _dogs = dogs;
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

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _load(search: value.trim().isEmpty ? null : value.trim());
    });
  }

  /// Client-side filter so results narrow while the server query is in flight.
  List<DogSummary> get _visible =>
      _dogs.where((dog) => dog.matchesSearch(_query)).toList();

  Future<void> _openQuickActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.person_add_outlined, color: context.mojo.accent),
              title: const Text('Add client'),
              subtitle: const Text('A new owner, with or without a login'),
              onTap: () => Navigator.pop(context, 'client'),
            ),
            ListTile(
              leading: Icon(Icons.pets_outlined, color: context.mojo.accent),
              title: const Text('Add dog'),
              subtitle: const Text('A new dog against an existing client'),
              onTap: () => Navigator.pop(context, 'dog'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => action == 'client' ? const ClientFormScreen() : const DogFormScreen(),
      ),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Doguments'),
        actions: [
          IconButton(
            icon: const Icon(Icons.people_outline),
            tooltip: 'Clients',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const _ClientListScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openQuickActions,
        tooltip: 'Quick actions',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Dog, owner or phone number',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      ),
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _dogs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _dogs.isEmpty) {
      return ErrorRetry(error: _error!, onRetry: _load);
    }

    final visible = _visible;
    if (visible.isEmpty) {
      return EmptyState(
        icon: _query.isEmpty ? Icons.pets_outlined : Icons.search_off,
        title: _query.isEmpty ? 'No dogs yet' : 'No matches',
        message: _query.isEmpty
            ? 'Add a client, then add their dog.'
            : 'Nothing matches “$_query”.',
        action: _query.isEmpty
            ? ElevatedButton(onPressed: _openQuickActions, child: const Text('ADD A CLIENT'))
            : null,
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(search: _query.trim().isEmpty ? null : _query.trim()),
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) => _DogRow(
          dog: visible[index],
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => DogProfileScreen(dogId: visible[index].id)),
            );
            if (mounted) _load(search: _query.trim().isEmpty ? null : _query.trim());
          },
        ),
      ),
    );
  }
}

/// One Doguments row: the dog's whole profile at a glance.
class _DogRow extends StatelessWidget {
  const _DogRow({required this.dog, required this.onTap});

  final DogSummary dog;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(url: dog.profileImage, name: dog.name),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        // The dog's name is what you scan this list for, so it
                        // leads: a clear step up from the breed line under it
                        // rather than a near-match in the same weight.
                        child: Text(dog.name, style: AppColors.display(23, weight: FontWeight.w600)),
                      ),
                      // Null for a client login; the chip renders nothing.
                      TemperamentChip(
                        temperament: dog.temperament,
                        label: dog.temperamentDisplay,
                        compact: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(dog.breedLabel, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _Fact(icon: Icons.person_outline, text: dog.clientFirstName),
                      _Fact(icon: Icons.tag, text: dog.clientUid),
                      _Fact(icon: Icons.schedule, text: formatDuration(dog.groomMinutes)),
                      _Fact(icon: Icons.payments_outlined, text: formatMoney(dog.price)),
                      _Fact(icon: Icons.repeat, text: 'every ${dog.scheduleWeeks}w'),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: context.mojo.muted),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: context.mojo.muted),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(fontSize: 12, color: context.mojo.muted),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    if (url != null && url!.isNotEmpty) {
      return SizedBox(
        width: 52,
        height: 52,
        child: Image.network(
          url!,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _initials(context),
        ),
      );
    }
    return _initials(context);
  }

  Widget _initials(BuildContext context) => Container(
        width: 52,
        height: 52,
        color: context.mojo.tint,
        alignment: Alignment.center,
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: AppColors.display(22, color: context.mojo.onTint),
        ),
      );
}

/// Full client list, reached from the Doguments app bar.
class _ClientListScreen extends StatefulWidget {
  const _ClientListScreen();

  @override
  State<_ClientListScreen> createState() => _ClientListScreenState();
}

class _ClientListScreenState extends State<_ClientListScreen> {
  final _data = getIt<DataService>();
  List<ClientRecord> _clients = const [];
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
      final clients = await _data.getClients();
      if (!mounted) return;
      setState(() {
        _clients = clients;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Clients')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final saved = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const ClientFormScreen()),
          );
          if (saved == true) _load();
        },
        child: const Icon(Icons.person_add_outlined),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : ListView.separated(
                  itemCount: _clients.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final client = _clients[index];
                    return ListTile(
                      title: Row(
                        children: [
                          Flexible(child: Text(client.fullName)),
                          if (client.chatty == true) ...[
                            const SizedBox(width: 8),
                            const InfoTag(label: 'Chatty', icon: Icons.chat_bubble_outline),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        '${client.uid} · ${client.dogCount} dog'
                        '${client.dogCount == 1 ? '' : 's'}'
                        '${client.phone.isEmpty ? '' : ' · ${client.phone}'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ClientProfileScreen(clientId: client.id),
                          ),
                        );
                        if (mounted) _load();
                      },
                    );
                  },
                ),
    );
  }
}
