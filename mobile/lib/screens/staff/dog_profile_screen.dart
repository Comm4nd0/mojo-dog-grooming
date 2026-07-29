import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/dog_silhouette.dart';
import 'client_profile_screen.dart';
import 'dog_form_screen.dart';
import 'dog_photos_screen.dart';
import 'groom_timer_screen.dart';
import 'problem_area_editor.dart';

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
      String? due;
      if (_isStaff) {
        try {
          due = await _data.getSuggestedNextGroom(widget.dogId);
        } catch (_) {
          // A missing suggestion is not worth failing the whole screen for.
        }
      }
      if (!mounted) return;
      setState(() {
        _dog = dog;
        _photos = photos;
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
          if (_isStaff) _problemAreasSection(dog),
          _photosSection(dog),
          if (dog.client != null) _ownerSection(dog.client!),
          _notesSection(dog),
        ],
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
                ? Image.network(dog.profileImage!, fit: BoxFit.cover, width: 76, height: 76)
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
                    if (dog.ageLabel != null) InfoTag(label: dog.ageLabel!, icon: Icons.cake_outlined),
                    if (dog.sex.isNotEmpty)
                      InfoTag(label: dog.sex == 'M' ? 'Male' : 'Female'),
                    if (dog.isNeutered) const InfoTag(label: 'Neutered'),
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
                MaterialPageRoute(builder: (_) => ProblemAreaEditor(dog: dog)),
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
                      child: Image.network(
                        photo.imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: context.mojo.tint,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
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
        DetailRow(label: 'Client UID', value: client.uid),
        DetailRow(label: 'Phone', value: client.phone),
        DetailRow(label: 'Email', value: client.email),
        DetailRow(label: 'Postcode', value: client.postcode),
      ],
    );
  }

  Widget _notesSection(Dog dog) {
    final hasAny = dog.medicalNotes.isNotEmpty || dog.vet.isNotEmpty || dog.generalNotes.isNotEmpty;
    if (!hasAny) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Notes'),
        DetailRow(label: 'Medical', value: dog.medicalNotes),
        DetailRow(label: 'Vet', value: dog.vet),
        DetailRow(label: 'General', value: dog.generalNotes),
      ],
    );
  }
}
