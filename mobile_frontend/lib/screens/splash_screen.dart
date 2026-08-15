import 'package:flutter/material.dart';
import '../pixel_theme.dart';
import '../widgets/background_decorator.dart';
import '../localization/locale_manager.dart';
import '../localization/app_strings.dart';

/// Launch screen shown while the app restores the saved session.
///
/// Purely presentational — it owns no navigation. `main.dart` decides how long
/// it stays up (session restore, plus a floor so the intro animation isn't cut
/// off mid-way on a fast device) and swaps it for Home or Login afterwards.
///
/// Built from widgets rather than an image asset so it scales cleanly at any
/// density and picks up palette changes in [PixelTheme] for free.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  /// How long the entrance animation runs. `main.dart` holds the splash at
  /// least this long so the sequence always finishes.
  static const Duration introDuration = Duration(milliseconds: 1400);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  /// Plays once: logo, wordmark, tagline, then the loading bar stagger in.
  late final AnimationController _intro;

  /// Loops: the halo breathing behind the logo and the indeterminate bar.
  late final AnimationController _pulse;

  late final Animation<double> _logoScale;
  late final Animation<double> _logoFade;
  late final Animation<double> _wordmarkFade;
  late final Animation<double> _wordmarkSlide;
  late final Animation<double> _taglineFade;
  late final Animation<double> _taglineSlide;
  late final Animation<double> _loaderFade;

  @override
  void initState() {
    super.initState();

    _intro = AnimationController(
      vsync: this,
      duration: SplashScreen.introDuration,
    );

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();

    // Staggered intervals over the single intro controller — cheaper than one
    // controller per element, and keeps the timing readable in one place.
    Animation<double> curve(double begin, double end, Curve c) =>
        CurvedAnimation(parent: _intro, curve: Interval(begin, end, curve: c));

    _logoFade      = curve(0.00, 0.45, Curves.easeOut);
    _logoScale     = Tween<double>(begin: 0.82, end: 1.0)
        .animate(curve(0.00, 0.55, Curves.easeOutBack));

    _wordmarkFade  = curve(0.30, 0.70, Curves.easeOut);
    _wordmarkSlide = Tween<double>(begin: 14, end: 0)
        .animate(curve(0.30, 0.70, Curves.easeOutCubic));

    _taglineFade   = curve(0.45, 0.85, Curves.easeOut);
    _taglineSlide  = Tween<double>(begin: 10, end: 0)
        .animate(curve(0.45, 0.85, Curves.easeOutCubic));

    _loaderFade    = curve(0.60, 1.00, Curves.easeOut);

    _intro.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PixelTheme.bgPrimary,
      body: BackgroundDecorator(
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),

              // ── Logo mark ──────────────────────────────────────────────
              FadeTransition(
                opacity: _logoFade,
                child: ScaleTransition(
                  scale: _logoScale,
                  child: _buildLogo(),
                ),
              ),
              const SizedBox(height: 28),

              // ── Wordmark ───────────────────────────────────────────────
              _slideFade(
                fade: _wordmarkFade,
                offset: _wordmarkSlide,
                child: Text(
                  'Smart City',
                  style: PixelTheme.pixelHeading(
                    fontSize: 28,
                    color: PixelTheme.primaryGreen,
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // ── Tagline ────────────────────────────────────────────────
              // The saved language is still loading while this screen is up,
              // so rebuild on the locale notifier: if the user picked Malay
              // last session the text swaps the moment prefs come back,
              // instead of sitting in English until the next screen.
              _slideFade(
                fade: _taglineFade,
                offset: _taglineSlide,
                child: ValueListenableBuilder<String>(
                  valueListenable: LocaleManager.localeNotifier,
                  builder: (context, _, _) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      // Shared app tagline — same copy the login header uses.
                      tr('login_tagline'),
                      textAlign: TextAlign.center,
                      style: PixelTheme.pixelBody(
                        fontSize: 14,
                        color: PixelTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),

              const Spacer(flex: 3),

              // ── Loading bar + footer ───────────────────────────────────
              FadeTransition(
                opacity: _loaderFade,
                child: Column(
                  children: [
                    _buildLoadingBar(),
                    const SizedBox(height: 18),
                    Text(
                      'Melaka Smart City',
                      style: PixelTheme.pixelCaption(
                        fontSize: 11,
                        color: PixelTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  /// Olive disc with a slowly breathing coral halo behind it.
  Widget _buildLogo() {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        // 0 -> 1 -> 0 over each loop, so the halo eases in and back out
        // instead of snapping at the wrap point.
        final t = Curves.easeInOut.transform(
          1 - (_pulse.value * 2 - 1).abs(),
        );
        return Container(
          width: 132,
          height: 132,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: PixelTheme.accentOrange.withValues(alpha: 0.05 + 0.05 * t),
          ),
          child: child,
        );
      },
      child: Container(
        width: 96,
        height: 96,
        decoration: const BoxDecoration(
          color: PixelTheme.primaryGreen,
          shape: BoxShape.circle,
          boxShadow: PixelTheme.pixelShadow,
        ),
        child: const Icon(
          Icons.apartment_rounded,
          size: 46,
          color: Colors.white,
        ),
      ),
    );
  }

  /// Indeterminate coral sliver sweeping along a soft track.
  Widget _buildLoadingBar() {
    const trackWidth = 132.0;
    const barWidth = 44.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Container(
        width: trackWidth,
        height: 5,
        color: PixelTheme.bgBorder,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            // Ease the sweep out to the far edge and back, so the bar never
            // teleports from right to left when the loop restarts.
            final t = Curves.easeInOut.transform(
              1 - (_pulse.value * 2 - 1).abs(),
            );
            return Align(
              alignment: Alignment(t * 2 - 1, 0),
              child: child,
            );
          },
          child: Container(
            width: barWidth,
            decoration: BoxDecoration(
              color: PixelTheme.accentOrange,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }

  /// Fade in while rising by [offset] logical pixels.
  Widget _slideFade({
    required Animation<double> fade,
    required Animation<double> offset,
    required Widget child,
  }) {
    return FadeTransition(
      opacity: fade,
      child: AnimatedBuilder(
        animation: offset,
        builder: (context, inner) => Transform.translate(
          offset: Offset(0, offset.value),
          child: inner,
        ),
        child: child,
      ),
    );
  }
}
