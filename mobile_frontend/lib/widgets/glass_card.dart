import 'dart:ui';
import 'package:flutter/material.dart';

/// A premium glassmorphic card container with backdrop blur,
/// translucent backgrounds, and glowing border highlights.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;
  final Color? color;
  final double? borderWidth;
  final Color? borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius,
    this.color,
    this.borderWidth,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final br = borderRadius ?? BorderRadius.circular(16);
    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20.0, sigmaY: 20.0), // Stronger frosted glass blur for maximum readability
          child: Container(
            padding: padding ?? const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color ?? Colors.black.withOpacity(0.35), // Darker frosted glass base to contrast white text
              borderRadius: br,
              border: Border.all(
                color: borderColor ?? Colors.white.withOpacity(0.1), // Subtly glowing glass border
                width: borderWidth ?? 1.0,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
