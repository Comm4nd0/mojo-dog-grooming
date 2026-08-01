import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/models.dart';

/// Pick a handling grade.
///
/// Wrapped chips rather than a `SegmentedButton`. There were three grades and
/// now there are five, which will not fit a phone's width in one row — and
/// Jess can rename them, so the widest label is not something this widget gets
/// to know in advance. A `Wrap` copes with both.
///
/// Each chip carries its own grade colour, so the ramp from easy to feisty is
/// visible while choosing rather than only afterwards on the badge.
///
/// [grades] comes from the server. Until it arrives the picker falls back to
/// the seed wording via [TemperamentChipLabels], so the form is usable on a
/// cold start rather than showing five blanks.
class TemperamentPicker extends StatelessWidget {
  const TemperamentPicker({
    super.key,
    required this.grades,
    required this.selected,
    required this.onSelected,
    this.includeUnset = false,
    this.unsetLabel = 'Not recorded',
  });

  final List<TemperamentGrade> grades;
  final String? selected;
  final ValueChanged<String?> onSelected;

  /// Adds a "not recorded" chip. On for the visit record, where leaving the
  /// observed temperament blank is a real answer; off on the dog form, where
  /// every dog has a grade.
  final bool includeUnset;
  final String unsetLabel;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (includeUnset)
          _chip(
            context,
            code: null,
            label: unsetLabel,
            colour: context.mojo.muted,
          ),
        for (final grade in grades)
          _chip(
            context,
            code: grade.code,
            label: grade.label,
            colour: context.temperamentColour(grade.code),
          ),
      ],
    );
  }

  Widget _chip(
    BuildContext context, {
    required String? code,
    required String label,
    required Color colour,
  }) {
    final isSelected = selected == code || (code == null && (selected ?? '').isEmpty);
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      showCheckmark: false,
      backgroundColor: Colors.transparent,
      selectedColor: colour.withValues(alpha: 0.14),
      side: BorderSide(color: colour.withValues(alpha: isSelected ? 0.9 : 0.35)),
      labelStyle: TextStyle(
        color: colour,
        fontSize: 13,
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
      ),
      onSelected: (_) => onSelected(code),
    );
  }
}

/// The seed wording, for the moment before the server's labels arrive.
///
/// Deliberately not a source of truth: anything rendering a grade for real
/// should be using [TemperamentGrade.label] or the server's
/// `temperament_display`.
class TemperamentChipLabels {
  TemperamentChipLabels._();

  static const List<TemperamentGrade> fallback = [
    TemperamentGrade(id: -1, code: 'EASY', label: 'Easy', maxPerDay: null, sortOrder: 1),
    TemperamentGrade(
      id: -2, code: 'WRIGGLY', label: 'Wriggly, but fine', maxPerDay: null, sortOrder: 2,
    ),
    TemperamentGrade(id: -3, code: 'FIDGETY', label: 'Fidgety', maxPerDay: null, sortOrder: 3),
    TemperamentGrade(
      id: -4, code: 'BITEY', label: 'Bitey, not hard', maxPerDay: null, sortOrder: 4,
    ),
    TemperamentGrade(
      id: -5, code: 'FEISTY', label: 'Feisty / hard', maxPerDay: null, sortOrder: 5,
    ),
  ];
}
