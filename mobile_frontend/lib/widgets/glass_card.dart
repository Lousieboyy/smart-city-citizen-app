import 'package:flutter/material.dart';
import '../pixel_theme.dart';

/// A soft, rounded white card with a blurred drop shadow — no hard border.
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
    final br = borderRadius ?? BorderRadius.circular(22);
    return Container(
      margin: margin,
      padding: padding ?? const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color ?? PixelTheme.bgSurface,
        borderRadius: br,
        border: borderColor != null
            ? Border.all(color: borderColor!, width: borderWidth ?? 1.5)
            : null,
        boxShadow: PixelTheme.pixelShadow,
      ),
      child: child,
    );
  }
}
