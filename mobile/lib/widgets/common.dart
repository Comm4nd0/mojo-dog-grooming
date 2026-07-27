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
    final color = AppColors.temperamentColor(temperament);
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

  static String _defaultLabel(String temperament) => switch (temperament) {
        'FEISTY' => 'Feisty',
        'FIDGETY' => 'Fidgety',
        _ => 'Easy',
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
    final tint = color ?? AppColors.primary;
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
            Icon(icon, size: 48, color: AppColors.inkSecondary.withValues(alpha: 0.5)),
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
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.ink,
      ),
    );
}
