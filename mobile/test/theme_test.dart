import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/constants/app_colors.dart';

/// Guards for the thing that went wrong in dark mode: colours chosen for a
/// white page and then painted on a near-black one.
///
/// The wordmark was the visible symptom — `AppColors.display()` defaulted its
/// colour to [AppColors.ink], so "Mojo and Co" was #151515 text on a #121212
/// background and simply was not there. Every screen title had the same bug;
/// nobody had noticed because the app is mostly used in light mode.
///
/// Unit tests could not see it, and the golden tests only covered the
/// silhouette, so these assert the two invariants that actually matter:
/// display text takes its colour from the theme, and every palette role has
/// enough contrast against the surface it is used on.
void main() {
  group('Display text', () {
    testWidgets('takes its colour from the theme rather than a fixed ink',
        (tester) async {
      for (final (label, theme, expected) in [
        ('light', AppColors.lightTheme(), AppColors.ink),
        ('dark', AppColors.darkTheme(), Colors.white),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Text('Mojo and Co', style: AppColors.display(34)),
            ),
          ),
        );
        // Material animates DefaultTextStyle across a theme change, so the
        // second pass through this loop would otherwise sample the colour
        // part-way from the light theme to the dark one.
        await tester.pumpAndSettle();

        final rendered = tester
            .renderObject<RenderParagraph>(find.text('Mojo and Co'))
            .text
            .style
            ?.color;

        expect(
          rendered,
          expected,
          reason: 'in $label mode the wordmark should paint in the theme\'s '
              'onSurface colour, not a hardcoded one',
        );
      }
    });

    testWidgets('is legible against the scaffold it is drawn on', (tester) async {
      for (final (label, theme) in [
        ('light', AppColors.lightTheme()),
        ('dark', AppColors.darkTheme()),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Text('Mojo and Co', style: AppColors.display(34)),
            ),
          ),
        );
        // Material animates DefaultTextStyle across a theme change, so the
        // second pass through this loop would otherwise sample the colour
        // part-way from the light theme to the dark one.
        await tester.pumpAndSettle();

        final rendered = tester
            .renderObject<RenderParagraph>(find.text('Mojo and Co'))
            .text
            .style!
            .color!;

        expect(
          contrastRatio(rendered, theme.scaffoldBackgroundColor),
          greaterThanOrEqualTo(4.5),
          reason: 'the wordmark is invisible in $label mode',
        );
      }
    });

    test('carries no colour of its own when none is asked for', () {
      // The inheriting-from-DefaultTextStyle behaviour above only works while
      // the style leaves colour unset. A default here would silently reinstate
      // the original bug, because Text merges its own style over the default.
      expect(AppColors.display(20).color, isNull);
      expect(AppColors.display(20, color: AppColors.primary).color,
          AppColors.primary);
    });
  });

  group('Palette contrast', () {
    // Thresholds are WCAG 2.1 AA: 4.5:1 for body text, 3:1 for large text.
    // `onTint` only ever carries the big display initials on an avatar tile,
    // which is large text; everything else is held to the body figure.
    const body = 4.5;
    const large = 3.0;

    for (final (label, palette, scaffold, onSurface) in [
      ('light', MojoPalette.light, AppColors.background, AppColors.ink),
      ('dark', MojoPalette.dark, AppColors.darkBackground, Colors.white),
    ]) {
      test('$label: muted text reads against the page', () {
        expect(contrastRatio(palette.muted, scaffold),
            greaterThanOrEqualTo(body));
      });

      test('$label: accent reads against the page', () {
        expect(contrastRatio(palette.accent, scaffold),
            greaterThanOrEqualTo(body));
      });

      test('$label: onTint reads against a tint block', () {
        expect(contrastRatio(palette.onTint, palette.tint),
            greaterThanOrEqualTo(large));
      });

      test('$label: body text reads against a header wash', () {
        expect(contrastRatio(onSurface, palette.tintWash),
            greaterThanOrEqualTo(body));
      });
    }

    // Jess: "whichever tab is highlighted, you can't see the text because the
    // background changes to the same colour as the text."
    //
    // It did, exactly. The chip theme set a label colour and no `selectedColor`,
    // so a selected chip fell back to `colorScheme.secondaryContainer` — a role
    // this scheme never sets, whose getter then returns `secondary`, which is
    // `primaryBright`. In dark mode `onTint` *is* `primaryBright`: the label was
    // painted in the colour of the background behind it, ratio 1.0. Light mode
    // was deep green on bright green, barely better.
    //
    // These read the theme rather than the palette on purpose. The bug was not
    // a bad colour — every value in the palette was fine — it was two of them
    // meeting through a default nobody had looked at, and only the assembled
    // ChipThemeData shows that.
    // The theme is built *inside* each test, never in the loop header:
    // `AppColors.lightTheme()` goes through google_fonts, and calling it during
    // collection is outside a test zone — the whole file fails to load.
    for (final (label, buildTheme, scaffold) in [
      ('light', AppColors.lightTheme, AppColors.background),
      ('dark', AppColors.darkTheme, AppColors.darkBackground),
    ]) {
      // Resolved the way Material resolves them, rather than asserted to be
      // non-null. Leaving `selectedColor` unset is not a config omission you
      // can spot by reading it back — it is a *green chip*, because the
      // fallback is `secondaryContainer`, and the point of the test is the
      // colour that ends up on screen. A null check here would have failed
      // with "null", which says nothing about why Jess could not read it.
      Color selectedFill(ThemeData theme) =>
          theme.chipTheme.selectedColor ?? theme.colorScheme.secondaryContainer;
      Color unselectedFill(ThemeData theme) => Color.alphaBlend(
            theme.chipTheme.backgroundColor ?? Colors.transparent,
            scaffold,
          );

      test('$label: a selected chip label reads on its own background', () {
        final theme = buildTheme();
        final fill = selectedFill(theme);
        // Both styles: which one a selected chip uses varies by chip type, so
        // neither is allowed to be the invisible one.
        for (final (state, style) in [
          ('secondary', theme.chipTheme.secondaryLabelStyle),
          ('primary', theme.chipTheme.labelStyle),
        ]) {
          final colour = style?.color ?? theme.colorScheme.onSurface;
          expect(
            contrastRatio(colour, fill),
            greaterThanOrEqualTo(body),
            reason: '$state label on the selected fill',
          );
        }
      });

      test('$label: an unselected chip label reads on the page', () {
        final theme = buildTheme();
        final colour = theme.chipTheme.labelStyle?.color ?? theme.colorScheme.onSurface;
        expect(
          contrastRatio(colour, unselectedFill(theme)),
          greaterThanOrEqualTo(body),
        );
      });

      test('$label: selected and unselected chips do not look alike', () {
        final theme = buildTheme();
        expect(
          contrastRatio(selectedFill(theme), unselectedFill(theme)),
          greaterThan(1.05),
          reason: 'selection has to be visible as well as legible',
        );
      });
    }

    // The scale went from three grades to five, so two new colours had to be
    // found between amber and red. A temperament badge is the one thing on a
    // dog's row that decides whether Jess braces before picking it up, and it
    // is drawn as text in the grade colour on a 12% wash of the same colour.
    // Both middles are darker than an obvious yellow for exactly this reason.
    const grades = ['EASY', 'WRIGGLY', 'FIDGETY', 'BITEY', 'FEISTY'];

    for (final (label, brightness, backgrounds) in [
      ('light', Brightness.light, [AppColors.background, AppColors.surface]),
      ('dark', Brightness.dark, [AppColors.darkBackground, AppColors.darkSurface]),
    ]) {
      for (final grade in grades) {
        test('$label: the $grade badge reads on its own wash', () {
          final colour = AppColors.temperamentColor(grade, brightness: brightness);
          // Checked against both the scaffold and a card, because a badge
          // appears on each and whichever gives the lower ratio is the one
          // that matters.
          for (final background in backgrounds) {
            final chip = Color.alphaBlend(colour.withValues(alpha: 0.12), background);
            expect(
              contrastRatio(colour, chip),
              greaterThanOrEqualTo(body),
              reason: '$grade on $background',
            );
          }
        });
      }

      test('$label: every grade has a colour of its own', () {
        final colours = {
          for (final g in grades) AppColors.temperamentColor(g, brightness: brightness),
        };
        expect(
          colours.length, grades.length,
          reason: 'two grades sharing a colour makes the badge useless',
        );
      });

      test('$label: an unrecognised grade is not painted as easy', () {
        // An older build against a newer server is exactly what happens
        // between an API deploy and an App Store release. Falling through to
        // the easy green there would tell Jess a bitey dog is fine to grab.
        final easy = AppColors.temperamentColor('EASY', brightness: brightness);
        expect(
          AppColors.temperamentColor('SOMETHING_NEW', brightness: brightness),
          isNot(easy),
        );
        expect(AppColors.temperamentColor(null, brightness: brightness), isNot(easy));
      });
    }

    test('the badge colours are not the same in both themes', () {
      // The whole reason these became a role: the light set sits between
      // 3.1:1 and 3.9:1 on the dark scaffold, which is the same class of bug
      // the deep green had.
      for (final grade in grades) {
        expect(
          AppColors.temperamentColor(grade, brightness: Brightness.dark),
          isNot(AppColors.temperamentColor(grade, brightness: Brightness.light)),
          reason: grade,
        );
      }
    });

    test('the two palettes are actually different', () {
      // A copy-paste that left dark pointing at the light constants would pass
      // every contrast check above and still ship the bug.
      expect(MojoPalette.dark.muted, isNot(MojoPalette.light.muted));
      expect(MojoPalette.dark.tint, isNot(MojoPalette.light.tint));
      expect(MojoPalette.dark.tintWash, isNot(MojoPalette.light.tintWash));
      expect(MojoPalette.dark.accent, isNot(MojoPalette.light.accent));
    });
  });

  group('Themes', () {
    test('both carry a palette, so context.mojo never falls back', () {
      // The `?? MojoPalette.light` fallback in the context extension exists for
      // bare test harnesses. If a real theme ever relied on it, dark mode would
      // quietly go back to light colours — which is exactly how the dark golden
      // test managed to pass while proving nothing.
      expect(AppColors.lightTheme().extension<MojoPalette>(), MojoPalette.light);
      expect(AppColors.darkTheme().extension<MojoPalette>(), MojoPalette.dark);
    });

    test('the snackbar separates from the scaffold behind it', () {
      for (final (label, theme) in [
        ('light', AppColors.lightTheme()),
        ('dark', AppColors.darkTheme()),
      ]) {
        final bar = theme.snackBarTheme.backgroundColor!;
        expect(
          contrastRatio(bar, theme.scaffoldBackgroundColor),
          greaterThan(1.2),
          reason: 'a floating snackbar is a shape, not just text — in $label '
              'mode it has to be distinguishable from the page',
        );
        expect(
          contrastRatio(theme.snackBarTheme.contentTextStyle!.color!, bar),
          greaterThanOrEqualTo(4.5),
        );
      }
    });
  });
}

/// WCAG 2.1 relative luminance.
double _luminance(Color color) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 2.1 contrast ratio, 1.0 (identical) to 21.0 (black on white).
///
/// Both colours must be opaque — every palette role is.
@visibleForTesting
double contrastRatio(Color foreground, Color background) {
  final a = _luminance(foreground);
  final b = _luminance(background);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}
