import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import 'appointment_block.dart';
import 'timeline_grid_painter.dart';
import 'timeline_layout.dart';
import 'timeline_metrics.dart';

/// Seven days on one time axis, Monday first.
///
/// Read and tap-through, **not** drag. At roughly 49dp a column a two-axis
/// gesture is a coin flip between "move to Tuesday" and "move thirty
/// minutes", and Jess's own framing splits them — the week is to see, the day
/// is to slide. Long-pressing here jumps to that day's view, where dragging
/// works properly.
class WeekTimeline extends StatelessWidget {
  const WeekTimeline({
    super.key,
    required this.weekStart,
    required this.appointmentsByDay,
    required this.metrics,
    required this.onOpen,
    required this.onOpenDay,
    this.hoursByWeekday = const {},
  });

  /// The Monday.
  final DateTime weekStart;

  /// Keyed by `DateTime.utc(y, m, d)`, as the calendar screen groups them.
  final Map<DateTime, List<Appointment>> appointmentsByDay;

  final TimelineMetrics metrics;
  final ValueChanged<Appointment> onOpen;
  final ValueChanged<DateTime> onOpenDay;

  /// Weekday index (Monday 1) to open/close minutes. Missing means closed.
  final Map<int, (int, int)> hoursByWeekday;

  List<DateTime> get _days =>
      [for (var i = 0; i < 7; i++) weekStart.add(Duration(days: i))];

  @override
  Widget build(BuildContext context) {
    final everything = [
      for (final day in _days) ...?appointmentsByDay[_key(day)],
    ];
    final window = dayWindowFor(everything);
    final totalHeight = window.height(metrics);

    return Column(
      children: [
        _header(context),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            child: SizedBox(
              height: totalHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final laneWidth =
                      (constraints.maxWidth - metrics.gutterWidth) / 7;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        left: metrics.gutterWidth,
                        child: CustomPaint(
                          painter: TimelineGridPainter(
                            window: window,
                            metrics: metrics,
                            hairline: context.mojo.hairline,
                            closedShade: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.05),
                            // Shading per-column would need a painter per day;
                            // at week scale the hour lines carry it.
                            openMinutes: window.startMinutes,
                            closeMinutes: window.endMinutes,
                            isClosedDay: false,
                            columnCount: 7,
                          ),
                        ),
                      ),
                      for (var minute = 0;
                          minute < window.totalMinutes;
                          minute += 60)
                        Positioned(
                          left: 0,
                          top: metrics.yForMinutes(minute) + 2,
                          width: metrics.gutterWidth - 6,
                          child: Text(
                            '${((window.startMinutes + minute) ~/ 60).toString().padLeft(2, '0')}:00',
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 10, color: context.mojo.muted),
                          ),
                        ),
                      for (var index = 0; index < 7; index++)
                        ..._blocksFor(context, index, window, laneWidth),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _blocksFor(
    BuildContext context,
    int index,
    DayWindow window,
    double laneWidth,
  ) {
    final day = _days[index];
    final placed = layoutDay(appointmentsByDay[_key(day)] ?? const [], window);
    return [
      for (final item in placed)
        Positioned(
          top: item.top(metrics),
          left: metrics.gutterWidth + index * laneWidth + item.left(laneWidth),
          width: item.width(laneWidth),
          child: GestureDetector(
            onTap: () => onOpen(item.appointment),
            onLongPress: () => onOpenDay(day),
            child: AppointmentBlock(
              placed: item,
              metrics: metrics,
              compact: true,
            ),
          ),
        ),
    ];
  }

  Widget _header(BuildContext context) {
    final today = DateTime.now();
    return Row(
      children: [
        SizedBox(width: metrics.gutterWidth),
        for (final day in _days)
          Expanded(
            child: InkWell(
              onTap: () => onOpenDay(day),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                color: _isSameDay(day, today) ? context.mojo.tint : null,
                child: Column(
                  children: [
                    Text(
                      _weekdayLabel(day.weekday),
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 0.5,
                        color: _isSameDay(day, today)
                            ? context.mojo.onTint
                            : context.mojo.muted,
                      ),
                    ),
                    Text(
                      '${day.day}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _isSameDay(day, today)
                            ? context.mojo.onTint
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static DateTime _key(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  static String _weekdayLabel(int weekday) =>
      const ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'][weekday - 1];

  /// Kept for callers that want the one-letter form.
  static String weekdayInitial(int weekday) => _weekdayLabel(weekday)[0];
}
