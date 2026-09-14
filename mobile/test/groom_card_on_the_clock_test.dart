import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/screens/staff/visit_record_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/service_locator.dart';

const _emptyPage = '{"count":0,"next":null,"previous":null,"results":[]}';

/// The record card opened off a groom that is still on the clock.
///
/// Jess: *"is there a way that I can 'fill out the groom card' whilst doing
/// the groom, so bits found in health check I remember to put on"*. The card
/// used to open only once the timer was settled. Now it opens at any point,
/// reads the time so far without pausing anything, and hands every change
/// back to the timer's draft — so leaving it keeps it, and saving from it is
/// what finishes the groom.
void main() {
  tearDown(getIt.reset);

  late List<Map<String, dynamic>> drafts;
  late List<http.Request> posts;
  late bool running;
  late bool settled;

  Future<void> pumpCard(
    WidgetTester tester, {
    Map<String, dynamic> record = const {},
    List<PhaseTiming> phases = const [],
  }) async {
    drafts = [];
    posts = [];
    settled = false;
    final mock = MockClient((request) async {
      const asJson = {'content-type': 'application/json'};
      if (request.method == 'POST' && request.url.path.endsWith('/groom-sessions/')) {
        posts.add(request);
        return http.Response(
          jsonEncode({
            'id': 5,
            'dog': 1,
            'dog_name': 'Biscuit',
            'started_at': '2026-09-14T10:00:00+01:00',
          }),
          201,
          headers: asJson,
        );
      }
      return http.Response(_emptyPage, 200, headers: asJson);
    });
    final api = ApiClient(baseUrl: 'http://test/api', httpClient: mock);
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<DataService>(DataService(api));

    tester.view.physicalSize = const Size(800, 4400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AppColors.lightTheme(),
      home: VisitRecordScreen(
        dogId: 1,
        dogName: 'Biscuit',
        liveGroom: LiveGroom(
          phases: () => phases,
          settle: () {
            settled = true;
            return phases;
          },
          isRunning: () => running,
          record: record,
          onRecordChanged: drafts.add,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on what was put on it last time', (tester) async {
    running = true;
    await pumpCard(tester, record: {
      'health_check_done': true,
      'health_check_notes': 'Small lump on the left hip',
      'hygiene_area_done': false,
      'matting_ears': true,
      'notes': 'Lovely today',
    });

    expect(find.text('Small lump on the left hip'), findsOneWidget);
    expect(find.text('Lovely today'), findsOneWidget);
    // Health check done, hygiene area not — and the other six untouched
    // (the seventh "Not recorded" is the temperament picker's).
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Not done — say why below'), findsOneWidget);
    expect(find.text('Not recorded'), findsNWidgets(7));

    // Reading the draft back is not a change to it.
    expect(drafts, isEmpty);
  });

  testWidgets('says it is on the clock, and never asks what kind of visit',
      (tester) async {
    running = true;
    await pumpCard(tester);

    expect(find.textContaining('Still on the clock'), findsOneWidget);
    expect(find.text('FINISH & SAVE RECORD'), findsOneWidget);
    expect(find.text('KEEP — BACK TO THE TIMER'), findsOneWidget);
    // A timed visit is a groom by construction — even before any time is on
    // it, because the card is now opened before the clock starts too.
    expect(find.text('What kind of visit'), findsNothing);
  });

  testWidgets('every change goes straight back to the timer', (tester) async {
    running = true;
    await pumpCard(tester);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Health check'));
    await tester.pumpAndSettle();
    expect(drafts.last['health_check_done'], isTrue);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Anything found'),
      'Small lump on the left hip',
    );
    await tester.pumpAndSettle();
    expect(drafts.last['health_check_notes'], 'Small lump on the left hip');
    // What was ticked a moment ago is still in the draft the text landed in.
    expect(drafts.last['health_check_done'], isTrue);
    expect(posts, isEmpty);
  });

  testWidgets('shows the time so far, without settling it', (tester) async {
    running = true;
    await pumpCard(tester, phases: const [
      PhaseTiming(phase: 'PREP', durationSeconds: 600),
      PhaseTiming(phase: 'WASH', durationSeconds: 900),
    ]);

    expect(find.text('Actual grooming time'), findsOneWidget);
    expect(find.text('2 phases timed'), findsOneWidget);
    expect(settled, isFalse);
  });

  testWidgets('finishing off a running clock asks first', (tester) async {
    running = true;
    await pumpCard(tester);

    await tester.tap(find.text('FINISH & SAVE RECORD'));
    await tester.pumpAndSettle();
    expect(find.text('Stop the clock?'), findsOneWidget);

    await tester.tap(find.text('KEEP TIMING'));
    await tester.pumpAndSettle();
    expect(settled, isFalse);
    expect(posts, isEmpty);

    await tester.tap(find.text('FINISH & SAVE RECORD'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FINISH & SAVE'));
    await tester.pumpAndSettle();
    expect(settled, isTrue);
    expect(posts, hasLength(1));
  });

  testWidgets('a paused clock finishes without the question', (tester) async {
    running = false;
    await pumpCard(tester, record: {'notes': 'Lovely today'});

    await tester.tap(find.text('FINISH & SAVE RECORD'));
    await tester.pumpAndSettle();
    expect(find.text('Stop the clock?'), findsNothing);
    expect(settled, isTrue);
    expect(posts, hasLength(1));
    // The card went with it.
    final body = jsonDecode(posts.single.body) as Map<String, dynamic>;
    expect(body['notes'], 'Lovely today');
    expect(body['dog'], 1);
  });
}
