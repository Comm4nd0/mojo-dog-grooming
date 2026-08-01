import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import 'appointment_block.dart';
import 'timeline_grid_painter.dart';
import 'timeline_layout.dart';
import 'timeline_metrics.dart';

/// A day, blocked out on a time axis.
///
/// Jess's words: *"have it blocked out, as booking in multiple dogs it's a bit
/// hard to continue booking without seeing the blocked out time for the clash,
/// if you could hold to 'slide' a blocked out groom up and down"*.
///
/// A `Stack` of `Positioned` blocks inside one scroll view, rather than a
/// calendar package. Every rectangle is known before layout — top and height
/// from the times, left and width from the lane packing — so `Positioned` is
/// the direct expression of it. More to the point, a package gives you
/// `onDragEnd(newTime)` as accept-or-revert, and that cannot express the one
/// rule this app is built on: show the server's warnings and let Jess move it
/// anyway.
class DayTimeline extends StatefulWidget {
  const DayTimeline({
    super.key,
    required this.day,
    required this.appointments,
    required this.metrics,
    required this.onOpen,
    required this.onCreateAt,
    required this.onMove,
    this.openMinutes,
    this.closeMinutes,
    this.isClosedDay = false,
    this.movingId,
  });

  final DateTime day;
  final List<Appointment> appointments;
  final TimelineMetrics metrics;

  final ValueChanged<Appointment> onOpen;

  /// Tapping empty space starts a booking at that time.
  final ValueChanged<DateTime> onCreateAt;

  /// Dropped after a drag. The parent runs the warning check and the PATCH,
  /// because both need a Navigator and a data service this widget has no
  /// business holding.
  final void Function(Appointment appointment, DateTime newStart) onMove;

  final int? openMinutes;
  final int? closeMinutes;
  final bool isClosedDay;

  /// Drawn at reduced opacity while its move is in flight.
  final int? movingId;

  @override
  State<DayTimeline> createState() => _DayTimelineState();
}

class _DayTimelineState extends State<DayTimeline> {
  final _scroll = ScrollController();

  int? _draggingId;
  int _dragOffsetMinutes = 0;
  Timer? _autoScroll;

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final window = dayWindowFor(
      widget.appointments,
      openMinutes: widget.openMinutes,
      closeMinutes: widget.closeMinutes,
    );
    final placed = layoutDay(widget.appointments, window);
    final metrics = widget.metrics;
    final totalHeight = window.height(metrics);

    return SingleChildScrollView(
      controller: _scroll,
      child: SizedBox(
        height: totalHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final laneWidth = constraints.maxWidth - metrics.gutterWidth;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: TimelineGridPainter(
                      window: window,
                      metrics: metrics,
                      hairline: context.mojo.hairline,
                      closedShade: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.05),
                      openMinutes: widget.openMinutes,
                      closeMinutes: widget.closeMinutes,
                      isClosedDay: widget.isClosedDay,
                    ),
                  ),
                ),
                ..._hourLabels(context, window, metrics),
                // Under the blocks, so a tap on a booking opens it rather
                // than starting a new one on top of it.
                Positioned(
                  left: metrics.gutterWidth,
                  top: 0,
                  width: laneWidth,
                  height: totalHeight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (details) => _createAt(details.localPosition.dy, window),
                  ),
                ),
                for (final item in placed)
                  _positioned(context, item, window, laneWidth, metrics),
                if (_isToday) _nowLine(context, window, metrics),
              ],
            );
          },
        ),
      ),
    );
  }

  bool get _isToday {
    final now = DateTime.now();
    return now.year == widget.day.year &&
        now.month == widget.day.month &&
        now.day == widget.day.day;
  }

  List<Widget> _hourLabels(
    BuildContext context,
    DayWindow window,
    TimelineMetrics metrics,
  ) {
    return [
      for (var minute = 0; minute < window.totalMinutes; minute += 60)
        Positioned(
          left: 0,
          top: metrics.yForMinutes(minute) + 2,
          width: metrics.gutterWidth - 6,
          child: Text(
            '${((window.startMinutes + minute) ~/ 60).toString().padLeft(2, '0')}:00',
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11, color: context.mojo.muted),
          ),
        ),
    ];
  }

  Widget _nowLine(BuildContext context, DayWindow window, TimelineMetrics metrics) {
    final now = DateTime.now();
    final minutes = now.hour * 60 + now.minute - window.startMinutes;
    if (minutes < 0 || minutes > window.totalMinutes) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: metrics.gutterWidth - 4,
      right: 0,
      top: metrics.yForMinutes(minutes),
      child: Row(
        children: [
          Container(width: 8, height: 8, color: AppColors.error),
          Expanded(child: Container(height: 1.5, color: AppColors.error)),
        ],
      ),
    );
  }

  Widget _positioned(
    BuildContext context,
    PlacedAppointment item,
    DayWindow window,
    double laneWidth,
    TimelineMetrics metrics,
  ) {
    final isDragging = _draggingId == item.appointment.id;
    final shift = isDragging ? metrics.yForMinutes(_dragOffsetMinutes) : 0.0;
    final newStart = item.appointment.startAt.add(
      Duration(minutes: _dragOffsetMinutes),
    );

    return Positioned(
      top: item.top(metrics) + shift,
      left: metrics.gutterWidth + item.left(laneWidth),
      width: item.width(laneWidth),
      child: GestureDetector(
        onTap: () => widget.onOpen(item.appointment),
        // Not LongPressDraggable: its feedback follows the finger in two
        // dimensions and cannot snap, so the block floats free and then
        // teleports on drop. Driving `top` from state keeps it on the axis
        // and lets it settle on five-minute detents as it goes.
        onLongPressStart: (_) {
          setState(() {
            _draggingId = item.appointment.id;
            _dragOffsetMinutes = 0;
          });
          HapticFeedback.mediumImpact();
        },
        onLongPressMoveUpdate: (details) {
          final raw = metrics.minutesForY(details.localOffsetFromOrigin.dy);
          final snapped = TimelineMetrics.snap(raw);
          if (snapped != _dragOffsetMinutes) {
            setState(() => _dragOffsetMinutes = snapped);
            HapticFeedback.selectionClick();
          }
          _maybeAutoScroll(details.globalPosition.dy);
        },
        onLongPressEnd: (_) {
          _autoScroll?.cancel();
          final moved = _dragOffsetMinutes;
          final appointment = item.appointment;
          setState(() {
            _draggingId = null;
            _dragOffsetMinutes = 0;
          });
          if (moved != 0) {
            widget.onMove(
              appointment,
              appointment.startAt.add(Duration(minutes: moved)),
            );
          }
        },
        child: Material(
          color: Colors.transparent,
          elevation: isDragging ? 6 : 0,
          child: AppointmentBlock(
            placed: item,
            metrics: metrics,
            dimmed: widget.movingId == item.appointment.id,
            overrideTimeLabel: isDragging ? '→ ${formatTime(newStart)}' : null,
          ),
        ),
      ),
    );
  }

  /// Nudges the scroll view when a drag reaches the edge.
  ///
  /// Without it a booking can only be moved as far as one screenful, which on
  /// a 12-hour day is about four hours.
  void _maybeAutoScroll(double globalY) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(Offset(0, globalY)).dy;
    const edge = 60.0;
    final height = box.size.height;

    double? delta;
    if (local < edge) {
      delta = -6;
    } else if (local > height - edge) {
      delta = 6;
    }

    if (delta == null) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    _autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_scroll.hasClients) return;
      final next = (_scroll.offset + delta!).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      _scroll.jumpTo(next);
    });
  }

  void _createAt(double y, DayWindow window) {
    final minutes = TimelineMetrics.snap(
      window.startMinutes + widget.metrics.minutesForY(y),
    );
    widget.onCreateAt(
      DateTime(
        widget.day.year,
        widget.day.month,
        widget.day.day,
        minutes ~/ 60,
        minutes % 60,
      ),
    );
  }
}
