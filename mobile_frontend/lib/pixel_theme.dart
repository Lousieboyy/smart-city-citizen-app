import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// "Wellness Calendar" theme system for Melaka Smart City app.
///
/// Cream canvas, soft rounded white cards with blurred shadows (no hard
/// borders), a deep olive-green primary and a warm coral accent for actions,
/// clean geometric sans typography. Every screen should pull its colors from
/// these tokens rather than hardcoding hex values, so a palette change here
/// is a palette change everywhere.
///
/// Kept the original static member names (`PixelTheme`, `pixelHeading`, etc.)
/// from the prior 8-bit theme so the ~10 screens that already consume them
/// didn't need call-site rewrites for this restyle — only the values inside
/// changed.
class PixelTheme {
  // ── Palette ────────────────────────────────────────────────────────────
  static const Color bgPrimary    = Color(0xFFF7F3EC); // Cream canvas
  static const Color bgSurface    = Color(0xFFFFFFFF); // White card surface
  static const Color bgInput      = Color(0xFFF1EDE4); // Filled input recess
  static const Color bgBorder     = Color(0xFFE7E1D5); // Hairline divider (soft, not a hard border)

  static const Color accentOrange     = Color(0xFFE08A5B); // Coral — sole action accent
  static const Color accentOrangeDark = Color(0xFFC06F45); // Coral pressed/shadow

  static const Color primaryGreen     = Color(0xFF3E4F35); // Deep olive — header/nav/primary
  static const Color primaryGreenDark = Color(0xFF2E3C27);

  static const Color surfaceDark = Color(0xFF232B3B); // Navy banner surface (e.g. mood/notification)

  // Secondary/info accent — used where the old theme used a neutral slate.
  static const Color accentCyan   = Color(0xFF6B7B8C);
  static const Color accentPink   = Color(0xFF6B7B8C);
  static const Color accentPurple = Color(0xFF6B7B8C);

  static const Color accentGreen  = Color(0xFF3F8F5E); // Resolved / success
  static const Color accentYellow = Color(0xFFD79A2C); // Pending / caution amber
  static const Color tagYellow    = Color(0xFFF4C15C); // Secondary tag pill
  static const Color alertRed     = Color(0xFFD16256); // Rejected / destructive
  static const Color alertRedDark = Color(0xFFAD4C42);

  static const Color textPrimary   = Color(0xFF2B2B28); // Near-black ink
  static const Color textSecondary = Color(0xFF8A8A85); // Muted gray
  static const Color textMuted     = Color(0xFFB7B3AC); // Light muted gray

  // ── Soft shadows ─────────────────────────────────────────────────────────
  static const List<BoxShadow> pixelShadow = [
    BoxShadow(
      color: Color(0x14000000),
      offset: Offset(0, 6),
      blurRadius: 20,
    ),
  ];

  static const List<BoxShadow> pixelShadowOrange = [
    BoxShadow(
      color: Color(0x40E08A5B),
      offset: Offset(0, 8),
      blurRadius: 20,
    ),
  ];

  static const List<BoxShadow> pixelShadowGlowOrange = [
    BoxShadow(
      color: Color(0x4DE08A5B),
      blurRadius: 20,
      spreadRadius: 1,
    ),
  ];

  // ── Typography ─────────────────────────────────────────────────────────────
  // Poppins: rounded geometric sans — headings, buttons, labels, badges.
  static TextStyle pixelHeading({double fontSize = 16, Color color = textPrimary}) {
    try {
      return GoogleFonts.poppins(
        fontSize: fontSize,
        color: color,
        fontWeight: FontWeight.w600,
        height: 1.3,
      );
    } catch (_) {
      return TextStyle(fontSize: fontSize, color: color, fontWeight: FontWeight.w600);
    }
  }

  static TextStyle pixelSubheading({double fontSize = 13, Color color = primaryGreen}) {
    try {
      return GoogleFonts.poppins(
        fontSize: fontSize,
        color: color,
        fontWeight: FontWeight.w600,
        height: 1.3,
      );
    } catch (_) {
      return TextStyle(fontSize: fontSize, color: color, fontWeight: FontWeight.w600);
    }
  }

  // Manrope: legible sans for body copy, descriptions, form inputs, list text.
  static TextStyle pixelBody({double fontSize = 15, Color color = textPrimary, FontWeight fontWeight = FontWeight.normal}) {
    try {
      return GoogleFonts.manrope(
        fontSize: fontSize,
        color: color,
        fontWeight: fontWeight,
        height: 1.4,
      );
    } catch (_) {
      return TextStyle(fontSize: fontSize, color: color, fontWeight: fontWeight);
    }
  }

  static TextStyle pixelCaption({double fontSize = 11, Color color = textSecondary}) {
    try {
      return GoogleFonts.manrope(
        fontSize: fontSize,
        color: color,
        fontWeight: FontWeight.w600,
        height: 1.2,
      );
    } catch (_) {
      return TextStyle(fontSize: fontSize, color: color, fontWeight: FontWeight.w600);
    }
  }

  // ── ThemeData Builder ──────────────────────────────────────────────────────
  static ThemeData buildTheme() {
    final bodyTheme = GoogleFonts.manropeTextTheme();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: bgPrimary,
      primaryColor: primaryGreen,
      colorScheme: const ColorScheme.light(
        primary: primaryGreen,
        secondary: accentOrange,
        surface: bgSurface,
        error: alertRed,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textPrimary,
      ),
      textTheme: bodyTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      fontFamily: GoogleFonts.manrope().fontFamily,
      appBarTheme: AppBarTheme(
        backgroundColor: bgPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 18,
          color: textPrimary,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: const IconThemeData(color: primaryGreen),
      ),
      cardTheme: CardThemeData(
        color: bgSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentOrange,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          textStyle: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryGreen,
          side: const BorderSide(color: bgBorder, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          textStyle: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryGreen,
          textStyle: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgInput,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: accentOrange, width: 1.5),
        ),
        labelStyle: GoogleFonts.manrope(color: textSecondary, fontSize: 15),
        hintStyle: GoogleFonts.manrope(color: textMuted, fontSize: 15),
        floatingLabelStyle: GoogleFonts.manrope(color: accentOrange, fontSize: 15),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceDark,
        contentTextStyle: GoogleFonts.manrope(color: Colors.white, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerColor: bgBorder,
      iconTheme: const IconThemeData(color: primaryGreen),
    );
  }
}
