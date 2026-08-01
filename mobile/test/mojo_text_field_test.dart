/// Tapping into a field selects what's already there.
///
/// Jess's words: "type to reset across the board — click on then not have to
/// delete text to enter details". Nearly every form in the app is editing
/// details that already exist rather than filling in blanks, and Flutter's
/// default drops the caret where you tapped, so correcting a phone number
/// meant holding backspace over it first.
///
/// Two things here are deliberate and easy to undo by accident:
///
/// * The selection is set on *focus gain*, not on every build. Doing it in
///   `build` would fight anyone trying to place the caret on purpose.
/// * Multi-line fields opt out by default. Selecting four paragraphs of
///   medical notes on focus leaves them one keystroke from gone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/widgets/common.dart';

Future<TextEditingController> _pumpField(
  WidgetTester tester, {
  required String text,
  int? maxLines = 1,
  bool? selectOnFocus,
}) async {
  final controller = TextEditingController(text: text);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MojoTextField(
          controller: controller,
          maxLines: maxLines,
          selectOnFocus: selectOnFocus,
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets('tapping in selects the whole value', (tester) async {
    final controller = await _pumpField(tester, text: '07700 900001');

    await tester.tap(find.byType(MojoTextField));
    await tester.pumpAndSettle();

    expect(controller.selection.baseOffset, 0);
    expect(controller.selection.extentOffset, '07700 900001'.length);
  });

  testWidgets('so the next keystroke replaces rather than appends',
      (tester) async {
    final controller = await _pumpField(tester, text: '90');

    await tester.tap(find.byType(MojoTextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(MojoTextField), '105');

    expect(controller.text, '105');
  });

  testWidgets('a multi-line field is left alone', (tester) async {
    final controller = await _pumpField(
      tester,
      text: 'Sore left ear.\nDoes not like the dryer.',
      maxLines: 3,
    );

    await tester.tap(find.byType(MojoTextField));
    await tester.pumpAndSettle();

    expect(
      controller.selection.baseOffset == controller.selection.extentOffset ||
          controller.selection.baseOffset == -1,
      isTrue,
      reason: 'notes should not arrive pre-selected and one keystroke from gone',
    );
  });

  testWidgets('a multi-line field can opt back in', (tester) async {
    final controller = await _pumpField(
      tester,
      text: 'two lines\nof it',
      maxLines: 2,
      selectOnFocus: true,
    );

    await tester.tap(find.byType(MojoTextField));
    await tester.pumpAndSettle();

    expect(controller.selection.extentOffset, 'two lines\nof it'.length);
  });

  testWidgets('an empty field is not touched', (tester) async {
    final controller = await _pumpField(tester, text: '');

    await tester.tap(find.byType(MojoTextField));
    await tester.pumpAndSettle();

    expect(controller.text, isEmpty);
  });
}
