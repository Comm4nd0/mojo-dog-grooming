import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import 'timeline_layout.dart';
import 'timeline_metrics.dart';

/// One booking, drawn on the time axis.
///
/// The content adapts to the *height*, never the other way round: squeezing
/// the axis so a label fits would make the diary lie about when things are.
/// Three lines above 56dp, two above 34, and a single ellipsised line below
/// that — which is where a 20-minute nail trim lands.
class AppointmentBlock extends StatelessWidget {
  const AppointmentBlock({
    super.key,
    required this.placed,
    required this.metrics,
    this.dimmed = false,
    this.compact = false,
    this.overrideTimeLabel,
  });

  final PlacedAppointment placed;
  final TimelineMetrics metrics;

  /// Half-opacity while a move is in flight with the server.
  final bool dimmed;

  /// Week view: 49dp columns fit a name and nothing else.
  final bool compact;

  /// Shown instead of the real start time while being dragged, so the new
  /// time is visible before the finger lifts rather than after.
  final String? overrideTimeLabel;

  @override
  Widget build(BuildContext context) {
    final appointment = placed.appointment;
    final height = placed.height(metrics);
    final cancelled = appointment.isCancelled;
    // Carries the handling grade at 26dp, where a chip would not fit.
    final grade = context.temperamentColour(appointment.dogTemperament);
    final fill = cancelled ? Colors.transparent : context.mojo.tint;
    final ink = cancelled ? context.mojo.muted : context.mojo.onTint;

    return Opacity(
      opacity: dimmed ? 0.6 : 1,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: fill,
          border: Border(
            top: BorderSide(color: context.mojo.hairline),
            right: BorderSide(color: context.mojo.hairline),
            bottom: BorderSide(color: context.mojo.hairline),
            left: BorderSide(color: grade, width: 4),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
        child: DefaultTextStyle(
          style: TextStyle(
            color: ink,
            fontSize: metrics.blockFontSize,
            decoration: cancelled ? TextDecoration.lineThrough : null,
          ),
          child: ClipRect(child: _content(context, height)),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, double height) {
    final appointment = placed.appointment;
    final time = overrideTimeLabel ?? formatTime(appointment.startAt);

    if (compact || height < 34) {
      return Text(
        compact ? appointment.dogName : '$time  ${appointment.dogName}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: compact ? 9.5 : metrics.blockFontSize),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(time, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                appointment.dogName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (appointment.serviceType == ServiceType.nailsFleasTicks)
              Icon(Icons.content_cut, size: 12, color: context.mojo.onTint),
          ],
        ),
        if (height >= 56)
          Text(
            '${appointment.clientName} · ${formatDuration(appointment.durationMinutes)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: metrics.blockFontSize - 1.5),
          ),
      ],
    );
  }
}
