import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/dog_silhouette.dart';

/// Mark an area of the dog and say why.
///
/// Multiple areas can be recorded per dog — each is a separate entry with its
/// own reason, so "sore left hip" and "matted tail" don't get merged into one
/// note. Staff-only on the profile, but the same widget backs the intake form.
class ProblemAreaEditor extends StatefulWidget {
  const ProblemAreaEditor({super.key, required this.dog});

  final Dog dog;

  @override
  State<ProblemAreaEditor> createState() => _ProblemAreaEditorState();
}

class _ProblemAreaEditorState extends State<ProblemAreaEditor> {
  final _data = getIt<DataService>();
  final _reason = TextEditingController();

  Set<String> _cells = {};
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_cells.isEmpty) {
      showSnack(context, 'Tap the areas on the dog first.', isError: true);
      return;
    }
    if (_reason.text.trim().isEmpty) {
      showSnack(context, 'Say why this area is marked.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _data.createProblemArea(
        dogId: widget.dog.id,
        gridCells: _cells.toList()..sort(),
        reason: _reason.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Problem area — ${widget.dog.name}'),
        actions: [
          if (_cells.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _cells = {}),
              child: const Text('CLEAR'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Text(
            'Tap the squares covering the area. Tap again to unselect.',
            style: TextStyle(fontSize: 13, color: context.mojo.muted),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(border: Border.all(color: context.mojo.hairline)),
            child: DogSilhouettePicker(
              selectedCells: _cells,
              onChanged: (cells) => setState(() => _cells = cells),
              highlightColor: AppColors.error,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _cells.isEmpty
                ? 'Nothing selected'
                : '${_cells.length} square${_cells.length == 1 ? '' : 's'} selected',
            style: TextStyle(fontSize: 12, color: context.mojo.muted),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Why is this area marked? *',
              hintText: 'e.g. Sore hip — dislikes being lifted here',
            ),
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 28),
          ElevatedButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'SAVING…' : 'SAVE AREA'),
          ),
          const SizedBox(height: 12),
          Text(
            'Add one entry per area. Not visible to the client.',
            style: TextStyle(fontSize: 12, color: context.mojo.muted),
          ),
        ],
      ),
    );
  }
}
