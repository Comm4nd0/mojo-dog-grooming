import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../staff/dog_profile_screen.dart';
import '../staff/staff_shell.dart';
import 'claim_profile_screen.dart';
import 'my_bookings_screen.dart';
import 'my_profile_screen.dart';

/// The client's app: their dogs, their bookings, their details.
///
/// A signed-up client with no linked record can't see anything yet, so they
/// land on the claim flow instead of an empty shell.
class ClientShell extends StatefulWidget {
  const ClientShell({super.key});

  @override
  State<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<ClientShell> {
  final _auth = getIt<AuthService>();
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    if (_auth.user?.needsToClaimProfile ?? false) {
      return const ClaimProfileScreen();
    }
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          _MyDogsScreen(),
          MyBookingsScreen(),
          MyProfileScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.pets_outlined),
            selectedIcon: Icon(Icons.pets),
            label: 'My dogs',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_outlined),
            selectedIcon: Icon(Icons.event),
            label: 'Bookings',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Me',
          ),
        ],
      ),
    );
  }
}

class _MyDogsScreen extends StatefulWidget {
  const _MyDogsScreen();

  @override
  State<_MyDogsScreen> createState() => _MyDogsScreenState();
}

class _MyDogsScreenState extends State<_MyDogsScreen> {
  final _data = getIt<DataService>();
  List<DogSummary> _dogs = const [];
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
      final dogs = await _data.getDogs();
      if (!mounted) return;
      setState(() {
        _dogs = dogs;
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
      appBar: AppBar(
        title: const Text('My dogs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => confirmSignOut(context),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : _dogs.isEmpty
                  ? const EmptyState(
                      icon: Icons.pets_outlined,
                      title: 'No dogs yet',
                      message: 'Once Mojo and Co have added your dogs, they will appear here.',
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _dogs.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final dog = _dogs[index];
                          return ListTile(
                            leading: Container(
                              width: 48,
                              height: 48,
                              color: context.mojo.tint,
                              alignment: Alignment.center,
                              child: Text(
                                dog.name.isEmpty
                                    ? '?'
                                    : dog.name.characters.first.toUpperCase(),
                                style: AppColors.display(20, color: context.mojo.onTint),
                              ),
                            ),
                            title: Text(dog.name),
                            subtitle: Text(
                              '${dog.breedLabel} · '
                              'groom every ${dog.scheduleWeeks} weeks',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => DogProfileScreen(dogId: dog.id),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
