import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

/// One visit, as the owner sees it — Jess's groom report card.
///
/// Her words for what belongs on it: the tick boxes, *"notes from any of the
/// above, why it was not carried out"*, the temperament of the dog and the
/// anything-to-note box. The server whitelists exactly that, so nothing on
/// this screen needs hiding — everything in a [GroomReport] is for the person
/// reading it.
///
/// Read-only by design: the record is Jess's, the report is a window onto it.
class GroomReportScreen extends StatelessWidget {
  const GroomReportScreen({super.key, required this.report});

  final GroomReport report;

  @override
  Widget build(BuildContext context) {
    // Answered items only. On the staff card a null row is worth showing —
    // it is Jess's own to-do list — but on the owner's report "Not recorded"
    // eight times over reads as eight worries, and a card written up before
    // the checklist existed would be all of them. What was done and what was
    // deliberately left, with the reason, is the report.
    final answered =
        report.checklist.where((item) => item.done != null).toList();

    return Scaffold(
      appBar: AppBar(title: Text('${report.dogName} · ${formatDate(report.startedAt)}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 40),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              report.isGroom ? 'Groom report' : 'Nails, fleas or ticks',
              style: AppColors.display(22),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              formatDate(report.startedAt),
              style: TextStyle(fontSize: 13, color: context.mojo.muted),
            ),
          ),

          const SectionHeader(title: 'Checklist'),
          if (answered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                "The checklist wasn't filled in for this visit.",
                style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
              ),
            )
          else
            for (final item in answered)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: Row(
                  children: [
                    Icon(
                      item.done == true
                          ? Icons.check_circle_outline
                          : Icons.remove_circle_outline,
                      size: 18,
                      color: item.done == true
                          ? context.mojo.accent
                          : AppColors.warning,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(item.label, style: const TextStyle(fontSize: 14))),
                    Text(
                      item.done == true ? 'Done' : 'Not this time',
                      style: TextStyle(
                        fontSize: 12,
                        color: item.done == true
                            ? context.mojo.accent
                            : AppColors.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          if (report.checklistNotes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                report.checklistNotes,
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),
            ),
          ],

          if (report.fleasTreated || report.ticksRemoved) ...[
            const SectionHeader(title: 'Fleas and ticks'),
            if (report.fleasTreated)
              const DetailRow(label: 'Fleas', value: 'Treated'),
            if (report.ticksRemoved)
              const DetailRow(label: 'Ticks', value: 'Removed'),
          ],

          if (report.temperamentDisplay.isNotEmpty) ...[
            const SectionHeader(title: 'How they were'),
            DetailRow(label: 'On the day', value: report.temperamentDisplay),
          ],

          if (report.notes.isNotEmpty) ...[
            const SectionHeader(title: 'Notes from the groom'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                report.notes,
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
