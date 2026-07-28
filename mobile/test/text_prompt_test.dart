import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/widgets/common.dart';

/// promptForText exists because the obvious version of this — caller owns the
/// controller, disposes it on the line after `await showDialog` — throws.
/// `showDialog` completes when Navigator.pop runs, not when the route has
/// finished animating away, so the TextField is still on screen and rebuilds
/// against a disposed controller. It took down "add a to-do" on the calendar.
///
/// These tests pumpAndSettle past the exit transition: that is the window the
/// old code died in, and an exception there fails the test on its own.
void main() {
  /// What the prompt handed back, and whether it has answered at all.
  late ({List<String?> value}) outcome;

  Future<void> openPrompt(WidgetTester tester, {String initialValue = ''}) async {
    outcome = (value: <String?>[]);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                outcome.value.add(await promptForText(
                  context,
                  title: 'Add to the list',
                  hintText: 'e.g. Order more shampoo',
                  initialValue: initialValue,
                  confirmLabel: 'ADD',
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add to the list'), findsOneWidget);
  }

  testWidgets('returns the trimmed text and survives the exit animation',
      (tester) async {
    await openPrompt(tester);
    await tester.enterText(find.byType(TextField), '  Order more shampoo  ');
    await tester.tap(find.text('ADD'));
    await tester.pumpAndSettle();

    expect(outcome.value, ['Order more shampoo']);

    // Reopening proves the first dialog tore down cleanly.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('cancelling returns null', (tester) async {
    await openPrompt(tester);
    await tester.enterText(find.byType(TextField), 'typed then abandoned');
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();

    expect(outcome.value, [null]);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('submitting from the keyboard closes it too', (tester) async {
    await openPrompt(tester, initialValue: 'Order more shampoo');
    expect(find.text('Order more shampoo'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(outcome.value, ['Order more shampoo']);
    expect(find.byType(TextField), findsNothing);
  });
}
