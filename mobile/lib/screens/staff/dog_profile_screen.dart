import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/contact_actions.dart';
import '../../widgets/dog_silhouette.dart';
import 'booking_form_screen.dart';
import 'client_profile_screen.dart';
import 'dog_form_screen.dart';
import 'document_viewer_screen.dart';
import 'dog_photos_screen.dart';
import 'groom_timer_screen.dart';
import 'problem_area_editor.dart';
import 'visit_record_screen.dart';

class DogProfileScreen extends StatefulWidget {
  const DogProfileScreen({super.key, required this.dogId});

  final int dogId;

  @override
  State<DogProfileScreen> createState() => _DogProfileScreenState();
}

class _DogProfileScreenState extends State<DogProfileScreen> {
  final _data = getIt<DataService>();
  final _isStaff = getIt<AuthService>().isStaff;

  Dog? _dog;
  List<DogPhoto> _photos = const [];
  List<DogDocument> _documents = const [];
  List<GroomSession> _visits = const [];
  String? _nextGroomDue;
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
      final dog = await _data.getDog(widget.dogId);
      final photos = await _data.getDogPhotos(widget.dogId);
      // Clients see only what Jess has marked visible; the server filters
      // that in the queryset, so this call is safe either way.
      var documents = const <DogDocument>[];
      try {
        documents = await _data.getDogDocuments(widget.dogId);
      } catch (_) {
        // Paperwork is a nice-to-have on this screen, not the point of it.
      }
      String? due;
      var visits = const <GroomSession>[];
      if (_isStaff) {
        try {
          due = await _data.getSuggestedNextGroom(widget.dogId);
        } catch (_) {
          // A missing suggestion is not worth failing the whole screen for.
        }
        try {
          visits = await _data.getGroomSessions(widget.dogId);
        } catch (_) {
          // Same again — the record cards are history, not the profile.
        }
      }
      if (!mounted) return;
      setState(() {
        _dog = dog;
        _photos = photos;
        _documents = documents;
        _visits = visits;
        _nextGroomDue = due;
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

  @override
  Widget build(BuildContext context) {
    final dog = _dog;
    return Scaffold(
      appBar: AppBar(
        title: Text(dog?.name ?? 'Dog'),
        actions: [
          if (_isStaff && dog != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () async {
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => DogFormScreen(dog: dog)),
                );
                if (saved == true) _load();
              },
            ),
        ],
      ),
      floatingActionButton: (_isStaff && dog != null)
          ? FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => GroomTimerScreen(dog: dog)),
                );
                if (mounted) _load();
              },
              icon: const Icon(Icons.timer_outlined),
              label: const Text('TIME A GROOM'),
            )
          : null,
      // Bottom-left, so it doesn't fight the timer FAB on the right. Booking
      // the next groom is the thing Jess reaches for straight off a dog's
      // profile, and it used to mean backing out to the diary and searching
      // for the dog again.
      bottomNavigationBar: (_isStaff && dog != null) ? _bookBar(dog) : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : _content(dog!),
    );
  }

  Widget _content(Dog dog) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          _header(dog),
          if (_isStaff) _temperamentSection(dog),
          _groomingSection(dog),
          _preferencesSection(dog),
          _healthSection(dog),
          if (_isStaff) _problemAreasSection(dog),
          _photosSection(dog),
          _documentsSection(dog),
          if (_isStaff) _visitsSection(dog),
          if (dog.client != null) _ownerSection(dog.client!),
          _notesSection(dog),
        ],
      ),
    );
  }

  /// The bar under the profile carrying "book a groom".
  ///
  /// Left-aligned with a wide gap on the right: the timer FAB floats over that
  /// corner, and a button underneath it can't be tapped.
  Widget _bookBar(Dog dog) {
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.mojo.hairline)),
          color: Theme.of(context).colorScheme.surface,
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 180, 8),
        // A Row, not an Align. `Align` without a heightFactor expands to its
        // incoming constraints, and Scaffold measures bottomNavigationBar with
        // the whole screen height available — so the bar grew to fill the
        // screen and left the profile itself zero pixels tall. The dog's
        // details vanished, silently: no exception, no overflow stripe, just
        // this button and an empty page. A Row takes its height from its child.
        child: Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.event_available_outlined, size: 18),
              label: const Text('BOOK A GROOM'),
              onPressed: () async {
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => BookingFormScreen(
                      initialDate: DateTime.now(),
                      initialDogId: dog.id,
                    ),
                  ),
                );
                if (saved == true && mounted) {
                  showSnack(context, 'Booked in.');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(Dog dog) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      color: context.mojo.tintWash,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 76,
            height: 76,
            color: context.mojo.tint,
            alignment: Alignment.center,
            child: dog.profileImage != null && dog.profileImage!.isNotEmpty
                ? MojoNetworkImage(url: dog.profileImage!, width: 76, height: 76)
                : Text(
                    dog.name.isEmpty ? '?' : dog.name.characters.first.toUpperCase(),
                    style: AppColors.display(32, color: context.mojo.onTint),
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dog.name, style: AppColors.display(28)),
                const SizedBox(height: 4),
                Text(dog.breedLabel, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (dog.ageLabel != null)
                      InfoTag(
                        // Age and the birthday together — an owner asking
                        // "when's her birthday?" shouldn't need the edit form.
                        label: '${dog.ageLabel!} · ${formatDate(dog.dateOfBirth!)}',
                        icon: Icons.cake_outlined,
                      ),
                    if (dog.sex.isNotEmpty)
                      InfoTag(label: dog.sex == 'M' ? 'Male' : 'Female'),
                    // Jess's "intact / done" tag, up by the age. Null means
                    // nobody has asked — which shows as neither, because
                    // guessing "Intact" is how a wrong answer gets written
                    // down as a fact.
                    if (dog.isNeutered == true)
                      const InfoTag(label: 'Done', icon: Icons.check),
                    if (dog.isNeutered == false)
                      InfoTag(label: 'Intact', color: AppColors.warning),
                    if (dog.colour.isNotEmpty) InfoTag(label: dog.colour),
                    if (!dog.isActive)
                      InfoTag(label: 'Inactive', color: context.mojo.muted),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _temperamentSection(Dog dog) {
    // Belt and braces: the server strips these for a client login, so a null
    // here means "not visible to me" and the section shouldn't render at all.
    if (dog.temperament == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Temperament'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              TemperamentChip(
                temperament: dog.temperament,
                label: dog.temperamentDisplay,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Not visible to the client',
                  style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
                ),
              ),
            ],
          ),
        ),
        if ((dog.temperamentNotes ?? '').isNotEmpty)
          DetailRow(label: 'Handling', value: dog.temperamentNotes),
      ],
    );
  }

  Widget _groomingSection(Dog dog) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Groom'),
        DetailRow(
          label: 'Time',
          value: '${formatDuration(dog.groomMinutes)}'
              '${dog.groomMinutesOverride == null ? ' (breed default)' : ''}',
        ),
        DetailRow(
          label: 'Price',
          value: '${formatMoney(dog.price)}'
              '${dog.priceOverride == null ? ' (breed default)' : ''}',
        ),
        DetailRow(
          label: 'Schedule',
          value: 'Every ${dog.scheduleWeeks} weeks'
              '${dog.scheduleWeeksOverride == null ? ' (breed default)' : ''}',
        ),
        if (_nextGroomDue != null)
          DetailRow(label: 'Next due', value: formatDate(DateTime.parse(_nextGroomDue!))),
        DetailRow(label: 'Microchip', value: dog.microchipNumber),
      ],
    );
  }

  Widget _preferencesSection(Dog dog) {
    final filled = dog.preferences.where((p) => p.value.trim().isNotEmpty).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Grooming preferences'),
        if (filled.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Nothing recorded yet.',
              style: TextStyle(color: context.mojo.muted, fontSize: 13),
            ),
          )
        else
          for (final pref in filled) DetailRow(label: pref.label, value: pref.value),
      ],
    );
  }

  Widget _problemAreasSection(Dog dog) {
    final areas = dog.problemAreas ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Problem areas',
          action: TextButton.icon(
            onPressed: () async {
              final changed = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => ProblemAreaEditor.forDog(dog: dog)),
              );
              if (changed == true) _load();
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('ADD'),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Not visible to the client',
            style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
          ),
        ),
        const SizedBox(height: 8),
        if (areas.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'None marked.',
              style: TextStyle(color: context.mojo.muted, fontSize: 13),
            ),
          )
        else
          for (final area in areas)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DogSilhouetteThumbnail(cells: area.gridCells),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(area.reason, style: Theme.of(context).textTheme.bodyMedium),
                        if (area.source == 'INTAKE')
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: InfoTag(label: 'From intake form'),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () async {
                      await _data.deleteProblemArea(area.id);
                      _load();
                    },
                  ),
                ],
              ),
            ),
      ],
    );
  }

  /// Scanned paperwork — the original intake form, vaccination cards.
  ///
  /// Shown to the owner as well, which is what Jess asked for. Anything she
  /// has marked private is filtered out server-side, so a client never even
  /// sees the row.
  Widget _documentsSection(Dog dog) {
    if (!_isStaff && _documents.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Paperwork',
          action: _isStaff
              ? TextButton(onPressed: () => _addDocument(dog), child: const Text('ADD'))
              : null,
        ),
        if (_documents.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Nothing filed yet. Photograph the paper form and it lives here.',
              style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
            ),
          ),
        for (final document in _documents)
          ListTile(
            leading: Icon(
              document.contentType.contains('pdf')
                  ? Icons.picture_as_pdf_outlined
                  : Icons.image_outlined,
              color: context.mojo.accent,
            ),
            title: Text(document.title),
            subtitle: Text(
              [
                document.kindDisplay,
                document.sizeLabel,
                if (_isStaff && !document.visibleToClient) 'Not shown to the owner',
              ].join(' · '),
            ),
            trailing: _isStaff
                ? IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () => _deleteDocument(document),
                  )
                : const Icon(Icons.download_outlined),
            onTap: () => openDocument(context, document),
          ),
      ],
    );
  }

  /// File a scanned document against the dog.
  ///
  /// This used to take a camera shot and send it with the service's defaults —
  /// which meant every document was filed as an intake form and shown to the
  /// owner, and the "Not shown to the owner" subtitle above could never be
  /// produced by anything. What Jess files for herself (a vet letter, a note
  /// about a bite) is not the same as the form the owner signed and should be
  /// able to read back.
  Future<void> _addDocument(Dog dog) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: sheetContext.mojo.accent),
              title: const Text('Photograph it'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: sheetContext.mojo.accent),
              title: const Text('Choose from photos'),
              subtitle: const Text('A scan already on the phone'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (picked == null || !mounted) return;

    final details = await _askDocumentDetails();
    if (details == null || !mounted) return;

    try {
      await _data.uploadDogDocument(
        dogId: dog.id,
        filePath: picked.path,
        title: details.title,
        kind: details.kind,
        visibleToClient: details.visibleToClient,
      );
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
      return;
    }
    _load();
  }

  /// Title, kind and who can see it — asked together, because the last two
  /// were previously never asked at all.
  Future<_DocumentDetails?> _askDocumentDetails() async {
    var kind = 'INTAKE_FORM';
    // Matches the server's default and the point of the feature: the owner
    // seeing their own form. Turning it off is the deliberate act.
    var visible = true;
    final title = TextEditingController(text: 'Signed intake form');

    const kinds = <String, String>{
      'INTAKE_FORM': 'Intake form',
      'VACCINATION': 'Vaccination record',
      'VET': 'Vet letter',
      'OTHER': 'Other',
    };

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('File it', style: Theme.of(sheetContext).textTheme.headlineSmall),
              const SizedBox(height: 14),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'What is it?'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: [
                  for (final entry in kinds.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (value) => setSheetState(() => kind = value ?? kind),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: visible,
                title: const Text('The owner can see this'),
                subtitle: Text(
                  visible
                      ? 'They can open and download it from their app.'
                      : 'Kept for you only.',
                  style: TextStyle(fontSize: 12, color: sheetContext.mojo.muted),
                ),
                onChanged: (value) => setSheetState(() => visible = value),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.pop(sheetContext, true),
                child: const Text('FILE IT'),
              ),
            ],
          ),
        ),
      ),
    );

    final text = title.text.trim();
    title.dispose();
    if (saved != true || text.isEmpty) return null;
    return _DocumentDetails(title: text, kind: kind, visibleToClient: visible);
  }

  Future<void> _deleteDocument(DogDocument document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${document.title}?'),
        content: const Text('The file goes with it. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('KEEP IT'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _data.deleteDogDocument(document.id);
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
      return;
    }
    _load();
  }

  Widget _photosSection(Dog dog) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Photos',
          action: TextButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DogPhotosScreen(dog: dog)),
              );
              if (mounted) _load();
            },
            child: const Text('SEE ALL'),
          ),
        ),
        if (_photos.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'No photos yet.',
              style: TextStyle(color: context.mojo.muted, fontSize: 13),
            ),
          )
        else
          SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final photo = _photos[index];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 90,
                      height: 90,
                      child: MojoNetworkImage(url: photo.imageUrl),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      formatDate(photo.takenAt),
                      style: TextStyle(fontSize: 10.5, color: context.mojo.muted),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _ownerSection(ClientRecord client) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Owner',
          action: _isStaff
              ? TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ClientProfileScreen(clientId: client.id),
                    ),
                  ),
                  child: const Text('FULL PROFILE'),
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(client.fullName, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              // Staff-only: chatty is null for a client login.
              if (client.chatty == true)
                const InfoTag(label: 'Chatty', icon: Icons.chat_bubble_outline),
            ],
          ),
        ),
        // The UID is Jess's filing reference off the paper cards. It means
        // nothing to an owner looking at their own dog, so it stays on the
        // staff side of the screen.
        if (_isStaff) DetailRow(label: 'Client UID', value: client.uid),
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
        DetailRow(label: 'Postcode', value: client.postcode),
      ],
    );
  }

  /// Jess's ongoing record cards for this dog, newest first.
  ///
  /// Staff-only — the whole endpoint is, and a client has no business reading
  /// the handling notes on it.
  Widget _visitsSection(Dog dog) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Visit records',
          action: TextButton(
            onPressed: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => VisitRecordScreen(
                    dogId: dog.id,
                    dogName: dog.name,
                    visitType: VisitType.nailsFleasTicks,
                  ),
                ),
              );
              if (saved == true) _load();
            },
            child: const Text('+ NAILS/FLEAS/TICKS'),
          ),
        ),
        if (_visits.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Nothing recorded yet.',
              style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
            ),
          )
        else
          for (final visit in _visits) _visitTile(dog, visit),
      ],
    );
  }

  Widget _visitTile(Dog dog, GroomSession visit) {
    final parts = <String>[
      formatDuration(visit.totalMinutes),
      if (!visit.isGroom && visit.nailsSummary.isNotEmpty) visit.nailsSummary,
      if (visit.mattingPlaces.isNotEmpty) 'matting: ${visit.mattingPlaces.join(', ')}',
      if (visit.shampooUsed.isNotEmpty) visit.shampooUsed,
      if (visit.temperamentObservedDisplay.isNotEmpty) visit.temperamentObservedDisplay,
    ];
    return ListTile(
      dense: true,
      leading: Icon(
        visit.isGroom ? Icons.content_cut : Icons.pets_outlined,
        size: 20,
        color: context.mojo.accent,
      ),
      title: Text(
        '${visit.isGroom ? 'Groom' : 'Nails, fleas or ticks'} · ${formatDate(visit.startedAt)}',
        style: const TextStyle(fontSize: 13.5),
      ),
      subtitle: Text(
        parts.join(' · '),
        style: TextStyle(fontSize: 11.5, color: context.mojo.muted),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () async {
        final saved = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => VisitRecordScreen(
              dogId: dog.id,
              dogName: dog.name,
              visitType: visit.visitType,
              session: visit,
            ),
          ),
        );
        if (saved == true) _load();
      },
    );
  }

  /// The health questions off the booking card, each on its own row.
  ///
  /// Separate rows rather than one "Medical" paragraph because an allergy has
  /// to be findable at a glance, which is how the paper card asks it too.
  Widget _healthSection(Dog dog) {
    final notes = dog.healthNotes;
    if (notes.isEmpty && dog.vet.isEmpty && dog.lastVetVisit.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Health'),
        for (final note in notes) DetailRow(label: note.label, value: note.value),
        DetailRow(label: 'Vet', value: dog.vet),
        DetailRow(label: 'Last vet trip', value: dog.lastVetVisit),
      ],
    );
  }

  Widget _notesSection(Dog dog) {
    final hasAny = dog.generalNotes.isNotEmpty || dog.ownerGrooming.isNotEmpty;
    if (!hasAny) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Notes'),
        DetailRow(label: 'Owner grooms', value: dog.ownerGrooming),
        DetailRow(label: 'General', value: dog.generalNotes),
      ],
    );
  }
}

/// What `_askDocumentDetails` collects. Kind and visibility were previously
/// never asked for at all — the service's defaults went out on every upload.
class _DocumentDetails {
  final String title;
  final String kind;
  final bool visibleToClient;

  const _DocumentDetails({
    required this.title,
    required this.kind,
    required this.visibleToClient,
  });
}
