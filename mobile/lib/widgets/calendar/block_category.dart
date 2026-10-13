import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';

const blockCategoryLabels = <String, String>{
  '': 'No category',
  'SOCIAL': 'Social',
  'KENNELS': 'Kennels',
  'IMPORTANT': 'Important',
  'SHOOT': 'Shoot',
  'DOG_CARE': 'Dog Care',
  'SHOWS': 'Shows',
};

/// Category ink on a faint hatched wash. Light pastels need darker ink in
/// light mode; the hue is kept in both themes and the words identify it too.
Color blockCategoryColour(BuildContext context, String? category) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (category) {
    'SOCIAL' => dark ? const Color(0xFFA5D66D) : const Color(0xFF42651F),
    'KENNELS' => dark ? const Color(0xFFCFACFF) : const Color(0xFF7540A5),
    'IMPORTANT' => dark ? const Color(0xFFFFA6A6) : const Color(0xFFB3261E),
    'SHOOT' => dark ? const Color(0xFFFFBE83) : const Color(0xFF944800),
    'DOG_CARE' => dark ? const Color(0xFF99D9FF) : const Color(0xFF176389),
    'SHOWS' => dark ? const Color(0xFFFFA9D6) : const Color(0xFFA13370),
    _ => context.mojo.muted,
  };
}
