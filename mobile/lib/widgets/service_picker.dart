import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/models.dart';

/// Tick what is being done.
///
/// Jess asked for "a drop down list of services/type of groom" at the top of
/// grooming preferences. It is a tick-list rather than a dropdown because more
/// than one thing happens at a visit — a full groom *and* nails is the normal
/// case, and a dropdown can only say one.
///
/// A service with no price set shows a quiet marker. Her price list covers
/// full grooms only, so most of these are blank until she fills them in, and
/// the booking check says so again at save time rather than the app inventing
/// a figure.
class ServicePicker extends StatelessWidget {
  const ServicePicker({
    super.key,
    required this.services,
    required this.selected,
    required this.onChanged,
    this.showPrices = true,
  });

  final List<ServiceItem> services;
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;

  /// Off on the dog form, where this records what the dog usually has rather
  /// than what a particular visit will cost.
  final bool showPrices;

  @override
  Widget build(BuildContext context) {
    if (services.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'No services set up yet.',
          style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final service in services)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: selected.contains(service.id),
            onChanged: (ticked) {
              // A fresh set, not a mutation: the parent holds this in its own
              // state and comparing identical instances would skip the build.
              final next = Set<int>.from(selected);
              if (ticked == true) {
                next.add(service.id);
              } else {
                next.remove(service.id);
              }
              onChanged(next);
            },
            title: Row(
              children: [
                Expanded(child: Text(service.name)),
                if (service.category == ServiceType.nailsFleasTicks)
                  InfoTagLike(
                    label: 'Nails card',
                    colour: context.temperamentColour(null),
                  ),
              ],
            ),
            subtitle: showPrices ? Text(service.summary) : null,
          ),
      ],
    );
  }
}

/// A tiny flag, without pulling in the full InfoTag's brand green.
class InfoTagLike extends StatelessWidget {
  const InfoTagLike({super.key, required this.label, required this.colour});

  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(border: Border.all(color: colour.withValues(alpha: 0.4))),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: colour, fontWeight: FontWeight.w600),
      ),
    );
  }
}
