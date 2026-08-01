import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Type-to-filter picker for a list that is too long to scroll through.
///
/// Ported from p4td's `DogTypeahead`, which Jess recognised as "the tagging" —
/// a `LayerLink` plus a hand-built `OverlayEntry` rather than
/// `DropdownButtonFormField` or Flutter's `Autocomplete`. Three reasons for
/// that shape rather than the shorter `Autocomplete` one:
///
/// * `Autocomplete`'s options view is `Align`-positioned in the overlay and
///   does not track the field. Both screens using this are `ListView`s;
///   scrolling with the list open would visibly detach it.
///   `CompositedTransformFollower` re-anchors every frame.
/// * `Autocomplete` has no keyboard-aware height clamp. On a phone the
///   keyboard covers the options; [_availableOverlayHeight] and
///   `didChangeMetrics` exist because of that, and p4td had already hit it.
/// * `Autocomplete.initialValue` is honoured on the first build only, so it
///   fights a selection owned by the parent — which is exactly the case when
///   editing an existing booking.
///
/// Filtering is synchronous and in memory. Both call sites already hold the
/// whole list (224 breeds, and however many dogs Jess has), so a debounce and
/// a round trip would only add latency.
///
/// [T] is compared by identity, so [selected] must be an instance out of
/// [items] — both call sites resolve it from the same list by id.
class SearchablePicker<T> extends StatefulWidget {
  const SearchablePicker({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    required this.labelOf,
    required this.matches,
    required this.decoration,
    this.subtitleOf,
    this.leadingOf,
    this.trailingOf,
    this.emptyLabel = 'Nothing matches that',
    this.clearable = true,
  });

  final List<T> items;
  final T? selected;
  final ValueChanged<T?> onSelected;

  /// What goes in the field once something is chosen, and the row's title.
  final String Function(T item) labelOf;

  /// Whether [item] should survive the query the user has typed.
  final bool Function(T item, String query) matches;

  /// The field's decoration — label, hint, validation state. Its `suffixIcon`
  /// is supplied here.
  final InputDecoration decoration;

  final String? Function(T item)? subtitleOf;
  final Widget Function(BuildContext context, T item)? leadingOf;
  final Widget Function(BuildContext context, T item)? trailingOf;

  final String emptyLabel;

  /// Whether the field offers an × to go back to nothing selected. Off where
  /// a choice is mandatory.
  final bool clearable;

  @override
  State<SearchablePicker<T>> createState() => _SearchablePickerState<T>();
}

class _SearchablePickerState<T> extends State<SearchablePicker<T>>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _link = LayerLink();

  OverlayEntry? _overlay;
  late List<T> _filtered = widget.items;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(_onFocusChanged);
    _showSelectedInField();
  }

  @override
  void didUpdateWidget(SearchablePicker<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The list arrives asynchronously on both screens, so the first build
    // usually has nothing to resolve the selection against.
    if (!identical(widget.selected, oldWidget.selected) ||
        !identical(widget.items, oldWidget.items)) {
      _filtered = widget.items;
      if (!_focus.hasFocus) _showSelectedInField();
      _overlay?.markNeedsBuild();
    }
  }

  @override
  void didChangeMetrics() {
    // Re-clamp the overlay to whatever the keyboard has left of the screen.
    _overlay?.markNeedsBuild();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeOverlay();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _showSelectedInField() {
    final selected = widget.selected;
    _controller.text = selected == null ? '' : widget.labelOf(selected);
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) {
      // Select-all on focus: typing replaces the current choice rather than
      // appending to it. Same behaviour Jess asked for on every other field.
      _controller.selection =
          TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
      setState(() => _filtered = widget.items);
      _showOverlay();
    } else {
      _removeOverlay();
      // Put the chosen label back — a half-typed query left in the field
      // would read as the selection.
      _showSelectedInField();
    }
  }

  void _filter(String query) {
    setState(() {
      final trimmed = query.trim();
      _filtered = trimmed.isEmpty
          ? widget.items
          : widget.items.where((item) => widget.matches(item, trimmed)).toList();
    });
    _overlay?.markNeedsBuild();
  }

  double _availableOverlayHeight(BuildContext overlayContext) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return 200;
    final media = MediaQuery.of(overlayContext);
    final fieldBottom = box.localToGlobal(Offset.zero).dy + box.size.height;
    final available =
        media.size.height - media.viewInsets.bottom - fieldBottom - 16;
    return available.clamp(120.0, 280.0);
  }

  void _showOverlay() {
    _removeOverlay();
    final box = context.findRenderObject() as RenderBox;
    final size = box.size;

    _overlay = OverlayEntry(
      builder: (overlayContext) => Positioned(
        width: size.width,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          offset: Offset(0, size.height + 4),
          child: Material(
            elevation: 4,
            // Not optional. An OverlayEntry sits outside the Scaffold and
            // inherits no theme surface, so a default-coloured Material here
            // renders light-on-light in dark mode.
            color: Theme.of(overlayContext).colorScheme.surface,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: overlayContext.mojo.hairline),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _availableOverlayHeight(overlayContext),
              ),
              child: _filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        widget.emptyLabel,
                        style: TextStyle(color: overlayContext.mojo.muted),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _filtered.length,
                      itemBuilder: (rowContext, index) {
                        final item = _filtered[index];
                        final isSelected = identical(item, widget.selected);
                        final subtitle = widget.subtitleOf?.call(item);
                        return ListTile(
                          dense: true,
                          selected: isSelected,
                          selectedTileColor: rowContext.mojo.tintWash,
                          leading: widget.leadingOf?.call(rowContext, item),
                          title: Text(widget.labelOf(item)),
                          subtitle: subtitle == null || subtitle.isEmpty
                              ? null
                              : Text(subtitle, overflow: TextOverflow.ellipsis),
                          trailing: isSelected
                              ? Icon(Icons.check, size: 18, color: rowContext.mojo.accent)
                              : widget.trailingOf?.call(rowContext, item),
                          onTap: () {
                            widget.onSelected(item);
                            _focus.unfocus();
                          },
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = widget.selected != null;
    return CompositedTransformTarget(
      link: _link,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        onChanged: _filter,
        decoration: widget.decoration.copyWith(
          suffixIcon: widget.clearable && hasSelection
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Clear',
                  onPressed: () {
                    widget.onSelected(null);
                    _controller.clear();
                    _focus.unfocus();
                  },
                )
              : const Icon(Icons.arrow_drop_down),
        ),
      ),
    );
  }
}
