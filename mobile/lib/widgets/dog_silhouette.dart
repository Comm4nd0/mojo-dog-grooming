import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Grid dimensions. These must stay in step with `ProblemArea.GRID_COLUMNS`
/// and `GRID_ROWS` on the server, which validates the cell references.
const int kGridColumns = 12;
const int kGridRows = 8;

/// Cell reference in the form the API stores: `r{row}c{col}`, zero-indexed.
String cellRef(int row, int col) => 'r${row}c$col';

/// A side-profile dog drawn as a path rather than an image asset.
///
/// Drawing it means the silhouette scales cleanly to any size and picks up
/// the theme colour, and there's no asset to ship or keep in sync with the
/// grid. The proportions are deliberately generic — this is a diagram for
/// marking up areas, not a portrait of any particular breed.
class DogSilhouettePainter extends CustomPainter {
  const DogSilhouettePainter({required this.color});

  final Color color;

  /// The design is drawn in a 120x80 box and scaled to fit.
  static const Size designSize = Size(120, 80);

  static Path buildPath() {
    final path = Path();

    // Body, head and legs, clockwise from the nose.
    path.moveTo(4, 32);
    path.lineTo(20, 25); // top of the muzzle
    path.quadraticBezierTo(27, 24, 29, 14); // stop and forehead
    path.quadraticBezierTo(34, 8, 43, 15); // skull
    path.quadraticBezierTo(47, 17, 52, 19); // neck into the withers
    path.lineTo(84, 19); // back
    path.quadraticBezierTo(94, 20, 97, 28); // croup
    path.lineTo(97, 44);
    path.lineTo(95, 64); // hind leg
    path.lineTo(88, 64); // hind foot
    path.lineTo(89, 44);
    path.quadraticBezierTo(70, 50, 55, 46); // belly
    path.lineTo(53, 64); // front leg
    path.lineTo(46, 64); // front foot
    path.lineTo(46, 44);
    path.quadraticBezierTo(38, 42, 34, 34); // chest
    path.quadraticBezierTo(28, 33, 22, 33); // throat and under the jaw
    path.close();

    // Ear, flopping back from the skull.
    path.moveTo(36, 13);
    path.quadraticBezierTo(45, 12, 44, 27);
    path.quadraticBezierTo(37, 24, 34, 15);
    path.close();

    // Tail, lifted off the croup.
    path.moveTo(93, 21);
    path.quadraticBezierTo(108, 17, 111, 5);
    path.quadraticBezierTo(116, 15, 99, 28);
    path.close();

    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / designSize.width;
    canvas.save();
    canvas.scale(scale, size.height / designSize.height);
    canvas.drawPath(buildPath(), Paint()..color = color..style = PaintingStyle.fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DogSilhouettePainter oldDelegate) => oldDelegate.color != color;
}

/// Tap cells over a dog silhouette to mark a problem area.
///
/// Used by staff on the dog profile and by owners on the intake form — the
/// one place an owner supplies this information.
class DogSilhouettePicker extends StatelessWidget {
  const DogSilhouettePicker({
    super.key,
    required this.selectedCells,
    required this.onChanged,
    this.readOnly = false,
    this.highlightColor,
  });

  /// Currently selected cell references, e.g. `['r3c5', 'r3c6']`.
  final Set<String> selectedCells;
  final ValueChanged<Set<String>> onChanged;
  final bool readOnly;
  final Color? highlightColor;

  void _toggle(String ref) {
    final next = Set<String>.from(selectedCells);
    if (!next.remove(ref)) next.add(ref);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final tint = highlightColor ?? AppColors.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gridLine = (isDark ? Colors.white : AppColors.ink).withValues(alpha: 0.12);

    return AspectRatio(
      aspectRatio: kGridColumns / kGridRows,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cellWidth = constraints.maxWidth / kGridColumns;
          final cellHeight = constraints.maxHeight / kGridRows;

          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: DogSilhouettePainter(
                    color: (isDark ? Colors.white : AppColors.ink).withValues(alpha: 0.22),
                  ),
                ),
              ),
              for (int row = 0; row < kGridRows; row++)
                for (int col = 0; col < kGridColumns; col++)
                  Positioned(
                    left: col * cellWidth,
                    top: row * cellHeight,
                    width: cellWidth,
                    height: cellHeight,
                    child: _Cell(
                      selected: selectedCells.contains(cellRef(row, col)),
                      gridLine: gridLine,
                      tint: tint,
                      onTap: readOnly ? null : () => _toggle(cellRef(row, col)),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.selected,
    required this.gridLine,
    required this.tint,
    this.onTap,
  });

  final bool selected;
  final Color gridLine;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // Transparent cells still need to take a tap, so the silhouette shows
      // through while the whole grid stays touchable.
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: selected ? tint.withValues(alpha: 0.42) : Colors.transparent,
          border: Border.all(
            color: selected ? tint : gridLine,
            width: selected ? 1.5 : 0.5,
          ),
        ),
      ),
    );
  }
}

/// Read-only thumbnail of a saved problem area, for list rows.
class DogSilhouetteThumbnail extends StatelessWidget {
  const DogSilhouetteThumbnail({super.key, required this.cells, this.size = 64});

  final List<String> cells;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * kGridRows / kGridColumns,
      child: DogSilhouettePicker(
        selectedCells: cells.toSet(),
        onChanged: (_) {},
        readOnly: true,
        highlightColor: AppColors.error,
      ),
    );
  }
}
