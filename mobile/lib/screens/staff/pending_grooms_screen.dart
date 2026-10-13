import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/searchable_picker.dart';
import 'visit_record_screen.dart';

/// A saved groom stays here until the server acknowledges its reference.
class PendingGroomsScreen extends StatelessWidget {
  const PendingGroomsScreen({super.key});

  Future<void> _changeDog(BuildContext context, GroomSession visit) async {
    final data = getIt<DataService>();
    try {
      final dogs = await data.getDogs(includeInactive: true);
      if (!context.mounted) return;
      DogSummary? selected;
      final dog = await showDialog<DogSummary>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Choose the dog for this groom'),
            content: SearchablePicker<DogSummary>(
              items: dogs,
              selected: selected,
              onSelected: (dog) => setState(() => selected = dog),
              labelOf: (dog) => dog.name,
              subtitleOf: (dog) => dog.clientFullName,
              matches: (dog, query) => dog.matchesSearch(query),
              decoration: const InputDecoration(labelText: 'Dog and owner'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('CANCEL'),
              ),
              TextButton(
                onPressed: selected == null
                    ? null
                    : () => Navigator.pop(context, selected),
                child: const Text('USE THIS DOG'),
              ),
            ],
          ),
        ),
      );
      if (dog == null) return;
      await data.revisePendingGroom(visit.clientReference!, {
        'dog': dog.id,
        'walk_in_name': '',
        'appointment': null,
      }, dogName: dog.name);
    } catch (error) {
      if (context.mounted) showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = getIt<DataService>();
    final store = data.offline;
    return Scaffold(
      appBar: AppBar(title: const Text('Saved grooms')),
      body: store == null
          ? const SizedBox.shrink()
          : ListenableBuilder(
              listenable: store,
              builder: (context, _) => PageBody(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'These grooms are kept on this device until their upload is confirmed. '
                      'Uploads retry while the app is open.',
                    ),
                    const SizedBox(height: 16),
                    if (data.pendingGrooms.isEmpty)
                      const ListTile(
                        leading: Icon(Icons.cloud_done_outlined),
                        title: Text('All saved grooms uploaded'),
                      ),
                    for (final visit in data.pendingGrooms)
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              title: Text(visit.dogName),
                              subtitle: Text(
                                '${formatDate(visit.startedAt)} · ${formatDuration(visit.totalMinutes)}\n'
                                '${visit.pendingError ?? 'Waiting to upload'}',
                              ),
                            ),
                            if (visit.pendingError != null)
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: store.syncing
                                        ? null
                                        : () => Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => VisitRecordScreen(
                                                dogId: visit.dogId,
                                                dogName: visit.dogName,
                                                session: visit,
                                                visitType: visit.visitType,
                                              ),
                                            ),
                                          ),
                                    child: const Text('EDIT GROOM CARD'),
                                  ),
                                  TextButton(
                                    onPressed: store.syncing
                                        ? null
                                        : () => _changeDog(context, visit),
                                    child: const Text('CHANGE DOG'),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    if (store.pendingCount > 0)
                      ElevatedButton(
                        onPressed: store.syncing
                            ? null
                            : () => data.syncOffline(refreshSnapshot: true),
                        child: Text(
                          store.syncing ? 'UPLOADING…' : 'RETRY UPLOADS',
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}
