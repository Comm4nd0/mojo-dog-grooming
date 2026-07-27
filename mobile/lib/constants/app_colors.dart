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

  /// Temperament colours. Deliberately not green — green is the brand, and a
  /// temperament badge needs to read as a status, not a decoration.
  static const Color temperamentEasy = Color(0xFF2E7D32);
  static const Color temperamentFidgety = Color(0xFFB26A00);
  static const Color temperamentFeisty = Color(0xFFC62828);

  static Color temperamentColor(String? temperament) {
    switch (temperament) {
      case 'FEISTY':
        return temperamentFeisty;
      case 'FIDGETY':
        return temperamentFidgety;
      default:
        return temperamentEasy;
    }
  }

  // ── Typography ─────────────────────────────────────────────────────

  /// Display face for screen titles and dog names, matching the site's h1.
  static TextStyle display(double size, {Color? color, FontWeight? weight}) {
    return GoogleFonts.playfairDisplay(
      fontSize: size,
      height: 1.2,
      letterSpacing: 1.0,
      fontWeight: weight ?? FontWeight.w400,
      color: color ?? ink,
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
    return _base(scheme, background, _textTheme(ink, inkSecondary));
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
    return _base(scheme, darkBackground, _textTheme(Colors.white, const Color(0xFFB0B0B0)));
  }

  static ThemeData _base(ColorScheme scheme, Color scaffold, TextTheme text) {
    final isLight = scheme.brightness == Brightness.light;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      textTheme: text,
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
          side: BorderSide(color: isLight ? hairline : const Color(0xFF2E2E2E)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isLight ? surface : darkSurface,
        border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: isLight ? hairline : const Color(0xFF3A3A3A)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        labelStyle: GoogleFonts.montserrat(color: isLight ? inkSecondary : const Color(0xFFB0B0B0)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isLight ? surfaceTint : primaryDark,
        labelStyle: GoogleFonts.montserrat(fontSize: 12, fontWeight: FontWeight.w600),
        shape: const RoundedRectangleBorder(),
        side: BorderSide.none,
      ),
      dividerTheme: DividerThemeData(
        color: isLight ? hairline : const Color(0xFF2E2E2E),
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: isLight ? surfaceTint : primaryDark,
        indicatorShape: const RoundedRectangleBorder(),
        labelTextStyle: WidgetStatePropertyAll(
          GoogleFonts.montserrat(fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
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
