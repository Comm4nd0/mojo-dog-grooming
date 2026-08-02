/// The app's locale, and the two pickers that quietly depend on it.
///
/// Jess reported that the date picker on the booking screen started its weeks
/// on a Sunday while the calendar on the screen behind it started on a Monday.
/// The calendar sets `startingDayOfWeek` on `TableCalendar` directly; the date
/// picker takes it from `MaterialLocalizations`, and the app declared no
/// locale at all, so Flutter fell back to en_US.
///
/// The same fallback is why the time picker offered AM/PM in an app that
/// formats every other time as HH:mm.
///
/// These tests assert against the real `kSupportedLocales` from main.dart
/// rather than a copy, so removing it from `MaterialApp` is the only way to
/// break them without them noticing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/main.dart';
import 'package:mojo_app/models/models.dart';

/// Builds the same localisation setup `MojoApp` does, and hands back a context
/// underneath it.
Future<BuildContext> _localisedContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: kSupportedLocales,
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

CurrentUser _user({String first = '', String last = ''}) => CurrentUser(
      id: 1,
      username: 'jess',
      email: 'info@mojoandco.uk',
      isStaff: true,
      firstName: first,
      lastName: last,
    );

void main() {
  group('What to call somebody', () {
    // Jess asked to be "Jessica Croll" rather than "jess". "jess" was her
    // *username* showing, because that was all the app had — and a username
    // is what she signs in with, so it is not the thing to change.
    test('a name is used when there is one', () {
      expect(_user(first: 'Jessica', last: 'Croll').displayName, 'Jessica Croll');
    });

    test('a first name on its own is enough', () {
      expect(_user(first: 'Jessica').displayName, 'Jessica');
    });

    test('the username is the fallback, not a blank', () {
      expect(_user().displayName, 'jess');
    });
  });

  test('the app supports exactly one locale, en_GB', () {
    expect(kSupportedLocales, const [Locale('en', 'GB')]);
  });

  testWidgets('weeks start on Monday', (tester) async {
    final context = await _localisedContext(tester);

    // 0 is Sunday, 1 is Monday. en_US gives 0, which is the bug.
    expect(MaterialLocalizations.of(context).firstDayOfWeekIndex, 1);
  });

  testWidgets('the clock is 24-hour, matching how times are written', (tester) async {
    final context = await _localisedContext(tester);

    expect(
      MaterialLocalizations.of(context).formatTimeOfDay(
        const TimeOfDay(hour: 14, minute: 30),
        alwaysUse24HourFormat: false,
      ),
      '14:30',
    );
  });
}
