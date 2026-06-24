import 'package:flutter/material.dart';

/// A reusable backdrop decorator that wraps our screens.
/// Automatically resolves background color based on current theme brightness.
class BackgroundDecorator extends StatelessWidget {
  final Widget child;

  const BackgroundDecorator({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: isDark ? const Color(0xFF000000) : const Color(0xFFFAFAF9),
      child: child,
    );
  }
}

