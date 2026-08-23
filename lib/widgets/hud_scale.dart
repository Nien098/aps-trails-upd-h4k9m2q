import 'package:flutter/material.dart';

import '../services/settings.dart';

/// Scales a floating HUD element (a button, a button cluster, a status bar)
/// by [Settings.uiScale], live. Unlike the app-wide [IconTheme]/textScaler
/// bump in `main.dart` (which only grows the *glyph*/text inside an
/// already-fixed-size widget), this scales the whole rendered subtree —
/// including a [FloatingActionButton]'s own circular footprint, which
/// Android gives no continuous-size API for otherwise — so the actual tap
/// target grows too, not just what's drawn inside it.
///
/// [alignment] must match which screen corner/edge this cluster is anchored
/// to (e.g. bottomRight for a `Positioned(right: 16, bottom: 0, ...)` FAB
/// column) so scaling grows the cluster toward the visible map instead of
/// off the screen edge it's pinned to.
class HudScale extends StatelessWidget {
  const HudScale({super.key, required this.alignment, required this.child});

  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: Settings.instance.uiScale,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, alignment: alignment, child: child),
      child: child,
    );
  }
}
