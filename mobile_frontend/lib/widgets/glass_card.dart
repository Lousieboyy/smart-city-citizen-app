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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final br = borderRadius ?? BorderRadius.circular(8);
    return Container(
      margin: margin,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color ?? (isDark ? const Color(0xFF0F0F0F) : Colors.white), // Flat dark or white card background
        borderRadius: br,
        border: Border.all(
          color: borderColor ?? (isDark ? Colors.white24 : const Color(0xFFE7E5E4)), // Minimalist outline border
          width: borderWidth ?? 1.5,
        ),
      ),
      child: child,
    );
  }
}

