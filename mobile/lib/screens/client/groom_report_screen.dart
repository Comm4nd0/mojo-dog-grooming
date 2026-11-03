import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

/// One visit, as the owner sees it — Jess's groom report card.
///
/// Her words for what belongs on it: the tick boxes, *"notes from any of the
/// above, why it was not carried out"*, the temperament of the dog and the
/// anything-to-note box — and later the health check (under her not-a-vet
/// disclaimer), where matting was found, and flea and tick aftercare. The
/// server whitelists exactly that, so nothing on this screen needs hiding —
/// everything in a [GroomReport] is for the person reading it.
///
/// Read-only by design: the record is Jess's, the report is a window onto it.
class GroomReportScreen extends StatelessWidget {
  const GroomReportScreen({super.key, required this.report});

  final GroomReport report;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${report.dogName} · ${formatDate(report.startedAt)}')),
      body: PageBody(child: ListView(
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
          // Every item, answered or not. It used to show answered ones only,
          // so "Not recorded" eight times over would not read as eight
          // worries; Jess asked for the opposite — "can anything not been
          // ticked off still be shown and if left blank just say N/A…
          // reminds clients more on offer". N/A, not "not done": a blank is
          // a box nobody ticked, and saying the nails were skipped would be
          // a claim nobody made.
          for (final item in report.checklist) _checklistRow(context, item),
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

          // Jess: "can the health check ... and where matting found be
          // added", with her disclaimer above whatever was found.
          if (report.healthCheckNotes.isNotEmpty) ...[
            const SectionHeader(title: 'Health check'),
            _disclaimer(context),
            _paragraph(report.healthCheckNotes),
          ],

          if (report.hasMatting) ...[
            const SectionHeader(title: 'Matting found'),
            if (report.mattingAreas.isNotEmpty)
              _paragraph(report.mattingAreas.join(', ')),
            if (report.mattingNotes.isNotEmpty) ...[
              const SizedBox(height: 4),
              _paragraph(report.mattingNotes),
            ],
          ],

          if (report.fleasTreated || report.ticksRemoved) ...[
            const SectionHeader(title: 'Fleas and ticks'),
            if (report.fleasTreated) ...[
              const DetailRow(label: 'Fleas', value: 'Treated'),
              if (report.fleaAftercare.isNotEmpty) _aftercare(context, report.fleaAftercare),
            ],
            if (report.ticksRemoved) ...[
              const DetailRow(label: 'Ticks', value: 'Removed'),
              if (report.tickAftercare.isNotEmpty) _aftercare(context, report.tickAftercare),
            ],
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
      )),
    );
  }

  /// Jess's own wording, verbatim — it is her statement to her clients.
  static const healthCheckDisclaimer =
      'This is observation from the groomer, please note we are not trained vets '
      'and these are simple observations found on your dog during our basic health '
      'check, please speak with your groomer or vet about anything of concern';

  Widget _checklistRow(BuildContext context, ({String label, bool? done}) item) {
    final (icon, colour, word) = switch (item.done) {
      true => (Icons.check_circle_outline, context.mojo.accent, 'Done'),
      false => (Icons.remove_circle_outline, AppColors.warning, 'Not this time'),
      null => (Icons.circle_outlined, context.mojo.muted, 'N/A'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: 10),
          Expanded(child: Text(item.label, style: const TextStyle(fontSize: 14))),
          Text(
            word,
            style: TextStyle(fontSize: 12, color: colour, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _paragraph(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.4)),
      );

  Widget _disclaimer(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(
          healthCheckDisclaimer,
          key: const Key('health-check-disclaimer'),
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            fontStyle: FontStyle.italic,
            color: context.mojo.muted,
          ),
        ),
      );

  Widget _aftercare(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: context.mojo.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4))),
          ],
        ),
      );
}
