import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/models.dart';
import '../services/api_client.dart';

/// Temperament badge. Staff-only — [temperament] is null for client logins,
/// in which case this renders nothing at all.
class TemperamentChip extends StatelessWidget {
  const TemperamentChip({super.key, required this.temperament, this.label, this.compact = false});

  final String? temperament;
  final String? label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (temperament == null) return const SizedBox.shrink();
    final color = context.temperamentColour(temperament);
    final text = label ?? _defaultLabel(temperament!);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: compact ? 10.5 : 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  /// Wording of last resort, for a caller with no [label] to hand.
  ///
  /// Jess renames the grades in Settings, so the server's
  /// `temperament_display` is the real answer and every screen that has one
  /// passes it in. These are the seed names, used only when there is nothing
  /// better.
  ///
  /// **The fallback returns the code itself, not "Easy".** It used to be
  /// `_ => 'Easy'`, so a build that had not heard of a grade — an older phone
  /// against a newer server — would quietly label a bitey dog as easy. An
  /// unfamiliar code shown raw is odd-looking; the same code shown as "Easy"
  /// gets someone bitten.
  static String _defaultLabel(String temperament) => switch (temperament) {
        'EASY' => 'Easy',
        'WRIGGLY' => 'Wriggly',
        'FIDGETY' => 'Fidgety',
        'BITEY' => 'Bitey',
        'FEISTY' => 'Feisty',
        _ => temperament,
      };
}

/// Small pale-green flag, e.g. "Chatty" on an owner.
class InfoTag extends StatelessWidget {
  const InfoTag({super.key, required this.label, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.mojo.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: tint),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: tint, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Section heading in the brand display face.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 8, 8),
      child: Row(
        children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.headlineSmall)),
          ?action,
        ],
      ),
    );
  }
}

/// A [TextFormField] that selects its contents when you tap into it.
///
/// Jess asked for "type to reset across the board — click on then not have to
/// delete text to enter details". Every form here is mostly *editing* existing
/// details rather than filling in blanks, and Flutter's default puts the caret
/// where you tapped, so correcting a phone number meant holding backspace.
///
/// The selection is set once per focus gain, not on every rebuild: doing it in
/// `build` would fight the user the moment they tried to place the caret
/// deliberately. Tapping a second time inside an already-focused field behaves
/// normally, which is the escape hatch for editing one character.
///
/// Owns its [FocusNode] unless given one, so migrating a field is renaming the
/// widget and nothing else.
class MojoTextField extends StatefulWidget {
  const MojoTextField({
    super.key,
    required this.controller,
    this.decoration,
    this.focusNode,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.maxLines = 1,
    this.minLines,
    this.enabled = true,
    this.autofocus = false,
    this.validator,
    this.onChanged,
    this.onFieldSubmitted,
    this.selectOnFocus,
  });

  final TextEditingController controller;
  final InputDecoration? decoration;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final int? maxLines;
  final int? minLines;
  final bool enabled;
  final bool autofocus;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;

  /// Defaults to on for single-line fields only.
  ///
  /// A phone number or a price is a value you replace; a notes box is one you
  /// add to, and selecting several paragraphs on focus would put the lot one
  /// keystroke from being wiped. Pass it explicitly to override either way.
  final bool? selectOnFocus;

  @override
  State<MojoTextField> createState() => _MojoTextFieldState();
}

class _MojoTextFieldState extends State<MojoTextField> {
  FocusNode? _owned;
  FocusNode get _focus => widget.focusNode ?? (_owned ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _owned?.dispose();
    super.dispose();
  }

  bool get _selectOnFocus => widget.selectOnFocus ?? widget.maxLines == 1;

  void _onFocusChanged() {
    if (!_selectOnFocus || !_focus.hasFocus) return;
    final text = widget.controller.text;
    if (text.isEmpty) return;
    widget.controller.selection =
        TextSelection(baseOffset: 0, extentOffset: text.length);
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      focusNode: _focus,
      decoration: widget.decoration,
      keyboardType: widget.keyboardType,
      textCapitalization: widget.textCapitalization,
      textInputAction: widget.textInputAction,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      validator: widget.validator,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onFieldSubmitted,
    );
  }
}

/// Label/value row used throughout the profiles. Hides itself when empty.
class DetailRow extends StatelessWidget {
  const DetailRow({super.key, required this.label, required this.value, this.hideWhenEmpty = true});

  final String label;
  final String? value;
  final bool hideWhenEmpty;

  @override
  Widget build(BuildContext context) {
    final text = value?.trim() ?? '';
    if (text.isEmpty && hideWhenEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              text.isEmpty ? '—' : text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder for an empty list, with an optional call to action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: context.mojo.muted.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Error state with a retry, phrased for the failure that actually happened.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final offline = error is NoConnectionException;
    return EmptyState(
      icon: offline ? Icons.wifi_off : Icons.error_outline,
      title: offline ? 'No connection' : 'Something went wrong',
      message: error.toString(),
      action: OutlinedButton(onPressed: onRetry, child: const Text('TRY AGAIN')),
    );
  }
}

/// Confirm dialog for the advisory booking warnings.
///
/// The affirmative action is always available — these warnings inform the
/// decision, they never take it away.
Future<bool> showWarningsDialog(BuildContext context, BookingCheck check) async {
  if (!check.hasWarnings) return true;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Before you book'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final warning in check.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.warning),
                  const SizedBox(width: 10),
                  Expanded(child: Text(warning.message)),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('GO BACK'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('BOOK ANYWAY'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

void showSnack(BuildContext context, String message, {bool isError = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      // Only the error colour is forced. The ordinary background comes from
      // snackBarTheme, which picks a shade that separates from the scaffold in
      // whichever theme is in force — passing ink here unconditionally made the
      // bar all but invisible in dark mode.
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : null,
      ),
    );
}

/// Ask for a single line of text. Returns null if the dialog was cancelled,
/// otherwise the trimmed text (which may be empty).
///
/// The controller belongs to the dialog's own State rather than the caller.
/// `await showDialog(...)` completes the moment `Navigator.pop` runs, while
/// the route is still animating out and the field is still on screen, so a
/// caller that disposes its controller on the next line kills it underneath a
/// live TextField: "A TextEditingController was used after being disposed."
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String? message,
  String initialValue = '',
  String? labelText,
  String? hintText,
  String? helperText,
  String? suffixText,
  TextInputType? keyboardType,
  TextCapitalization textCapitalization = TextCapitalization.sentences,
  String confirmLabel = 'SAVE',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _TextPromptDialog(
      title: title,
      message: message,
      initialValue: initialValue,
      labelText: labelText,
      hintText: hintText,
      helperText: helperText,
      suffixText: suffixText,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      confirmLabel: confirmLabel,
    ),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.message,
    required this.initialValue,
    required this.labelText,
    required this.hintText,
    required this.helperText,
    required this.suffixText,
    required this.keyboardType,
    required this.textCapitalization,
    required this.confirmLabel,
  });

  final String title;
  final String? message;
  final String initialValue;
  final String? labelText;
  final String? hintText;
  final String? helperText;
  final String? suffixText;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final String confirmLabel;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void initState() {
    super.initState();
    // The field autofocuses with the caret at the end, so editing a phase's
    // minutes meant backspacing over the existing number first. Pre-selecting
    // it means typing replaces — same as [MojoTextField].
    _controller.selection =
        TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: widget.keyboardType,
            textCapitalization: widget.textCapitalization,
            decoration: InputDecoration(
              labelText: widget.labelText,
              hintText: widget.hintText,
              helperText: widget.helperText,
              suffixText: widget.suffixText,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        ElevatedButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
