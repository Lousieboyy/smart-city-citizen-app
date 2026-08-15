import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_frontend/localization/locale_manager.dart';
import 'package:mobile_frontend/screens/login_screen.dart';

/// Guards the language switch actually re-rendering the screen underneath it.
///
/// The subtle failure this covers: a `const` screen constructor returns the
/// same canonicalised instance on every rebuild, and Flutter skips updating a
/// child whose new widget is identical to the old one. The locale notifier then
/// fires, the app rebuilds, and the screen below keeps the old language.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocaleManager.localeNotifier.value = 'en';
  });

  const englishTagline = 'Citizen reporting made simple';
  const malayTagline = 'Laporan warga dipermudahkan';

  testWidgets('switching locale re-translates the live screen', (tester) async {
    // Mirrors main.dart: a ValueListenableBuilder on the locale, wrapping the
    // app, with a NON-const screen so the subtree can rebuild.
    await tester.pumpWidget(
      ValueListenableBuilder<String>(
        valueListenable: LocaleManager.localeNotifier,
        builder: (context, locale, _) => MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(englishTagline), findsOneWidget);
    expect(find.text(malayTagline), findsNothing);

    await LocaleManager.toggleLocale();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(malayTagline), findsOneWidget,
        reason: 'the screen should re-translate without a manual refresh');
    expect(find.text(englishTagline), findsNothing);
  });

  testWidgets('a const screen does NOT re-translate — the bug this guards against',
      (tester) async {
    // Documents why `home:` must not be const. If this ever starts passing with
    // the Malay string, Flutter changed its identical-widget short-circuit and
    // the comment in main.dart can go.
    await tester.pumpWidget(
      ValueListenableBuilder<String>(
        valueListenable: LocaleManager.localeNotifier,
        // ignore: prefer_const_constructors
        builder: (context, locale, _) => MaterialApp(home: const LoginScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(englishTagline), findsOneWidget);

    await LocaleManager.toggleLocale();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(englishTagline), findsOneWidget,
        reason: 'const instance is identical across rebuilds, so it is skipped');
  });
}
