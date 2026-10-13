import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/groom_timer_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/offline_status.dart';
import '../../widgets/searchable_picker.dart';
import 'client_form_screen.dart';
import 'dog_form_screen.dart';
import 'groom_timer_screen.dart';
import 'visit_record_screen.dart';

class WalkInsScreen extends StatefulWidget {
  const WalkInsScreen({super.key});
  @override
  State<WalkInsScreen> createState() => _WalkInsScreenState();
}

class _WalkInsScreenState extends State<WalkInsScreen> {
  final _data = getIt<DataService>();
  List<GroomSession>? _visits;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _data.getWalkIns();
      if (mounted) {
        setState(() {
          _visits = rows;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _start() async {
    final name = await promptForText(
      context,
      title: 'Name this walk-in',
      hintText: 'Dog name or a description you will recognise',
      confirmLabel: 'START GROOM',
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    final timer = getIt<GroomTimerService>();
    await timer.ready;
    final session = timer.openWalkIn(name.trim());
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            GroomTimerScreen(dogId: session.dogId, dogName: session.dogName),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _assign(GroomSession visit) async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _AssignWalkInScreen(visit: visit)),
    );
    if (done == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Walk-in grooms')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _start,
      icon: const Icon(Icons.timer_outlined),
      label: const Text('START WALK-IN'),
    ),
    body: PageBody(
      child: Column(
        children: [
          const OfflineStatus(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Time a groom before the dog has a profile. Finished walk-ins stay here until you assign them.',
            ),
          ),
          Expanded(
            child: _error != null
                ? ErrorRetry(error: _error!, onRetry: _load)
                : _visits == null
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 100),
                      children: [
                        if (_visits!.isEmpty)
                          const ListTile(
                            title: Text('No finished walk-ins waiting'),
                          ),
                        for (final visit in _visits!)
                          Card(
                            child: Column(
                              children: [
                                ListTile(
                                  title: Text(visit.dogName),
                                  subtitle: Text(
                                    '${formatDate(visit.startedAt)} · ${formatDuration(visit.bookableMinutes)}'
                                    '${visit.pendingSync ? ' · Waiting to upload' : ''}',
                                  ),
                                  onTap: visit.pendingSync
                                      ? null
                                      : () async {
                                          await Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => VisitRecordScreen(
                                                dogId: 0,
                                                dogName: visit.dogName,
                                                session: visit,
                                                visitType: visit.visitType,
                                              ),
                                            ),
                                          );
                                          if (mounted) _load();
                                        },
                                ),
                                TextButton.icon(
                                  onPressed: visit.pendingSync
                                      ? null
                                      : () => _assign(visit),
                                  icon: const Icon(Icons.pets_outlined),
                                  label: const Text('ASSIGN TO DOG'),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}

class _AssignWalkInScreen extends StatefulWidget {
  const _AssignWalkInScreen({required this.visit});
  final GroomSession visit;
  @override
  State<_AssignWalkInScreen> createState() => _AssignWalkInScreenState();
}

class _AssignWalkInScreenState extends State<_AssignWalkInScreen> {
  final _data = getIt<DataService>();
  List<DogSummary>? _dogs;
  DogSummary? _selected;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dogs = await _data.getDogs(includeInactive: true);
      if (mounted) {
        setState(() {
          _dogs = dogs;
          _selected = null;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _newProfile(bool owner) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            owner ? const ClientFormScreen() : const DogFormScreen(),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _save() async {
    final dog = _selected;
    if (dog == null) return;
    setState(() => _busy = true);
    try {
      final visit = await _data.assignWalkIn(widget.visit.id, dog.id);
      if (!mounted) return;
      reportSavedVisit(
        context,
        visit,
        saved: 'Walk-in filed against ${dog.name}.',
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, error.toString(), isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Assign ${widget.visit.dogName}')),
    body: PageBody(
      child: _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : _dogs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Choose the dog this visit belongs to. Its timings and whole groom card will go with it.',
                ),
                const SizedBox(height: 20),
                SearchablePicker<DogSummary>(
                  items: _dogs!,
                  selected: _selected,
                  onSelected: (dog) => setState(() => _selected = dog),
                  labelOf: (dog) => dog.name,
                  subtitleOf: (dog) => dog.clientFullName,
                  matches: (dog, query) => dog.matchesSearch(query),
                  decoration: const InputDecoration(labelText: 'Dog and owner'),
                ),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: _busy ? null : () => _newProfile(true),
                  child: const Text('ADD NEW OWNER'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _newProfile(false),
                  child: const Text('ADD NEW DOG'),
                ),
                const SizedBox(height: 20),
                if (_selected != null)
                  Text(
                    'File under ${_selected!.name} — ${_selected!.clientFullName}',
                  ),
                ElevatedButton(
                  onPressed: _busy || _selected == null ? null : _save,
                  child: const Text('ASSIGN VISIT'),
                ),
              ],
            ),
    ),
  );
}
