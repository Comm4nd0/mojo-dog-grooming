import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/screens/client/groom_report_screen.dart';

/// The owner's groom report, after Jess's three asks of 3 Nov 2026:
/// 1. "can anything not been ticked off still be shown and if left blank just
///    say N/A… reminds clients more on offer"
/// 2. the health check, under her not-a-vet disclaimer, and where matting
///    was found
/// 3. flea and tick aftercare
void main() {
  Future<void> pumpReport(WidgetTester tester, Map<String, dynamic> json) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.lightTheme(),
      home: GroomReportScreen(
        report: GroomReport.fromJson({
          'id': 1, 'dog': 1, 'dog_name': 'Finley', 'visit_type': 'GROOM',
          'started_at': '2026-11-03T10:00:00Z',
          ...json,
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('every checklist item shows, blanks as N/A', (tester) async {
    await pumpReport(tester, {
      'nails_done': true, 'ears_cleaned': true, 'hygiene_area_done': false, 'bathed': true,
    });
    for (final label in [
      'Health check', 'Nails clipped', 'Ears cleaned', 'Hygiene area',
      'Feet clipped out', 'Bathed', 'Blow dried', 'Usual groom',
    ]) {
      expect(find.textContaining(label), findsWidgets, reason: '$label is missing');
    }
    expect(find.text('Done'), findsNWidgets(3));
    expect(find.text('Not this time'), findsOneWidget);
    expect(find.text('N/A'), findsNWidgets(4));
  });

  testWidgets('a card written before the checklist is all N/A, not a blank', (tester) async {
    await pumpReport(tester, {});
    expect(find.text('N/A'), findsNWidgets(8));
  });

  testWidgets('health check findings come under the disclaimer', (tester) async {
    await pumpReport(tester, {'health_check_notes': 'Small wart on the left ear.'});
    final disclaimer = find.byKey(const Key('health-check-disclaimer'));
    expect(disclaimer, findsOneWidget);
    expect(find.textContaining('we are not trained vets'), findsOneWidget);
    final finding = find.text('Small wart on the left ear.');
    expect(tester.getTopLeft(disclaimer).dy, lessThan(tester.getTopLeft(finding).dy));
  });

  testWidgets('no findings, no health check section', (tester) async {
    await pumpReport(tester, {});
    expect(find.byKey(const Key('health-check-disclaimer')), findsNothing);
    expect(find.text('Matting found'), findsNothing);
  });

  testWidgets('says where matting was found', (tester) async {
    await pumpReport(tester, {
      'matting_paws': true, 'matting_ears': true,
      'matting_elsewhere': true, 'matting_notes': 'Behind the collar',
    });
    expect(find.text('Matting found'), findsOneWidget);
    expect(find.text('In paws, Under ears'), findsOneWidget);
    expect(find.text('Behind the collar'), findsOneWidget);
  });

  testWidgets('aftercare sits under what was treated', (tester) async {
    await pumpReport(tester, {
      'fleas_treated': true, 'ticks_removed': true,
      'flea_aftercare': 'Flea bath again in two weeks.',
      'tick_aftercare': 'Keep an eye on the bite area.',
    });
    expect(find.text('Flea bath again in two weeks.'), findsOneWidget);
    expect(find.text('Keep an eye on the bite area.'), findsOneWidget);
  });
}
