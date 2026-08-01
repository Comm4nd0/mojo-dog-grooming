import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_colors.dart';
import 'common.dart';

/// Handing a phone number, an email address or an address off to the phone.
///
/// Jess asked for the number and contact details to be "linked" so she can
/// ring, write or find someone without retyping. All three are built from
/// fields the API already returns; nothing is stored for this.

/// Strips a phone number down to something `tel:` will accept.
///
/// Numbers here are free text off a paper card — "07700 900 001",
/// "07700-900001", "+44 7700 900001" all occur. Spaces and punctuation in a
/// `tel:` URI are technically allowed but are handled inconsistently, and a
/// leading `+` has to survive.
String dialableNumber(String raw) {
  final trimmed = raw.trim();
  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  return trimmed.startsWith('+') ? '+$digits' : digits;
}

/// Flattens a multi-line address and its postcode into one map query.
String mapQuery(String address, String postcode) {
  final parts = [
    ...address.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty),
    postcode.trim(),
  ].where((part) => part.isNotEmpty);
  return parts.join(', ');
}

Future<void> _open(BuildContext context, Uri uri, String failureMessage) async {
  bool launched;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    launched = false;
  }
  if (!launched && context.mounted) {
    // A tablet with no dialler, or no mail app set up. Say so rather than
    // letting the tap do nothing at all.
    showSnack(context, failureMessage, isError: true);
  }
}

Future<void> callNumber(BuildContext context, String number) {
  return _open(
    context,
    Uri(scheme: 'tel', path: dialableNumber(number)),
    "This device can't make calls.",
  );
}

Future<void> emailAddress(BuildContext context, String email) {
  return _open(
    context,
    Uri(scheme: 'mailto', path: email.trim()),
    'No email app is set up on this device.',
  );
}

Future<void> openMap(BuildContext context, String address, String postcode) {
  final query = mapQuery(address, postcode);
  return _open(
    context,
    // `geo:` with a `q` is understood by Google Maps and, on iOS, hands off to
    // Apple Maps. `0,0` is the documented "no coordinates, use the query" form.
    Uri.parse('geo:0,0?q=${Uri.encodeComponent(query)}'),
    "Couldn't open a map for that address.",
  );
}

/// A [DetailRow] whose value is tappable — the row shape used all over the
/// client and dog profiles, with an action on the end.
///
/// Hides itself when [value] is empty, exactly as [DetailRow] does, so a
/// client with no email doesn't get a dead mail button.
class ContactRow extends StatelessWidget {
  const ContactRow({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final text = value.trim();
    // Same rule as DetailRow: a client with no email should not get a dead
    // mail button.
    if (text.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      // Mirrors DetailRow's metrics — 16 in from the edge, a 108pt label
      // column — so a tappable row lines up with the plain ones around it.
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: 3, bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 108, child: Text(label, style: theme.textTheme.bodySmall)),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(color: context.mojo.accent),
              ),
            ),
            IconButton(
              icon: Icon(icon, size: 20),
              color: context.mojo.accent,
              tooltip: tooltip,
              onPressed: onTap,
            ),
          ],
        ),
      ),
    );
  }
}
