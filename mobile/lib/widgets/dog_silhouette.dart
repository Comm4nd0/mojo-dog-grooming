import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../constants/app_colors.dart';

/// Grid dimensions. These must stay in step with `ProblemArea.GRID_COLUMNS`
/// and `GRID_ROWS` on the server, which validates the cell references. There
/// is a test asserting the values, and changing them would invalidate every
/// problem area already recorded.
const int kGridColumns = 12;
const int kGridRows = 8;

/// Aspect ratio of the silhouette artwork (its viewBox is 2605 x 1661.7).
///
/// The grid is laid over the whole frame, so cells come out at roughly 1.05:1
/// — near enough square to tap accurately, while the dog still fills the width
/// rather than sitting letterboxed inside a 3:2 box.
const double kSilhouetteAspect = 2605 / 1661.7;

const String kSilhouetteAsset = 'assets/dog_silhouette.svg';

/// Cell reference in the form the API stores: `r{row}c{col}`, zero-indexed
/// from the top-left.
String cellRef(int row, int col) => 'r${row}c$col';

/// Tap cells over a dog silhouette to mark a problem area.
///
/// Used by staff on the dog profile and by owners on the intake form — the one
/// place an owner supplies this information.
///
/// The silhouette is a side-on standing dog facing left, so the grid reads
/// roughly: head and muzzle in columns 0-2, barrel and back 3-8, hindquarters
/// and tail 9-11, legs and feet in rows 4-7.
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
    final ink = isDark ? Colors.white : AppColors.ink;
    final gridLine = ink.withValues(alpha: 0.12);

    return AspectRatio(
      aspectRatio: kSilhouetteAspect,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cellWidth = constraints.maxWidth / kGridColumns;
          final cellHeight = constraints.maxHeight / kGridRows;

          return Stack(
            children: [
              Positioned.fill(
                child: SvgPicture.asset(
                  kSilhouetteAsset,
                  fit: BoxFit.fill,
                  // Kept faint so the grid lines and any selected cells stay
                  // the dominant marks — this is a diagram to annotate, not an
                  // illustration to admire.
                  colorFilter: ColorFilter.mode(
                    ink.withValues(alpha: 0.25),
                    BlendMode.srcIn,
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

  /// Width in logical pixels; the height follows from [kSilhouetteAspect].
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size / kSilhouetteAspect,
      child: DogSilhouettePicker(
        selectedCells: cells.toSet(),
        onChanged: (_) {},
        readOnly: true,
        highlightColor: AppColors.error,
      ),
    );
  }
}
