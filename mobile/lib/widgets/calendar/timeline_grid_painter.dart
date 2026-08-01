import 'package:flutter/material.dart';

import 'timeline_layout.dart';
import 'timeline_metrics.dart';

/// The hour lines, the closed-hours shading and the closure wash.
///
/// Every colour is passed in from the theme rather than picked here, so the
/// grid is correct in dark mode by construction rather than by a second set
/// of constants somebody has to remember to update.
class TimelineGridPainter extends CustomPainter {
  const TimelineGridPainter({
    required this.window,
    required this.metrics,
    required this.hairline,
    required this.closedShade,
    required this.openMinutes,
    required this.closeMinutes,
    required this.isClosedDay,
    this.columnCount = 1,
  });

  final DayWindow window;
  final TimelineMetrics metrics;
  final Color hairline;

  /// Wash over the hours Jess is not normally open.
  final Color closedShade;

  /// Her hours for this weekday, in minutes past midnight. Null when she has
  /// none set for it — then the whole day is shaded rather than none of it,
  /// because "no hours" means "not normally open", not "open all hours".
  final int? openMinutes;
  final int? closeMinutes;

  /// A whole day marked closed. Shaded throughout; bookings still draw over
  /// it, because a closure is a warning and never a block.
  final bool isClosedDay;

  final int columnCount;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Paint()..color = closedShade;

    if (isClosedDay || openMinutes == null || closeMinutes == null) {
      canvas.drawRect(Offset.zero & size, shade);
    } else {
      final openY = metrics.yForMinutes(openMinutes! - window.startMinutes);
      final closeY = metrics.yForMinutes(closeMinutes! - window.startMinutes);
      if (openY > 0) {
        canvas.drawRect(Rect.fromLTRB(0, 0, size.width, openY), shade);
      }
      if (closeY < size.height) {
        canvas.drawRect(Rect.fromLTRB(0, closeY, size.width, size.height), shade);
      }
    }

    final hourPaint = Paint()
      ..color = hairline
      ..strokeWidth = 1;
    final halfHourPaint = Paint()
      ..color = hairline.withValues(alpha: 0.4)
      ..strokeWidth = 1;

    for (var minute = 0; minute <= window.totalMinutes; minute += 30) {
      final y = metrics.yForMinutes(minute);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        minute % 60 == 0 ? hourPaint : halfHourPaint,
      );
    }

    // Column separators for the week view.
    if (columnCount > 1) {
      final columnWidth = size.width / columnCount;
      for (var column = 1; column < columnCount; column++) {
        final x = column * columnWidth;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), hourPaint);
      }
    }
  }

  @override
  bool shouldRepaint(TimelineGridPainter old) =>
      old.window.startMinutes != window.startMinutes ||
      old.window.endMinutes != window.endMinutes ||
      old.metrics.scale != metrics.scale ||
      old.hairline != hairline ||
      old.closedShade != closedShade ||
      old.openMinutes != openMinutes ||
      old.closeMinutes != closeMinutes ||
      old.isClosedDay != isClosedDay ||
      old.columnCount != columnCount;
}
