import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/widgets/dog_silhouette.dart';

/// Golden tests for the problem-area picker.
///
/// The silhouette is the one screen where a wrong result is invisible to the
/// unit tests: the cell maths can be perfectly correct while the artwork fails
/// to load, renders at the wrong scale, or sits misaligned against the grid.
/// Rendering it and comparing pixels is the only way to catch that short of
/// putting it on a device.
///
/// Regenerate after deliberately changing the artwork or the grid:
///   flutter test --update-goldens
void main() {
  testWidgets('silhouette renders with the grid aligned', (tester) async {
    await tester.pumpWidget(_harness(const {}));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(DogSilhouettePicker),
      matchesGoldenFile('goldens/silhouette_empty.png'),
    );
  });

  testWidgets('selected cells mark the hindquarters', (tester) async {
    // Cells over the rear leg and hip — the kind of area an owner would mark
    // for "dislikes being brushed here".
    await tester.pumpWidget(_harness(const {'r3c8', 'r3c9', 'r4c8', 'r4c9'}));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(DogSilhouettePicker),
      matchesGoldenFile('goldens/silhouette_selected.png'),
    );
  });

  testWidgets('renders on a dark background', (tester) async {
    await tester.pumpWidget(_harness(const {'r0c1', 'r1c1'}, dark: true));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(DogSilhouettePicker),
      matchesGoldenFile('goldens/silhouette_dark.png'),
    );
  });
}

Widget _harness(Set<String> selected, {bool dark = false}) {
  return MaterialApp(
    theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
    home: Scaffold(
      backgroundColor: dark ? const Color(0xFF121212) : Colors.white,
      body: Center(
        child: SizedBox(
          width: 600,
          child: DogSilhouettePicker(
            selectedCells: selected,
            onChanged: (_) {},
          ),
        ),
      ),
    ),
  );
}
