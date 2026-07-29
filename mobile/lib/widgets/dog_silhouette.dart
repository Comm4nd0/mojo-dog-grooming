import 'package:flutter/gestures.dart' show DragStartBehavior;
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

/// Tap or drag over cells on a dog silhouette to mark a problem area.
///
/// Used by staff on the dog profile and by owners on the intake form — the one
/// place an owner supplies this information.
///
/// The silhouette is a side-on standing dog facing left, so the grid reads
/// roughly: head and muzzle in columns 0-2, barrel and back 3-8, hindquarters
/// and tail 9-11, legs and feet in rows 4-7.
///
/// **Dragging paints.** On a phone the picker is about 310dp wide, which puts a
/// cell at roughly 26 x 25dp — well under the 44-48dp both platforms recommend
/// for a touch target. Requiring a separate accurate tap per cell would make
/// marking a hip or a matted flank genuinely fiddly, so a drag paints across
/// cells and a drag begun on an already-marked cell erases instead.
class DogSilhouettePicker extends StatefulWidget {
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

  @override
  State<DogSilhouettePicker> createState() => _DogSilhouettePickerState();
}

class _DogSilhouettePickerState extends State<DogSilhouettePicker> {
  /// Whether the in-flight drag is adding cells or removing them. Fixed by the
  /// first cell touched, so one gesture never both paints and erases.
  bool? _dragAdds;

  /// Cells accumulated during the current drag, or null when not dragging.
  ///
  /// The widget is controlled — normally it renders `widget.selectedCells` —
  /// but a drag cannot rely on that. Several pointer moves can arrive within
  /// one frame, and the parent's `setState` does not take effect until the
  /// next, so reading `widget.selectedCells` on each move would compute every
  /// change from the same stale set and drop all but the last cell. Holding
  /// the running set here also means the paint appears under the finger
  /// immediately rather than a frame late.
  Set<String>? _dragCells;

  Set<String> get _visibleCells => _dragCells ?? widget.selectedCells;

  /// Which cell a local offset falls in, or null when the pointer has left the
  /// grid — dragging off the edge should stop, not smear along it.
  String? _refAt(Offset local, Size size) {
    if (local.dx < 0 || local.dy < 0 || local.dx >= size.width || local.dy >= size.height) {
      return null;
    }
    final col = (local.dx / (size.width / kGridColumns)).floor();
    final row = (local.dy / (size.height / kGridRows)).floor();
    if (col < 0 || col >= kGridColumns || row < 0 || row >= kGridRows) return null;
    return cellRef(row, col);
  }

  void _toggle(String ref) {
    final next = Set<String>.from(widget.selectedCells);
    if (!next.remove(ref)) next.add(ref);
    widget.onChanged(next);
  }

  void _paintAt(Offset local, Size size) {
    final ref = _refAt(local, size);
    if (ref == null) return;

    final cells = _dragCells ??= Set<String>.from(widget.selectedCells);
    final adds = _dragAdds ??= !cells.contains(ref);
    final changed = adds ? cells.add(ref) : cells.remove(ref);
    if (!changed) return; // already in the wanted state

    setState(() {}); // repaint under the finger now, not next frame
    widget.onChanged(Set<String>.from(cells));
  }

  void _endDrag() {
    if (_dragCells == null && _dragAdds == null) return;
    setState(() {
      _dragCells = null;
      _dragAdds = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tint = widget.highlightColor ?? context.mojo.accent;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : AppColors.ink;
    final gridLine = ink.withValues(alpha: 0.12);

    return AspectRatio(
      aspectRatio: kSilhouetteAspect,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final cellWidth = size.width / kGridColumns;
          final cellHeight = size.height / kGridRows;

          final grid = Stack(
            children: [
              Positioned.fill(
                child: SvgPicture.asset(
                  kSilhouetteAsset,
                  fit: BoxFit.fill,
                  // Kept faint so the grid lines and any marked cells stay the
                  // dominant marks — this is a diagram to annotate, not an
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
                      selected: _visibleCells.contains(cellRef(row, col)),
                      gridLine: gridLine,
                      tint: tint,
                      label: describeCell(row, col),
                      interactive: !widget.readOnly,
                      onToggle: widget.readOnly ? null : () => _toggle(cellRef(row, col)),
                    ),
                  ),
            ],
          );

          if (widget.readOnly) return grid;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Report the drag from where the finger actually landed. The
            // default (DragStartBehavior.start) reports the position *after*
            // the ~18dp touch slop, which is most of a cell away: the cell the
            // user pressed would be skipped, and worse, if they began on a
            // marked cell the mode could latch to erase from the neighbour and
            // rub out what they meant to keep.
            dragStartBehavior: DragStartBehavior.down,
            onTapUp: (details) {
              final ref = _refAt(details.localPosition, size);
              if (ref != null) _toggle(ref);
            },
            onPanStart: (details) => _paintAt(details.localPosition, size),
            onPanUpdate: (details) => _paintAt(details.localPosition, size),
            onPanEnd: (_) => _endDrag(),
            onPanCancel: _endDrag,
            child: grid,
          );
        },
      ),
    );
  }
}

/// Rough anatomy for an accessibility label, so a screen reader announces
/// something a person can act on rather than "row 8, column 5".
///
/// The artwork is a standing dog seen from its left side, head at the left of
/// the frame. Kept in step with `describe()` in `templates/intake/form.html`,
/// which labels the same grid on the web form.
String describeCell(int row, int col) {
  final where = 'row ${row + 1} column ${col + 1}';

  if (row >= 6) {
    final side = col <= 5 ? 'front' : 'hind';
    return '$side ${row == 7 ? 'paw' : 'leg'}, $where';
  }

  final part = col <= 2
      ? 'head'
      : col <= 4
          ? 'neck and shoulder'
          : col <= 8
              ? 'body'
              : (row <= 1 ? 'tail' : 'hindquarters');
  final band = row <= 1
      ? 'top of'
      : row <= 3
          ? 'upper'
          : 'lower';
  return '$band $part, $where';
}

/// A grid cell. Visually painted by the parent's single gesture recogniser so
/// a drag can cross cell boundaries, but each cell still carries its own
/// semantics so the grid is usable with a screen reader — 96 anonymous shapes
/// on an owner-facing form would not be.
class _Cell extends StatelessWidget {
  const _Cell({
    required this.selected,
    required this.gridLine,
    required this.tint,
    required this.label,
    required this.interactive,
    this.onToggle,
  });

  final bool selected;
  final Color gridLine;
  final Color tint;
  final String label;
  final bool interactive;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: selected ? tint.withValues(alpha: 0.42) : Colors.transparent,
        border: Border.all(
          color: selected ? tint : gridLine,
          width: selected ? 1.5 : 0.5,
        ),
      ),
    );

    return Semantics(
      label: label,
      checked: selected,
      inMutuallyExclusiveGroup: false,
      enabled: interactive,
      // Assistive tech drives the cell directly; pointers go through the
      // parent recogniser so a drag is not chopped up per cell.
      onTap: onToggle,
      child: ExcludeSemantics(
        excluding: false,
        child: IgnorePointer(child: box),
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
