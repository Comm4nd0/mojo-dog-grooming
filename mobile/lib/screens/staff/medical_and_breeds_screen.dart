import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import 'breed_detail_screen.dart';
import 'medical_notes_screen.dart';

/// Jess's reference shelf: the medical dictionary and the breed standards.
///
/// Its own entry under More, at her request — *"can you move 'Medical notes'
/// out of settings and put at the top level under it's own section within
/// 'More' and call it Medical and Breed Standards?"*. Both used to live at the
/// bottom of Settings, and neither is a setting: they are what she looks
/// things up in mid-groom, and Settings is the wrong place to be standing
/// with a dog on the table.
class MedicalAndBreedsScreen extends StatelessWidget {
  const MedicalAndBreedsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Medical and Breed Standards')),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(Icons.medical_information_outlined, color: context.mojo.accent),
            title: const Text('Medical notes'),
            subtitle: const Text(
              'What an ailment means, and what it means for a groom',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MedicalNotesScreen()),
            ),
          ),
          ListTile(
            leading: Icon(Icons.list_alt_outlined, color: context.mojo.accent),
            title: const Text('Breed standards'),
            subtitle: const Text(
              'The whole record — times, prices, coat, technique',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BreedListScreen()),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Breed times and prices come from your own price list. Which size '
              'and coat band each breed was put in, and how often it needs '
              'doing, are our guess — worth a look through.',
              style: TextStyle(fontSize: 12, color: AppColors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

/// Breed reference table, editable in place.
///
/// Moved here from Settings along with the medical notes — it is the same
/// kind of thing: a reference sheet, not a switch.
class BreedListScreen extends StatefulWidget {
  const BreedListScreen({super.key});

  @override
  State<BreedListScreen> createState() => _BreedListScreenState();
}

class _BreedListScreenState extends State<BreedListScreen> {
  final _data = getIt<DataService>();
  List<Breed> _breeds = const [];
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final breeds = await _data.getBreeds();
    if (!mounted) return;
    setState(() {
      _breeds = breeds;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _breeds
        .where((b) => b.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Breeds')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Search breeds',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final breed = visible[index];
                      return ListTile(
                        title: Text(breed.name),
                        subtitle: Text(
                          '${formatDuration(breed.avgGroomMinutes)} · '
                          '${formatMoney(breed.avgPrice)} · '
                          'every ${breed.avgScheduleWeeks}w',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        // The whole standards record, not just the three
                        // numbers the old dialog edited.
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => BreedDetailScreen(breedId: breed.id),
                            ),
                          );
                          if (mounted) _load();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
