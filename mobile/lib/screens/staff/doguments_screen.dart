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

  /// Off by default — the list is a working list, and a dog Jess has retired
  /// should not be in the way of the ones coming in this week.
  ///
  /// It exists at all because `getDogs(includeInactive:)` had no call site: the
  /// profile happily renders an "Inactive" tag on a dog that nothing in the app
  /// could reach, so retiring one made it disappear for good.
  bool _includeInactive = false;

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
      final dogs = await _data.getDogs(search: search, includeInactive: _includeInactive);
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
            icon: Icon(
              _includeInactive ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            ),
            tooltip: _includeInactive ? 'Hide retired dogs' : 'Show retired dogs',
            onPressed: () {
              setState(() => _includeInactive = !_includeInactive);
              _load(search: _query.trim().isEmpty ? null : _query.trim());
            },
          ),
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
                  // The dog's name is what you scan this list for, so it
                  // leads: a clear step up from the breed line under it
                  // rather than a near-match in the same weight.
                  Text(dog.name, style: AppColors.display(23, weight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(dog.breedLabel, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  // Four facts, not six. Jess found this row too busy to scan:
                  // the temperament chip and the UID have gone (both are on the
                  // profile, and neither is what she's looking for here), and
                  // the interval and groom time she asked for are what's left
                  // alongside the owner.
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _Fact(icon: Icons.person_outline, text: dog.clientFirstName),
                      _Fact(icon: Icons.repeat, text: 'every ${dog.scheduleWeeks}w'),
                      _Fact(icon: Icons.schedule, text: formatDuration(dog.groomMinutes)),
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
        child: MojoNetworkImage(
          url: url!,
          errorWidget: _initials(context),
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
  final _searchController = TextEditingController();
  Timer? _debounce;

  List<ClientRecord> _clients = const [];
  String _query = '';
  bool _loading = true;
  Object? _error;

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
    // Only blank the list when there is nothing worth keeping, so typing does
    // not replace results with a spinner on every keystroke.
    if (_clients.isEmpty) setState(() => _loading = true);
    try {
      final clients = await _data.getClients(search: search);
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

  // Same shape as the dog list next door: debounced server search, plus an
  // immediate local filter so results narrow while the request is in flight.
  // The API has always supported `search` here; nothing was calling it.
  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _load(search: value.trim().isEmpty ? null : value.trim());
    });
  }

  List<ClientRecord> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _clients;
    final digits = q.replaceAll(' ', '');
    return _clients.where((client) {
      return client.fullName.toLowerCase().contains(q) ||
          (client.uid?.toLowerCase().contains(q) ?? false) ||
          client.email.toLowerCase().contains(q) ||
          client.phone.replaceAll(' ', '').contains(digits);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clients'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Name, code, phone or email',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
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
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final saved = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const ClientFormScreen()),
          );
          if (saved == true) _load();
        },
        child: const Icon(Icons.person_add_outlined),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _clients.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    // Don't throw away a usable list because a refresh failed.
    if (_error != null && _clients.isEmpty) {
      return ErrorRetry(error: _error!, onRetry: _load);
    }

    final visible = _visible;
    if (visible.isEmpty) {
      return EmptyState(
        icon: _query.isEmpty ? Icons.people_outline : Icons.search_off,
        title: _query.isEmpty ? 'No clients yet' : 'No matches',
        message: _query.isEmpty
            ? 'Add one with the button below, or send an intake form.'
            : 'Nothing matching “$_query”.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: visible.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final client = visible[index];
          // `uid` is staff-only and so nullable. This screen is staff-only, but
          // interpolating it bare would render the literal "null" if that ever
          // stopped being true — same rule as everywhere else here.
          final parts = [
            ?client.uid,
            '${client.dogCount} dog${client.dogCount == 1 ? '' : 's'}',
            if (client.phone.isNotEmpty) client.phone,
          ];
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
            subtitle: Text(parts.join(' · ')),
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
