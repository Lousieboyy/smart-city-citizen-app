import 'package:flutter/material.dart';
import '../pixel_theme.dart';
import '../app_config.dart';

/// One shared status→color/icon/label mapping, used everywhere a report's
/// status is shown (dashboard, history, detail, map). Keeps the app to a
/// single, deliberately small palette: amber for pending, slate for the
/// three "in progress" states, green for resolved, red for rejected —
/// status differences beyond that are carried by the icon and label, not a
/// unique color per state.
class StatusConfig {
  final Color color;
  final Color bg;
  final IconData icon;
  final String label;
  const StatusConfig({
    required this.color,
    required this.bg,
    required this.icon,
    required this.label,
  });
}

StatusConfig getStatusConfig(String status) {
  switch (status) {
    case ReportStatus.resolved:
      return const StatusConfig(
          color: PixelTheme.accentGreen,
          bg: Color(0xFFEAF5EE),
          icon: Icons.check_circle_rounded,
          label: 'Resolved');
    case ReportStatus.inMaintenance:
      return const StatusConfig(
          color: PixelTheme.accentCyan,
          bg: Color(0xFFEEF1F4),
          icon: Icons.construction_rounded,
          label: 'In Maintenance');
    case ReportStatus.inProcess:
      return const StatusConfig(
          color: PixelTheme.accentCyan,
          bg: Color(0xFFEEF1F4),
          icon: Icons.autorenew_rounded,
          label: 'In Process');
    case ReportStatus.inReview:
      return const StatusConfig(
          color: PixelTheme.accentCyan,
          bg: Color(0xFFEEF1F4),
          icon: Icons.rate_review_rounded,
          label: 'In Review');
    case ReportStatus.rejected:
      return const StatusConfig(
          color: PixelTheme.alertRed,
          bg: Color(0xFFFBEDEB),
          icon: Icons.cancel_rounded,
          label: 'Rejected');
    default:
      return const StatusConfig(
          color: PixelTheme.accentYellow,
          bg: Color(0xFFFCF3E3),
          icon: Icons.hourglass_empty_rounded,
          label: 'Pending');
  }
}

/// Soft, rounded card with a blurred drop shadow — the base building block
/// of the wellness theme's white surfaces.
class PixelCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final double borderRadius;
  final double borderWidth;

  const PixelCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.color,
    this.borderColor,
    this.onTap,
    this.borderRadius = 20.0,
    this.borderWidth = 1.5,
  });

  @override
  Widget build(BuildContext context) {
    final cardWidget = Container(
      margin: margin,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color ?? PixelTheme.bgSurface,
        borderRadius: BorderRadius.circular(borderRadius),
        border: borderColor != null
            ? Border.all(color: borderColor!, width: borderWidth)
            : null,
        boxShadow: PixelTheme.pixelShadow,
      ),
      child: child,
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(borderRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(borderRadius),
          onTap: onTap,
          child: cardWidget,
        ),
      );
    }

    return cardWidget;
  }
}

/// Pill-shaped primary button matching the wellness theme's soft, rounded
/// CTA language — coral fill, blurred shadow, no hard border/offset.
class PixelButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final Color color;
  final Color textColor;
  final IconData? icon;
  final bool isLoading;
  final double height;
  final double fontSize;

  const PixelButton({
    super.key,
    required this.text,
    this.onPressed,
    this.color = PixelTheme.accentOrange,
    this.textColor = Colors.white,
    this.icon,
    this.isLoading = false,
    this.height = 52.0,
    this.fontSize = 15.0,
  });

  @override
  State<PixelButton> createState() => _PixelButtonState();
}

class _PixelButtonState extends State<PixelButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.onPressed == null ? PixelTheme.textMuted : widget.color;

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        if (!widget.isLoading && widget.onPressed != null) {
          widget.onPressed!();
        }
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: effectiveColor,
            borderRadius: BorderRadius.circular(widget.height / 2),
            boxShadow: _isPressed
                ? []
                : [
                    BoxShadow(
                      color: effectiveColor.withOpacity(0.35),
                      offset: const Offset(0, 8),
                      blurRadius: 18,
                    ),
                  ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (widget.isLoading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              else ...[
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 18, color: widget.textColor),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    widget.text,
                    textAlign: TextAlign.center,
                    style: PixelTheme.pixelHeading(
                      fontSize: widget.fontSize,
                      color: widget.textColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Derives a report's display priority from its category, mirroring the
/// heuristic already used on the map screen (category-based, since the
/// backend `priority` column exists but is never populated) so the whole
/// app agrees on one definition instead of each screen inventing its own.
class ReportPriority {
  final String label;
  final Color color;
  const ReportPriority(this.label, this.color);
}

ReportPriority getReportPriority(String category, String status) {
  if (status.trim().toLowerCase().contains('resolve')) {
    return const ReportPriority('Resolved', PixelTheme.accentGreen);
  }
  final cat = category.toLowerCase();
  if (cat.contains('damage') || cat.contains('drainage') || cat.contains('tree')) {
    return const ReportPriority('High', PixelTheme.alertRed);
  }
  return const ReportPriority('Medium', PixelTheme.accentYellow);
}

/// Soft tint pill badge (`Pending`, `High`, `Resolved`) — a tinted
/// background with matching colored text, no outline.
class PixelBadge extends StatelessWidget {
  final String text;
  final Color color;
  final Color textColor;
  final bool outlinedOnly;

  const PixelBadge({
    super.key,
    required this.text,
    required this.color,
    this.textColor = Colors.white,
    this.outlinedOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: outlinedOnly ? Colors.transparent : color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
        border: outlinedOnly ? Border.all(color: color, width: 1.2) : null,
      ),
      child: Text(
        text,
        style: PixelTheme.pixelCaption(
          fontSize: 11,
          color: color,
        ),
      ),
    );
  }
}

/// Rounded, connected-dot report progress tracker.
class PixelProgressBar extends StatelessWidget {
  final String currentStatus;

  const PixelProgressBar({
    super.key,
    required this.currentStatus,
  });

  static const List<String> steps = [
    'Submitted',
    'Reviewed',
    'Assigned',
    'Maintenance',
    'Resolved',
  ];

  int _getCompletedStepIndex(String status) {
    final s = status.trim().toLowerCase();
    if (s.contains('pending') || s.contains('submit')) return 0;
    if (s.contains('review')) return 1;
    if (s.contains('assign') || s.contains('process')) return 2;
    if (s.contains('maint') || s.contains('work')) return 3;
    if (s.contains('resolve') || s.contains('done')) return 4;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final completedIndex = _getCompletedStepIndex(currentStatus);
    final isFullyResolved = completedIndex == 4;
    final activeColor = isFullyResolved ? PixelTheme.accentGreen : PixelTheme.accentOrange;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: PixelTheme.bgSurface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: PixelTheme.pixelShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REPORT PROGRESS',
            style: PixelTheme.pixelCaption(
              fontSize: 11,
              color: PixelTheme.primaryGreen,
            ),
          ),
          const SizedBox(height: 18),
          Stack(
            children: [
              Positioned(
                left: 11,
                right: 11,
                top: 11,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: isFullyResolved ? PixelTheme.accentGreen : PixelTheme.bgInput,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(steps.length, (index) {
                  final isDone = index <= completedIndex;
                  return Column(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: isDone ? activeColor : PixelTheme.bgInput,
                          shape: BoxShape.circle,
                          boxShadow: isDone
                              ? [
                                  BoxShadow(
                                    color: activeColor.withOpacity(0.35),
                                    blurRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                        child: isDone
                            ? const Icon(
                                Icons.check,
                                size: 14,
                                color: Colors.white,
                              )
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        steps[index],
                        style: PixelTheme.pixelCaption(
                          fontSize: 9,
                          color: isDone
                              ? (index == completedIndex ? activeColor : PixelTheme.textSecondary)
                              : PixelTheme.textMuted,
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Soft rounded modal dialog, pill-button actions.
class PixelDialog extends StatelessWidget {
  final String title;
  final String bodyText;
  final String confirmText;
  final String cancelText;
  final VoidCallback onConfirm;
  final VoidCallback? onCancel;
  final Color headerColor;
  final Color confirmButtonColor;

  const PixelDialog({
    super.key,
    required this.title,
    required this.bodyText,
    required this.confirmText,
    required this.onConfirm,
    this.cancelText = 'Cancel',
    this.onCancel,
    this.headerColor = PixelTheme.alertRed,
    this.confirmButtonColor = PixelTheme.alertRed,
  });

  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required String bodyText,
    required String confirmText,
    required VoidCallback onConfirm,
    String cancelText = 'Cancel',
    Color headerColor = PixelTheme.alertRed,
    Color confirmButtonColor = PixelTheme.alertRed,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => PixelDialog(
        title: title,
        bodyText: bodyText,
        confirmText: confirmText,
        cancelText: cancelText,
        onConfirm: () {
          Navigator.of(ctx).pop();
          onConfirm();
        },
        onCancel: () => Navigator.of(ctx).pop(),
        headerColor: headerColor,
        confirmButtonColor: confirmButtonColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: PixelTheme.bgSurface,
          borderRadius: BorderRadius.circular(26),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              offset: Offset(0, 12),
              blurRadius: 30,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 26, 24, 0),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: headerColor.withOpacity(0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.warning_amber_rounded, size: 20, color: headerColor),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: PixelTheme.pixelHeading(
                        fontSize: 17,
                        color: PixelTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bodyText,
                    style: PixelTheme.pixelBody(
                      fontSize: 14,
                      color: PixelTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: PixelButton(
                          text: cancelText,
                          color: PixelTheme.bgInput,
                          textColor: PixelTheme.textSecondary,
                          height: 46,
                          fontSize: 13,
                          onPressed: onCancel ?? () => Navigator.of(context).pop(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PixelButton(
                          text: confirmText,
                          color: confirmButtonColor,
                          textColor: Colors.white,
                          height: 46,
                          fontSize: 13,
                          onPressed: onConfirm,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
