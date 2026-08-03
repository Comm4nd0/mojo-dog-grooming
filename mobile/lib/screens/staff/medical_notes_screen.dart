import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Jess's medical reference: what an ailment means, and what it means for a
/// groom.
///
/// Her idea — *"if medical issue with the dog you can look up what it means or
/// if you need to take care when grooming"*.
///
/// **Everything in here is written by Jess.** Nothing is seeded and nothing is
/// generated: this is veterinary information, and an entry that merely sounds
/// right is worse than an empty table, because somebody would act on it. Every
/// entry carries a source, and one without a source is marked as such rather
/// than presented as fact.
///
/// This is *reference*, not a dog's record. A particular dog's conditions live
/// on that dog, in the health section of its profile.
class MedicalNotesScreen extends StatefulWidget {
  const MedicalNotesScreen({super.key, this.breedId, this.breedName});

  /// When set, opens filtered to one breed — reached from its standards record.
  final int? breedId;
  final String? breedName;

  @override
  State<MedicalNotesScreen> createState() => _MedicalNotesScreenState();
}

class _MedicalNotesScreenState extends State<MedicalNotesScreen> {
  final _data = getIt<DataService>();
  final _searchController = TextEditingController();

  List<MedicalNote> _notes = const [];
  String _query = '';
  String? _kind;
  bool _loading = true;
  Object? _error;

  static const _kinds = <String?, String>{
    null: 'All',
    'AILMENT': 'Conditions',
    'FIRST_AID': 'First aid',
    'GROOMING_CARE': 'Grooming care',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_notes.isEmpty) setState(() => _loading = true);
    try {
      final notes = await _data.getMedicalNotes(
        search: _query.trim().isEmpty ? null : _query.trim(),
        kind: _kind,
        breedId: widget.breedId,
      );
      if (!mounted) return;
      setState(() {
        _notes = notes;
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
        title: Text(widget.breedName == null
            ? 'Medical notes'
            : '${widget.breedName} — medical'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(108),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() => _query = value);
                    _load();
                  },
                  decoration: const InputDecoration(
                    hintText: 'Search what it means, care, first aid',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Row(
                  children: [
                    for (final entry in _kinds.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(entry.value),
                          selected: _kind == entry.key,
                          onSelected: (_) {
                            setState(() => _kind = entry.key);
                            _load();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(null),
        tooltip: 'Add a note',
        child: const Icon(Icons.add),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading && _notes.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _notes.isEmpty) {
      return ErrorRetry(error: _error!, onRetry: _load);
    }
    if (_notes.isEmpty) {
      return EmptyState(
        icon: Icons.medical_information_outlined,
        title: _query.isEmpty ? 'Nothing written up yet' : 'No matches',
        message: _query.isEmpty
            ? 'Write up what you want to be able to look up — what a condition '
                'means, what to watch for when grooming, what to do if it '
                'happens in the salon. Nothing is filled in for you: this is '
                'medical information and it should be yours, or your vet’s.'
            : 'Nothing matching “$_query”.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: _notes.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) => _row(_notes[index]),
      ),
    );
  }

  Widget _row(MedicalNote note) {
    final summary = [note.whatItMeans, note.groomingCare, note.firstAid]
        .firstWhere((text) => text.isNotEmpty, orElse: () => '');
    return ExpansionTile(
      leading: Icon(
        switch (note.kind) {
          'FIRST_AID' => Icons.emergency_outlined,
          'GROOMING_CARE' => Icons.content_cut_outlined,
          _ => Icons.medical_information_outlined,
        },
        color: context.mojo.accent,
      ),
      title: Text(note.title),
      subtitle: Text(
        note.kindDisplay,
        style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (summary.isEmpty)
          Text('Nothing written yet.',
              style: TextStyle(fontSize: 12.5, color: context.mojo.muted)),
        if (note.whatItMeans.isNotEmpty) _block('What it means', note.whatItMeans),
        if (note.groomingCare.isNotEmpty) _block('Care when grooming', note.groomingCare),
        if (note.firstAid.isNotEmpty) _block('First aid', note.firstAid),
        if (note.breedNames.isNotEmpty)
          _block('Common in', note.breedNames.join(', ')),
        const SizedBox(height: 6),
        // An unattributed entry is flagged rather than quietly presented as
        // fact. This is medical information and where it came from matters.
        Row(
          children: [
            Icon(
              note.isAttributed ? Icons.verified_outlined : Icons.help_outline,
              size: 15,
              color: note.isAttributed ? context.mojo.muted : AppColors.warning,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                note.isAttributed ? 'Source: ${note.source}' : 'No source recorded',
                style: TextStyle(
                  fontSize: 11.5,
                  color: note.isAttributed ? context.mojo.muted : AppColors.warning,
                ),
              ),
            ),
            TextButton(onPressed: () => _edit(note), child: const Text('EDIT')),
          ],
        ),
      ],
    );
  }

  Widget _block(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: context.mojo.muted,
              ),
            ),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(fontSize: 13.5)),
          ],
        ),
      );

  Future<void> _edit(MedicalNote? note) async {
    final title = TextEditingController(text: note?.title ?? '');
    final meaning = TextEditingController(text: note?.whatItMeans ?? '');
    final care = TextEditingController(text: note?.groomingCare ?? '');
    final firstAid = TextEditingController(text: note?.firstAid ?? '');
    final source = TextEditingController(text: note?.source ?? '');
    var kind = note?.kind ?? 'AILMENT';

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(note == null ? 'New note' : note.title,
                    style: Theme.of(sheetContext).textTheme.headlineSmall),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'What is it called?'),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: 'Kind'),
                  items: const [
                    DropdownMenuItem(value: 'AILMENT', child: Text('Condition or ailment')),
                    DropdownMenuItem(value: 'FIRST_AID', child: Text('First aid')),
                    DropdownMenuItem(value: 'GROOMING_CARE', child: Text('Care when grooming')),
                  ],
                  onChanged: (value) => setSheetState(() => kind = value ?? kind),
                ),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: meaning,
                  decoration: const InputDecoration(labelText: 'What it means'),
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: care,
                  decoration: const InputDecoration(labelText: 'Care when grooming'),
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: firstAid,
                  decoration: const InputDecoration(labelText: 'First aid'),
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 14),
                MojoTextField(
                  controller: source,
                  decoration: const InputDecoration(
                    labelText: 'Where this came from',
                    helperText: 'Your vet, a course, a book — so you know what it rests on',
                  ),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => Navigator.pop(sheetContext, true),
                  child: const Text('SAVE'),
                ),
                if (note != null)
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext, false),
                    child: const Text('DELETE', style: TextStyle(color: AppColors.error)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    final body = {
      'title': title.text.trim(),
      'kind': kind,
      'what_it_means': meaning.text.trim(),
      'grooming_care': care.text.trim(),
      'first_aid': firstAid.text.trim(),
      'source': source.text.trim(),
      // Keep it attached to the breed it was opened from, and to any it
      // already had. Nothing here silently unlinks a note from a breed.
      if (widget.breedId != null || note != null)
        'breeds': {
          ...?note?.breedIds,
          if (widget.breedId != null) widget.breedId!,
        }.toList(),
    };

    for (final controller in [title, meaning, care, firstAid, source]) {
      controller.dispose();
    }
    if (saved == null || !mounted) return;

    try {
      if (saved) {
        if ((body['title'] as String).isEmpty) {
          showSnack(context, 'Give it a name.', isError: true);
          return;
        }
        await _data.saveMedicalNote(body, id: note?.id);
      } else if (note != null) {
        await _data.deleteMedicalNote(note.id);
      }
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
      return;
    }
    await _load();
  }
}
