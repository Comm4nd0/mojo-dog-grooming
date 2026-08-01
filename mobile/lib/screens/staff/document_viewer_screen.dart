import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Shows a filed document.
///
/// Fetched through the API client rather than handed to the system browser:
/// the file sits behind a token-checked view, deliberately outside the
/// publicly served media directory, so a plain link would 401 — and putting
/// the token in the URL would give away the thing the gate exists to protect.
///
/// **Images only for now.** The common case by far is Jess photographing the
/// paper form with the camera, which produces a JPEG. A PDF says so plainly
/// rather than showing a blank page; viewing those in-app needs a PDF renderer
/// the project does not carry yet.
class DocumentViewerScreen extends StatefulWidget {
  const DocumentViewerScreen({super.key, required this.document});

  final DogDocument document;

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  final _data = getIt<DataService>();

  Uint8List? _bytes;
  bool _loading = true;
  Object? _error;

  bool get _isPdf =>
      widget.document.contentType.contains('pdf') ||
      widget.document.originalFilename.toLowerCase().endsWith('.pdf');

  @override
  void initState() {
    super.initState();
    if (_isPdf) {
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await _data.downloadDocument(widget.document.id);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.document.title)),
      backgroundColor: Colors.black,
      body: _body(),
    );
  }

  Widget _body() {
    if (_isPdf) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.picture_as_pdf_outlined, size: 48, color: Colors.white54),
              const SizedBox(height: 16),
              Text(
                widget.document.originalFilename,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                "PDFs can't be opened in the app yet — photograph the form "
                'instead and it will show here.',
                style: TextStyle(color: Colors.white70, fontSize: 12.5),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: ErrorRetry(error: _error!, onRetry: _load),
      );
    }
    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      child: Center(child: Image.memory(_bytes!)),
    );
  }
}

/// Opens [document] in the viewer.
Future<void> openDocument(BuildContext context, DogDocument document) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => DocumentViewerScreen(document: document)),
  );
}
