import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The four bottom-navigation icons, drawn as outline line-art.
///
/// Hand-drawn with [CustomPainter] rather than pulled from Material or an icon
/// font: the set is custom artwork, so there is no equivalent glyph to use.
/// Painting them keeps every stroke sharp at any size and lets each icon take
/// the navigation bar's active/inactive colour without shipping two bitmaps.
enum NavIconType { home, map, history, profile }

class NavIcon extends StatelessWidget {
  const NavIcon({
    super.key,
    required this.type,
    required this.color,
    this.size = 24,
    this.background = Colors.white,
  });

  final NavIconType type;
  final Color color;
  final double size;

  /// Surface the icon sits on. Used to punch the history icon's hourglass badge
  /// out of the page behind it, so the two shapes stay readable where they overlap.
  final Color background;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _NavIconPainter(type: type, color: color, background: background),
      ),
    );
  }
}

class _NavIconPainter extends CustomPainter {
  _NavIconPainter({
    required this.type,
    required this.color,
    required this.background,
  });

  final NavIconType type;
  final Color color;
  final Color background;

  /// Everything below is authored on a 24x24 grid and scaled to fit.
  static const double _canvas = 24.0;
  static const double _stroke = 1.7;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _canvas, size.height / _canvas);

    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (type) {
      case NavIconType.home:
        _paintHome(canvas, pen);
      case NavIconType.map:
        _paintMap(canvas, pen);
      case NavIconType.history:
        _paintHistory(canvas, pen);
      case NavIconType.profile:
        _paintProfile(canvas, pen);
    }

    canvas.restore();
  }

  /// Pitched roof with a chimney, walls, and a door.
  void _paintHome(Canvas canvas, Paint pen) {
    final roof = Path()
      ..moveTo(3.2, 11.3)
      ..lineTo(12.0, 3.5)
      ..lineTo(20.8, 11.3)
      ..close();
    canvas.drawPath(roof, pen);

    // Chimney, riding the right-hand slope.
    final chimney = Path()
      ..moveTo(16.3, 7.2)
      ..lineTo(16.3, 5.4)
      ..lineTo(18.3, 5.4)
      ..lineTo(18.3, 8.9);
    canvas.drawPath(chimney, pen);

    // Walls. The roof's base line already closes the top.
    final walls = Path()
      ..moveTo(5.6, 11.3)
      ..lineTo(5.6, 20.7)
      ..lineTo(18.4, 20.7)
      ..lineTo(18.4, 11.3);
    canvas.drawPath(walls, pen);

    canvas.drawRect(const Rect.fromLTRB(10.1, 14.9, 13.9, 18.5), pen);
  }

  /// Location pin with concentric rings, standing on a map card.
  void _paintMap(Canvas canvas, Paint pen) {
    // Map card. The taper is kept shallow on purpose — splaying the sides any
    // harder makes the silhouette read as a mountain range rather than a map.
    final card = Path()
      ..moveTo(5.2, 12.9)
      ..lineTo(4.2, 20.7)
      ..lineTo(19.8, 20.7)
      ..lineTo(18.8, 12.9);
    canvas.drawPath(card, pen);

    // Top edge, broken where the pin's tail passes through it.
    canvas.drawLine(const Offset(5.2, 12.9), const Offset(10.5, 12.9), pen);
    canvas.drawLine(const Offset(13.5, 12.9), const Offset(18.8, 12.9), pen);

    // Pin: an arc left open at the base, closed off into a point.
    const centre = Offset(12.0, 7.3);
    const radius = 5.0;
    const start = 0.7222 * math.pi; // ~130 degrees
    const sweep = 1.5556 * math.pi; // all but the base

    final pin = Path()
      ..arcTo(Rect.fromCircle(center: centre, radius: radius), start, sweep, true)
      ..lineTo(12.0, 14.1)
      ..close();
    canvas.drawPath(pin, pen);

    canvas.drawCircle(centre, 2.5, pen);

    // Fold mark on the card.
    canvas.drawLine(const Offset(13.8, 18.2), const Offset(17.2, 18.2), pen);
  }

  /// Ruled document resting on a shelf, with an hourglass badge.
  void _paintHistory(Canvas canvas, Paint pen) {
    canvas.drawRect(const Rect.fromLTRB(5.0, 3.0, 17.0, 17.2), pen);

    // Margin rule, kept short of both edges so it doesn't read as spiral binding.
    canvas.drawLine(const Offset(7.5, 5.6), const Offset(7.5, 14.6), pen);

    // Body text. Three lines, not four — at 24px any more turns into a smear.
    for (final y in const [7.0, 10.0, 13.0]) {
      canvas.drawLine(Offset(9.0, y), Offset(14.8, y), pen);
    }

    // Surface the document rests on. Deliberately a single rule with no end
    // ticks: adding them turned the whole icon into what looked like a trolley.
    canvas.drawLine(const Offset(3.0, 19.3), const Offset(19.0, 19.3), pen);

    // Hourglass badge, knocked out of the artwork behind it so the overlap reads
    // as one shape sitting in front of another rather than a tangle of lines.
    const badge = Offset(17.8, 16.9);
    const badgeRadius = 4.7;
    canvas.drawCircle(badge, badgeRadius, Paint()..color = background);
    canvas.drawCircle(badge, badgeRadius, pen);

    final glass = Paint()
      ..color = pen.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke * 0.85
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawLine(const Offset(15.9, 14.5), const Offset(19.7, 14.5), glass);
    canvas.drawLine(const Offset(15.9, 19.3), const Offset(19.7, 19.3), glass);
    canvas.drawLine(const Offset(16.2, 14.7), const Offset(19.4, 19.1), glass);
    canvas.drawLine(const Offset(19.4, 14.7), const Offset(16.2, 19.1), glass);
  }

  /// Head and shoulders inside a ring.
  void _paintProfile(Canvas canvas, Paint pen) {
    const centre = Offset(12.0, 12.0);
    const radius = 9.3;

    canvas.drawCircle(centre, radius, pen);
    canvas.drawCircle(const Offset(12.0, 9.7), 3.4, pen);

    // Shoulders, trimmed to the ring so they meet its edge instead of spilling past it.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: centre, radius: radius - _stroke / 2)));
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(12.0, 21.2), radius: 6.1),
      math.pi,
      math.pi,
      false,
      pen,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NavIconPainter old) =>
      old.type != type || old.color != color || old.background != background;
}
