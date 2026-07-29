import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/widgets/dog_silhouette.dart';

/// Golden tests for the problem-area picker.
///
/// The silhouette is the one place where a wrong result is invisible to the
/// unit tests: the cell arithmetic can be perfectly correct while the artwork
/// fails to load, renders at the wrong scale, or sits misaligned against the
/// grid. Comparing pixels is the only way to catch that short of a device —
/// and it has already earned its keep, catching a version of this widget that
/// drew the grid over an empty frame.
///
/// Regenerate after deliberately changing the artwork or the grid, then look
/// at the PNGs before committing:
///   flutter test --update-goldens
void main() {
  testWidgets('silhouette renders with the grid aligned', (tester) async {
    await _pumpSettled(tester, _harness(const {}));
    await expectLater(
      find.byType(DogSilhouettePicker),
      matchesGoldenFile('goldens/silhouette_empty.png'),
    );
  });

  testWidgets('selected cells mark the hindquarters', (tester) async {
    // Cells over the rear leg and hip — the kind of area an owner would mark
    // for "dislikes being brushed here".
    await _pumpSettled(tester, _harness(const {'r3c8', 'r3c9', 'r4c8', 'r4c9'}));
    await expectLater(
      find.byType(DogSilhouettePicker),
      matchesGoldenFile('goldens/silhouette_selected.png'),
    );
  });

  testWidgets('renders on a dark background', (tester) async {
    await _pumpSettled(tester, _harness(const {'r0c1', 'r1c1'}, dark: true));
    await expectLater(
      find.byType(DogSilhouettePicker),
      matchesGoldenFile('goldens/silhouette_dark.png'),
    );
  });

  testWidgets('the artwork is actually painted, not just the grid', (tester) async {
    // Cheap guard that does not depend on golden files, so a machine with
    // different pixel output still catches a missing asset.
    await _pumpSettled(tester, _harness(const {}));
    expect(find.byType(SvgPicture), findsOneWidget);

    final image = await _capture(tester);
    expect(
      image.inkPixels,
      greaterThan(image.total * 0.10),
      reason: 'the silhouette covers roughly a third of the frame; far less '
          'than that means the SVG did not render',
    );
  });
}

/// Pump, then give the SVG a real chance to load before anything is captured.
///
/// `SvgPicture.asset` reads the asset bundle asynchronously. `pumpAndSettle`
/// drives the animation scheduler, not file I/O, so on its own it can capture
/// a frame where the artwork has not arrived — which is exactly how the first
/// set of goldens was generated correctly and then failed on the next run,
/// with the dog simply absent. `runAsync` lets the real I/O complete.
Future<void> _pumpSettled(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
  await tester.pumpAndSettle();
}

const _boundaryKey = ValueKey('silhouette-boundary');

/// Counts non-background pixels, as a proxy for "something was drawn".
///
/// `toImage` is genuinely asynchronous, so it has to run through `runAsync`;
/// awaiting it directly inside a widget test hangs until the test times out,
/// because the fake async zone never lets the real future complete.
Future<({int inkPixels, int total})> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));

  final result = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final data = await image.toByteData();
    final bytes = data!.buffer.asUint8List();

    var ink = 0;
    for (var i = 0; i < bytes.length; i += 4) {
      // Anything meaningfully darker than white counts as drawn.
      if (bytes[i] < 240 || bytes[i + 1] < 240 || bytes[i + 2] < 240) ink++;
    }
    return (inkPixels: ink, total: bytes.length ~/ 4);
  });

  return result!;
}

/// Carries the brand palette, which a bare `ThemeData(brightness: …)` does not.
///
/// The picker reads its highlight colour from that palette, so without it the
/// dark golden fell back to the light colours and passed while proving nothing
/// about dark mode.
///
/// It attaches the palette to a stock ThemeData rather than using
/// `AppColors.darkTheme()` wholesale, because the real theme builds its text
/// styles through google_fonts, which tries to fetch over the network and
/// makes the test fail offline. That the real themes carry these exact
/// palettes is asserted in theme_test.dart instead.
Widget _harness(Set<String> selected, {bool dark = false}) {
  return MaterialApp(
    theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light)
        .copyWith(extensions: [dark ? MojoPalette.dark : MojoPalette.light]),
    home: Scaffold(
      backgroundColor: dark ? AppColors.darkBackground : Colors.white,
      body: Center(
        child: SizedBox(
          width: 600,
          // RepaintBoundary so the capture covers the picker alone rather than
          // the surrounding scaffold. The background goes inside it: the dark
          // silhouette is painted in translucent white, so capturing it over a
          // transparent backdrop produced a golden in which the dog was
          // invisible and a missing asset would have looked identical.
          child: RepaintBoundary(
            key: _boundaryKey,
            child: ColoredBox(
              color: dark ? AppColors.darkBackground : Colors.white,
              child: DogSilhouettePicker(
                selectedCells: selected,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
