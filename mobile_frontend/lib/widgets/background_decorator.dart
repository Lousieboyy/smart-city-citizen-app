import 'package:flutter/material.dart';
import '../pixel_theme.dart';

/// A reusable backdrop decorator that wraps our screens with the flat cream
/// canvas of the wellness theme. Kept as a wrapper (rather than inlined into
/// every screen's Scaffold) so the canvas color stays a single source of
/// truth, matching how it was used under the previous pixel starfield theme.
class BackgroundDecorator extends StatelessWidget {
  final Widget child;

  const BackgroundDecorator({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: PixelTheme.bgPrimary,
      child: child,
    );
  }
}
