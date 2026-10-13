import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/screens/staff/dog_form_screen.dart';
import 'package:mojo_app/services/api_client.dart';
import 'package:mojo_app/services/data_service.dart';
import 'package:mojo_app/services/service_locator.dart';
import 'package:mojo_app/widgets/common.dart';

const _breeds = [
  {
    'id': 1,
    'name': 'Poodle',
    'groom_style_body': 'Long comb',
    'groom_style_head': 'Rounded face',
    'groom_style_feet': 'Clean feet',
  },
  {
    'id': 2,
    'name': 'Spaniel',
    'groom_style_body': 'Hand strip',
    'groom_style_head': 'Natural face',
  },
  {'id': 3, 'name': 'Breed without styles'},
];
const _instructions = 'Different style / previous groomer’s instructions';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  tearDown(getIt.reset);
  final writes = <http.Request>[];

  Future<void> pump(
    WidgetTester tester, {
    Map<String, dynamic>? existing,
    bool dark = false,
    Size size = const Size(375, 2600),
  }) async {
    writes.clear();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient(
      baseUrl: 'https://test/api',
      httpClient: MockClient((request) async {
        Object result = {'results': [], 'next': null};
        switch (request.url.path) {
          case '/api/clients/':
            result = {
              'results': [
                {'id': 1, 'full_name': 'Alice Adams'},
              ],
              'next': null,
            };
          case '/api/breeds/':
            result = {'results': _breeds, 'next': null};
          case '/api/temperament-grades/':
            result = {
              'results': [
                {
                  'id': 1,
                  'temperament': 'EASY',
                  'label': 'Gentle',
                  'sort_order': 1,
                },
                {
                  'id': 2,
                  'temperament': 'BITEY',
                  'label': 'Needs care',
                  'sort_order': 2,
                },
                {
                  'id': 3,
                  'temperament': 'WRIGGLY',
                  'label': 'Wriggly, but fine',
                  'sort_order': 3,
                },
                {
                  'id': 4,
                  'temperament': 'FIDGETY',
                  'label': 'Fidgety',
                  'sort_order': 4,
                },
                {
                  'id': 5,
                  'temperament': 'FEISTY',
                  'label': 'Feisty / hard',
                  'sort_order': 5,
                },
              ],
              'next': null,
            };
        }
        if (request.method == 'POST' || request.method == 'PATCH') {
          writes.add(request);
          result = {
            ...jsonDecode(request.body) as Map<String, dynamic>,
            'id': 7,
          };
        }
        return http.Response(
          jsonEncode(result),
          request.method == 'POST' ? 201 : 200,
        );
      }),
    );
    getIt.registerSingleton<ApiClient>(api);
    getIt.registerSingleton<DataService>(DataService(api));
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppColors.darkTheme() : AppColors.lightTheme(),
        home: DogFormScreen(
          presetClientId: 1,
          dog: existing == null
              ? null
              : Dog.fromJson({
                  'id': 7,
                  'client': 1,
                  'name': 'Biscuit',
                  ...existing,
                }),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chooseBreed(WidgetTester tester, String name) async {
    await tester.scrollUntilVisible(
      field('Breed'),
      -500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(field('Breed'), name);
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester, String title) async {
    await tester.ensureVisible(find.text(title));
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Future<Map<String, dynamic>> save(WidgetTester tester) async {
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    return jsonDecode(writes.single.body) as Map<String, dynamic>;
  }

  testWidgets(
    'adding just a name saves unknown handling and no invented style',
    (tester) async {
      await pump(tester);
      expect(field('Handling notes'), findsNothing);
      expect(field('Body'), findsNothing);
      expect(find.text('Not assessed'), findsOneWidget);
      await tester.enterText(field("Dog's name *"), 'New arrival');
      final body = await save(tester);
      expect(body['temperament'], '');
      expect(body['requires_restraint'], isNull);
      expect(body['pref_body'], '');
    },
  );

  testWidgets('breed styles save without opening the individual fields', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(field("Dog's name *"), 'New arrival');
    await chooseBreed(tester, 'Poodle');
    expect(field('Body'), findsNothing);
    expect(
      find.text('Not specified by the breed record: Tail, Ears, Skirt.'),
      findsOneWidget,
    );
    final body = await save(tester);
    expect(body['pref_body'], 'Long comb');
    expect(body['pref_face'], 'Rounded face');
    expect(body['pref_feet'], 'Clean feet');
    expect(body['pref_tail'], '');
    expect(body['pref_skirt'], '');
  });

  testWidgets('changing breed updates only untouched unsaved suggestions', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(field("Dog's name *"), 'New arrival');
    await chooseBreed(tester, 'Poodle');
    await expand(tester, _instructions);
    await tester.enterText(
      field('Body'),
      'Keep the previous groomer’s long trim',
    );
    await tester.enterText(field('Face'), '');
    await chooseBreed(tester, 'Spaniel');
    final body = await save(tester);
    expect(body['pref_body'], 'Keep the previous groomer’s long trim');
    expect(
      body['pref_face'],
      '',
      reason: 'an explicitly cleared area stays cleared',
    );
    expect(body['pref_feet'], '', reason: 'Spaniel has no recorded feet style');
  });

  testWidgets(
    'a breed with no styles cannot inherit the previous suggestions',
    (tester) async {
      await pump(tester);
      await tester.enterText(field("Dog's name *"), 'New arrival');
      await chooseBreed(tester, 'Poodle');
      await chooseBreed(tester, 'Breed without styles');
      expect(
        find.text('No grooming styles recorded for Breed without styles yet.'),
        findsOneWidget,
      );
      final body = await save(tester);
      expect(body['pref_body'], '');
      expect(body['pref_face'], '');
    },
  );

  testWidgets(
    'an unrelated edit preserves old grades, false restraint and all styling',
    (tester) async {
      final original = {
        'breed': 1,
        'temperament': 'EASY',
        'requires_restraint': false,
        'temperament_notes': 'Patient with the dryer',
        'pref_body': 'Previous groomer trim',
        'pref_face': '',
        'pref_feet': 'Round',
        'pref_tail': 'Flag',
        'pref_ears': 'Long',
        'pref_skirt': 'Leave furnishings',
      };
      await pump(tester, existing: original);
      expect(
        find.textContaining('Gentle · No restraints required'),
        findsOneWidget,
      );
      expect(field('Body'), findsNothing);
      await tester.enterText(field("Dog's name *"), 'Biscuit renamed');
      final body = await save(tester);
      for (final entry in original.entries) {
        expect(body[entry.key], entry.value, reason: entry.key);
      }
    },
  );

  testWidgets(
    'saved styling survives a breed change, with blanks filled from the new breed',
    (tester) async {
      await pump(
        tester,
        existing: {
          'breed': 1,
          'pref_body': 'Long comb',
          'pref_feet': 'Keep round',
          'temperament': '',
          'requires_restraint': null,
        },
      );
      await chooseBreed(tester, 'Spaniel');
      final body = await save(tester);
      expect(
        body['pref_body'],
        'Long comb',
        reason: 'saved instructions stay even if they match the old breed',
      );
      expect(body['pref_feet'], 'Keep round');
      expect(body['pref_face'], 'Natural face');
      expect(body['temperament'], '');
      expect(body['requires_restraint'], isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'handling is explicitly editable on a narrow ${dark ? 'dark' : 'light'} phone',
      (tester) async {
        await pump(
          tester,
          dark: dark,
          size: const Size(375, 812),
          existing: {'temperament': '', 'requires_restraint': null},
        );
        await expand(tester, 'Handling assessment');
        await tester.ensureVisible(find.text('Needs care'));
        await tester.tap(find.text('Needs care'));
        await tester.ensureVisible(find.text('Yes'));
        await tester.tap(find.text('Yes'));
        await tester.ensureVisible(field('Handling notes'));
        await tester.enterText(
          field('Handling notes'),
          'Use a muzzle for nails',
        );
        expect(tester.takeException(), isNull);
        final body = await save(tester);
        expect(body['temperament'], 'BITEY');
        expect(body['requires_restraint'], true);
        expect(body['temperament_notes'], 'Use a muzzle for nails');
      },
    );
  }

  testWidgets(
    'staff unassessed badge is neutral while withheld data stays hidden',
    (tester) async {
      for (final theme in [AppColors.lightTheme(), AppColors.darkTheme()]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: Column(
                children: [
                  TemperamentChip(temperament: '', label: ''),
                  TemperamentChip(temperament: null),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final label = tester.widget<Text>(find.text('Not assessed'));
        expect(
          label.style!.color,
          AppColors.temperamentColor('', brightness: theme.brightness),
        );
        expect(find.byType(Text), findsOneWidget);
      }
    },
  );
}
