import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Monday-first weekday names, indexed the way the server numbers them.
///
/// **0 is Monday**, matching `WEEKDAY_CHOICES` in `api/models.py` and Python's
/// `date.weekday()`. Dart's own `DateTime.weekday` is 1-based with Monday at 1,
/// so never pass one straight into this list — that is off by one and lands on
/// the wrong day silently.
const List<String> kWeekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Pick which days of the week something happens on.
///
/// Written for Jess's *"be able to put what days they're in"* — daycare days
/// on a dog. Chips rather than seven switches, because the whole week has to
/// be readable at a glance to be worth anything.
///
/// Emits the same shape the API takes: weekday numbers, 0 = Monday. Sorting is
/// the server's job; this hands back a set.
class WeekdayPicker extends StatelessWidget {
  const WeekdayPicker({
    super.key,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final accent = context.mojo.accent;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var day = 0; day < kWeekdayNames.length; day++)
          ChoiceChip(
            // Three letters: seven full names wrap to four rows on a phone.
            label: Text(kWeekdayNames[day].substring(0, 3)),
            selected: selected.contains(day),
            showCheckmark: false,
            backgroundColor: Colors.transparent,
            selectedColor: context.mojo.tint,
            side: BorderSide(
              color: selected.contains(day) ? accent : context.mojo.hairline,
            ),
            labelStyle: TextStyle(
              color: selected.contains(day) ? context.mojo.onTint : null,
              fontSize: 13,
              fontWeight: selected.contains(day) ? FontWeight.w700 : FontWeight.w500,
            ),
            onSelected: enabled
                ? (isOn) {
                    final next = {...selected};
                    if (isOn) {
                      next.add(day);
                    } else {
                      next.remove(day);
                    }
                    onChanged(next);
                  }
                : null,
          ),
      ],
    );
  }
}
