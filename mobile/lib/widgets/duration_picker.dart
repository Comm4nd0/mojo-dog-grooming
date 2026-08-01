import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/app_colors.dart';

/// Minimum a booking can be. `CupertinoTimerPicker` will happily sit on zero,
/// and a zero-length appointment is invisible in the diary.
const int kMinDurationMinutes = 5;

/// Asks for a duration on an iPhone-style wheel.
///
/// Replaces the slider that used to set a booking's length. A slider spanning
/// 15–300 minutes in 15-minute steps is 19 detents across a phone's width —
/// landing on a specific one is fiddly, and Jess asked for "like setting a
/// timer on iPhones" instead.
///
/// Returns null if dismissed.
///
/// The `CupertinoTheme` wrapper is **not** optional. `CupertinoTimerPicker`
/// colours itself from `CupertinoColors.label`, a `CupertinoDynamicColor`.
/// Inside a `MaterialApp` there is no ambient `CupertinoTheme`, so that
/// resolves against `MediaQuery.platformBrightness` — the *phone's* setting,
/// not the app's — and the wheel paints near-black text on a dark sheet for
/// anyone whose phone is light while the app is dark. Passing the Material
/// theme's brightness through fixes that, and puts the app's own typeface on
/// the wheel at the same time.
Future<int?> showDurationPicker(
  BuildContext context, {
  required int initialMinutes,
  String title = 'How long?',
}) {
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(),
    builder: (sheetContext) {
      var draft = Duration(minutes: initialMinutes.clamp(kMinDurationMinutes, 24 * 60));
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('CANCEL'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(
                      // Clamp on the way out rather than fighting the wheel:
                      // it can reach zero, and a zero-minute booking is a
                      // block with no height in the diary.
                      draft.inMinutes < kMinDurationMinutes
                          ? kMinDurationMinutes
                          : draft.inMinutes,
                    ),
                    child: const Text('DONE'),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 216,
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: theme.brightness,
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: GoogleFonts.montserrat(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                child: CupertinoTimerPicker(
                  mode: CupertinoTimerPickerMode.hm,
                  minuteInterval: 5,
                  initialTimerDuration: draft,
                  backgroundColor: theme.colorScheme.surface,
                  onTimerDurationChanged: (value) => draft = value,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// A one-tap shortcut back to a known length — the dog's usual groom, or a
/// nail trim — sitting beside the duration row.
class DurationPreset extends StatelessWidget {
  const DurationPreset({
    super.key,
    required this.label,
    required this.minutes,
    required this.onPick,
    this.selected = false,
  });

  final String label;
  final int minutes;
  final ValueChanged<int> onPick;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      backgroundColor: selected ? context.mojo.tint : null,
      onPressed: () => onPick(minutes),
    );
  }
}
