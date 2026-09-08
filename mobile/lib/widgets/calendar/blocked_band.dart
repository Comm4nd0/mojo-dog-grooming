import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import 'timeline_layout.dart';
import 'timeline_metrics.dart';

/// Blocked-out time, drawn on the axis.
///
/// Hatched rather than filled, so it reads as "nothing goes here" rather than
/// as a booking with no name — and so a booking Jess puts on top of it (a
/// warning, never a refusal) still stands out as the solid thing. Grey, not
/// a temperament colour: the left edge of every other block on this axis
/// means a handling grade, and this is not a dog.
class BlockedBand extends StatelessWidget {
  const BlockedBand({
    super.key,
    required this.placed,
    required this.metrics,
    this.compact = false,
  });

  final PlacedBlock placed;
  final TimelineMetrics metrics;

  /// Week view: a 49dp column fits the word and nothing else.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final height = placed.height(metrics);
    final ink = context.mojo.muted;
    final block = placed.block;
    final headline = block.headline;
    final label = compact || headline.isEmpty || height < 34
        ? 'Blocked'
        : 'Blocked · $headline';

    return CustomPaint(
      painter: _HatchPainter(ink: ink),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: ink, width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
        alignment: Alignment.topLeft,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: ink,
            fontSize: compact ? 9.5 : metrics.blockFontSize,
            fontWeight: FontWeight.w600,
            letterSpacing: compact ? 0 : 0.5,
          ),
        ),
      ),
    );
  }
}

class _HatchPainter extends CustomPainter {
  const _HatchPainter({required this.ink});

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ink.withValues(alpha: 0.08));
    final line = Paint()
      ..color = ink.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    // Diagonals from the bottom-left, 10dp apart, clipped to the rect.
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    const gap = 10.0;
    for (var x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.ink != ink;
}
