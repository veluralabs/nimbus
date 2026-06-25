import 'dart:ui';

import 'package:flutter/material.dart';

/// Frosted-glass surface: a blurred, translucent panel with a hairline border —
/// the core building block of the glassmorphic UI. Place over photos/gradients.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.blur = 24,
    this.radius = 26,
    this.opacity = 0.10,
    this.padding,
    this.border = true,
    this.color,
  });

  final Widget child;
  final double blur;
  final double radius;
  final double opacity;
  final EdgeInsetsGeometry? padding;
  final bool border;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // On light backgrounds a translucent white needs more opacity to read as a
    // frosted panel, and the hairline border should be dark instead of white.
    final tint = color ?? (isDark ? Colors.white : Colors.white);
    final fill = isDark ? opacity : (opacity + 0.55).clamp(0.0, 0.85);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.06);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: fill),
            borderRadius: BorderRadius.circular(radius),
            border: border ? Border.all(color: borderColor, width: 1) : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A soft vivid gradient backdrop that the glass layers blur over. Sits at the
/// back of each screen so frosted panels have something colourful to refract.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? const Color(0xFF0A0A12) : const Color(0xFFEEEAFF);
    final alpha = isDark ? 0.55 : 0.40;
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: base)),
        Positioned(
            top: -120,
            left: -80,
            child: _blob(const Color(0xFF7C5CFF), 360, alpha)),
        Positioned(
            top: 120,
            right: -120,
            child: _blob(const Color(0xFF00B4D8), 320, alpha)),
        Positioned(
            bottom: -140,
            left: -60,
            child: _blob(const Color(0xFFE84393), 340, alpha)),
        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }

  Widget _blob(Color c, double size, double alpha) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [c.withValues(alpha: alpha), c.withValues(alpha: 0.0)],
          ),
        ),
      );
}
