import 'package:flutter/material.dart';

/// A reusable backdrop decorator that wraps our screens in a deep,
/// premium space gradient (slate/indigo/dark purple). This gradient
/// provides the ideal visual backing to show glassmorphic blur refractions.
class BackgroundDecorator extends StatelessWidget {
  final Widget child;

  const BackgroundDecorator({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0F172A), // slate-900
            Color(0xFF1E1B4B), // deep indigo
            Color(0xFF2E1065), // midnight purple
          ],
        ),
      ),
      child: child,
    );
  }
}
