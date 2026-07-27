import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Groom photos for one dog, newest first and grouped by date.
class DogPhotosScreen extends StatefulWidget {
  const DogPhotosScreen({super.key, required this.dog});

  final Dog dog;

  @override
  State<DogPhotosScreen> createState() => _DogPhotosScreenState();
}

class _DogPhotosScreenState extends State<DogPhotosScreen> {
  final _data = getIt<DataService>();
  final _isStaff = getIt<AuthService>().isStaff;
  final _picker = ImagePicker();

  List<DogPhoto> _photos = const [];
  bool _loading = true;
  bool _uploading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final photos = await _data.getDogPhotos(widget.dog.id);
      if (!mounted) return;
      setState(() {
        _photos = photos;
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

  Future<void> _add(ImageSource source) async {
    final file = await _picker.pickImage(
      source: source,
      // Groom photos are for reference, not print — capping the size keeps
      // uploads quick on salon wifi and the server's disk manageable.
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (file == null) return;

    setState(() => _uploading = true);
    try {
      await _data.uploadDogPhoto(dogId: widget.dog.id, filePath: file.path);
      await _load();
      if (mounted) showSnack(context, 'Photo added.');
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: AppColors.primary),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: AppColors.primary),
              title: const Text('Choose from library'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source != null) _add(source);
  }

  /// Group by calendar day so the grid reads as a timeline of grooms.
  Map<String, List<DogPhoto>> get _grouped {
    final groups = <String, List<DogPhoto>>{};
    for (final photo in _photos) {
      groups.putIfAbsent(formatDate(photo.takenAt), () => []).add(photo);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.dog.name} — photos')),
      floatingActionButton: _isStaff
          ? FloatingActionButton(
              onPressed: _uploading ? null : _pickSource,
              child: _uploading
                  ? const SizedBox(
                      height: 20, width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.add_a_photo_outlined),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : _photos.isEmpty
                  ? EmptyState(
                      icon: Icons.photo_camera_outlined,
                      title: 'No photos yet',
                      message: _isStaff
                          ? 'Take a photo after a groom to build up a history.'
                          : 'Photos from grooms will appear here.',
                      action: _isStaff
                          ? ElevatedButton(
                              onPressed: _pickSource, child: const Text('ADD A PHOTO'))
                          : null,
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 88),
                        children: [
                          for (final entry in _grouped.entries) ...[
                            SectionHeader(title: entry.key),
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 6,
                                crossAxisSpacing: 6,
                              ),
                              itemCount: entry.value.length,
                              itemBuilder: (context, index) {
                                final photo = entry.value[index];
                                return GestureDetector(
                                  onTap: () => _openFullscreen(photo),
                                  onLongPress:
                                      _isStaff ? () => _confirmDelete(photo) : null,
                                  child: Image.network(
                                    photo.imageUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      color: AppColors.surfaceTint,
                                      child: const Icon(Icons.broken_image_outlined),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
    );
  }

  void _openFullscreen(DogPhoto photo) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(formatDate(photo.takenAt))),
          backgroundColor: Colors.black,
          body: Center(
            child: InteractiveViewer(
              child: Image.network(photo.imageUrl, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(DogPhoto photo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this photo?'),
        content: Text('Taken ${formatDate(photo.takenAt)}. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DELETE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _data.deleteDogPhoto(photo.id);
    _load();
  }
}
