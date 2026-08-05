import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Mojo and Co brand palette and theme.
///
/// The values here were sampled from the live site at mojoandco.uk rather than
/// eyeballed: Playfair Display for headings, Montserrat for everything else,
/// a deep green for text accents and the bright green from the site's
/// "Send Message" button for calls to action.
///
/// One rule worth keeping: [primaryBright] carries **black** text, never
/// white. White on that green fails contrast badly; black on it passes
/// comfortably, and it matches the website's own button.
/// The brand colours that cannot be one fixed value, because they only make
/// sense relative to the background they sit on.
///
/// [AppColors] keeps the raw brand constants — they are the palette, and they
/// do not change. But a *role* like "muted caption text" or "pale green block"
/// resolves to a different constant in each theme, and hardcoding the light
/// one is how the app ended up unreadable in dark mode. Read these through
/// `context.mojo` rather than reaching for [AppColors.inkSecondary] and
/// friends directly.
@immutable
class MojoPalette extends ThemeExtension<MojoPalette> {
  const MojoPalette({
    required this.muted,
    required this.tint,
    required this.onTint,
    required this.tintWash,
    required this.hairline,
    required this.accent,
  });

  /// Secondary/caption text and inactive icons.
  final Color muted;

  /// Solid pale-green block — avatars, initials tiles, today's calendar cell.
  final Color tint;

  /// Text and icons drawn on a [tint] block.
  final Color onTint;

  /// The faint green band behind a profile header. Solid rather than a
  /// translucent [tint]: composited over a dark scaffold, a 40% pale green
  /// turns into a murky mid-tone that nothing reads well against.
  final Color tintWash;

  /// Borders, dividers and input outlines.
  final Color hairline;

  /// Brand green for text and icons on the page background. The deep green is
  /// only legible on light; dark mode needs the bright one.
  final Color accent;

  static const MojoPalette light = MojoPalette(
    muted: AppColors.inkSecondary,
    tint: AppColors.surfaceTint,
    onTint: AppColors.primary,
    tintWash: Color(0xFFEDFFEE),
    hairline: AppColors.hairline,
    accent: AppColors.primary,
  );

  static const MojoPalette dark = MojoPalette(
    muted: Color(0xFFB0B0B0),
    tint: AppColors.primaryDark,
    onTint: AppColors.primaryBright,
    tintWash: Color(0xFF16301A),
    hairline: Color(0xFF2E2E2E),
    accent: AppColors.primaryBright,
  );

  @override
  MojoPalette copyWith({
    Color? muted,
    Color? tint,
    Color? onTint,
    Color? tintWash,
    Color? hairline,
    Color? accent,
  }) {
    return MojoPalette(
      muted: muted ?? this.muted,
      tint: tint ?? this.tint,
      onTint: onTint ?? this.onTint,
      tintWash: tintWash ?? this.tintWash,
      hairline: hairline ?? this.hairline,
      accent: accent ?? this.accent,
    );
  }

  @override
  MojoPalette lerp(covariant MojoPalette? other, double t) {
    if (other == null) return this;
    return MojoPalette(
      muted: Color.lerp(muted, other.muted, t)!,
      tint: Color.lerp(tint, other.tint, t)!,
      onTint: Color.lerp(onTint, other.onTint, t)!,
      tintWash: Color.lerp(tintWash, other.tintWash, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
    );
  }
}

extension MojoPaletteContext on BuildContext {
  /// The brand's brightness-dependent colours for the theme in force here.
  ///
  /// Falls back to the light palette rather than throwing, so a widget lifted
  /// into a bare `MaterialApp` in a test still renders.
  MojoPalette get mojo =>
      Theme.of(this).extension<MojoPalette>() ?? MojoPalette.light;

  /// The badge colour for a temperament grade, for the theme in force here.
  ///
  /// Use this rather than [AppColors.temperamentColor] directly — the bare
  /// call defaults to the light set, which is how the badges ended up at
  /// 3.1:1 on the dark scaffold.
  Color temperamentColour(String? grade) =>
      AppColors.temperamentColor(grade, brightness: Theme.of(this).brightness);
}

class AppColors {
  AppColors._();

  // ── Brand greens ───────────────────────────────────────────────────
  /// Deep green — headings, icons, selected states. 5.3:1 on white (AA).
  static const Color primary = Color(0xFF01821B);

  /// Darker green for pressed states and dark-theme surfaces.
  static const Color primaryDark = Color(0xFF015412);

  /// The website's CTA green. Always pair with black text.
  static const Color primaryBright = Color(0xFF02D42C);

  /// Pale green wash for chips, selected grid cells and highlight rows.
  static const Color surfaceTint = Color(0xFFD2FFD4);

  // ── Neutrals ───────────────────────────────────────────────────────
  static const Color ink = Color(0xFF151515);
  static const Color inkSecondary = Color(0xFF5E5E5E);
  static const Color hairline = Color(0xFFE2E2E2);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFFAFAFA);

  static const Color darkSurface = Color(0xFF1B1B1B);
  static const Color darkBackground = Color(0xFF121212);

  // ── Semantic ───────────────────────────────────────────────────────
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFB26A00);
  static const Color error = Color(0xFFC62828);

  /// Temperament colours, easiest to hardest. Deliberately not green — green
  /// is the brand, and a temperament badge needs to read as a status, not a
  /// decoration.
  ///
  /// Five grades, so the ramp runs green → olive → amber → burnt orange → red.
  ///
  /// **Two sets, because these are a role, not a constant.** The badge draws
  /// the grade name as *text* in this colour on a 12%-alpha wash of itself, so
  /// it has to clear AA against whatever is behind it — and the original three
  /// were only ever checked on white. On the dark scaffold they came out
  /// between 3.1:1 and 3.9:1, which is the same class of bug CLAUDE.md
  /// describes for the deep green. Read them through
  /// [MojoPaletteContext.temperamentColour], never directly.
  static const Color temperamentEasy = Color(0xFF2A732E);
  static const Color temperamentWriggly = Color(0xFF526E1B);
  static const Color temperamentFidgety = Color(0xFF925700);
  static const Color temperamentBitey = Color(0xFFAE420B);
  static const Color temperamentFeisty = Color(0xFFBE2626);

  static const Color temperamentEasyDark = Color(0xFF66A069);
  static const Color temperamentWrigglyDark = Color(0xFF849B56);
  static const Color temperamentFidgetyDark = Color(0xFFC18833);
  static const Color temperamentBiteyDark = Color(0xFFCD8159);
  static const Color temperamentFeistyDark = Color(0xFFDB7575);

  /// Neutral, for a grade this build has never heard of.
  static const Color temperamentUnknown = inkSecondary;
  static const Color temperamentUnknownDark = Color(0xFFB0B0B0);

  /// The colour for a grade code, in the given theme.
  ///
  /// The default is **not** the easy green. It used to be, so an older build
  /// talking to a newer server — exactly what happens between an API deploy
  /// and an App Store release — would paint an unrecognised grade reassuring
  /// green. Grey says "I don't know this one", which is true.
  static Color temperamentColor(
    String? temperament, {
    Brightness brightness = Brightness.light,
  }) {
    final isDark = brightness == Brightness.dark;
    switch (temperament) {
      case 'EASY':
        return isDark ? temperamentEasyDark : temperamentEasy;
      case 'WRIGGLY':
        return isDark ? temperamentWrigglyDark : temperamentWriggly;
      case 'FIDGETY':
        return isDark ? temperamentFidgetyDark : temperamentFidgety;
      case 'BITEY':
        return isDark ? temperamentBiteyDark : temperamentBitey;
      case 'FEISTY':
        return isDark ? temperamentFeistyDark : temperamentFeisty;
      default:
        return isDark ? temperamentUnknownDark : temperamentUnknown;
    }
  }

  // ── Typography ─────────────────────────────────────────────────────

  /// Display face for screen titles and dog names, matching the site's h1.
  ///
  /// [color] is left null when not given, so the style inherits from the
  /// ambient `DefaultTextStyle` — `Text` merges its own style over that — and
  /// therefore lands on the theme's `onSurface`. It used to default to [ink],
  /// which is the whole reason the wordmark and every screen title vanished in
  /// dark mode: near-black text painted on a near-black background. Do not
  /// reintroduce a default here; pass a colour explicitly at the call sites
  /// that genuinely need one.
  static TextStyle display(double size, {Color? color, FontWeight? weight}) {
    return GoogleFonts.playfairDisplay(
      fontSize: size,
      height: 1.2,
      letterSpacing: 1.0,
      fontWeight: weight ?? FontWeight.w400,
      color: color,
    );
  }

  /// The site's button treatment: uppercase, heavy, widely tracked.
  static TextStyle get buttonLabel => GoogleFonts.montserrat(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 3.0,
        color: Colors.black,
      );

  static TextTheme _textTheme(Color onSurface, Color muted) {
    final body = GoogleFonts.montserratTextTheme();
    return body
        .copyWith(
          displayLarge: display(40, color: onSurface),
          displayMedium: display(32, color: onSurface),
          headlineLarge: display(28, color: onSurface),
          headlineMedium: display(24, color: onSurface),
          headlineSmall: display(20, color: onSurface),
          titleLarge: GoogleFonts.montserrat(
            fontSize: 17, fontWeight: FontWeight.w600, color: onSurface,
          ),
          titleMedium: GoogleFonts.montserrat(
            fontSize: 15, fontWeight: FontWeight.w600, color: onSurface,
          ),
          bodyLarge: GoogleFonts.montserrat(fontSize: 15, color: onSurface, height: 1.45),
          bodyMedium: GoogleFonts.montserrat(fontSize: 14, color: onSurface, height: 1.45),
          bodySmall: GoogleFonts.montserrat(fontSize: 12.5, color: muted, height: 1.4),
          labelLarge: GoogleFonts.montserrat(
            fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: onSurface,
          ),
        )
        .apply(bodyColor: onSurface, displayColor: onSurface);
  }

  static ThemeData lightTheme() {
    final scheme = const ColorScheme.light(
      primary: primary,
      onPrimary: Colors.white,
      secondary: primaryBright,
      onSecondary: Colors.black,
      surface: surface,
      onSurface: ink,
      error: error,
      onError: Colors.white,
    );
    return _base(scheme, background, _textTheme(ink, MojoPalette.light.muted),
        MojoPalette.light);
  }

  static ThemeData darkTheme() {
    final scheme = const ColorScheme.dark(
      primary: primaryBright,
      onPrimary: Colors.black,
      secondary: primaryBright,
      onSecondary: Colors.black,
      surface: darkSurface,
      onSurface: Colors.white,
      error: Color(0xFFEF9A9A),
      onError: Colors.black,
    );
    return _base(scheme, darkBackground, _textTheme(Colors.white, MojoPalette.dark.muted),
        MojoPalette.dark);
  }

  static ThemeData _base(
    ColorScheme scheme,
    Color scaffold,
    TextTheme text,
    MojoPalette palette,
  ) {
    final isLight = scheme.brightness == Brightness.light;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      textTheme: text,
      extensions: <ThemeExtension<dynamic>>[palette],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: display(22, color: scheme.onSurface),
      ),
      // Square corners throughout — the website uses no rounding on its
      // buttons, and softening it here would read as a different brand.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBright,
          foregroundColor: Colors.black,
          elevation: 0,
          minimumSize: const Size(64, 48),
          shape: const RoundedRectangleBorder(),
          textStyle: buttonLabel,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          minimumSize: const Size(64, 48),
          side: BorderSide(color: scheme.primary),
          shape: const RoundedRectangleBorder(),
          textStyle: GoogleFonts.montserrat(
            fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 2.0,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: GoogleFonts.montserrat(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryBright,
        foregroundColor: Colors.black,
        elevation: 2,
        shape: RoundedRectangleBorder(),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: palette.hairline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: isLight ? palette.hairline : const Color(0xFF3A3A3A)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        labelStyle: GoogleFonts.montserrat(color: palette.muted),
      ),
      // **`selectedColor` is not optional here.** Without it a selected chip
      // falls back to `colorScheme.secondaryContainer`, and this scheme never
      // sets that role — Flutter's getter then returns `secondary`, which is
      // `primaryBright`. In dark mode `onTint` is *also* `primaryBright`, so
      // the label was drawn in exactly the colour of the background behind it
      // and every selected filter chip went blank. Light mode was no better:
      // deep green on bright green is about 2:1.
      //
      // So both states are stated outright rather than inherited. Unselected
      // is an outline on the page, selected is a filled `tint` block, and one
      // label colour reads on both — `onTint` is the documented foreground for
      // `tint`, and it is the accent on the surface. The checkmark stays on:
      // colour alone should not be what tells you a chip is selected.
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: palette.tint,
        checkmarkColor: palette.onTint,
        labelStyle: GoogleFonts.montserrat(
          fontSize: 12, fontWeight: FontWeight.w600, color: palette.onTint,
        ),
        secondaryLabelStyle: GoogleFonts.montserrat(
          fontSize: 12, fontWeight: FontWeight.w700, color: palette.onTint,
        ),
        iconTheme: IconThemeData(color: palette.onTint, size: 18),
        shape: const RoundedRectangleBorder(),
        side: BorderSide(color: palette.hairline),
      ),
      dividerTheme: DividerThemeData(
        color: palette.hairline,
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: palette.tint,
        indicatorShape: const RoundedRectangleBorder(),
        labelTextStyle: WidgetStatePropertyAll(
          GoogleFonts.montserrat(fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
      ),
      // A floating snackbar has to separate from the scaffold behind it. In
      // light that means the near-black ink; in dark, ink is a shade off the
      // background and the bar all but disappears, so it goes lighter instead.
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isLight ? ink : const Color(0xFF383838),
        contentTextStyle: GoogleFonts.montserrat(color: Colors.white, fontSize: 14),
        shape: const RoundedRectangleBorder(),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: const DialogThemeData(
        shape: RoundedRectangleBorder(),
      ),
    );
  }
}
