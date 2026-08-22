import 'package:flutter/material.dart';

/// Shows [builder]'s content as a centred card on a full *opaque* route,
/// instead of `showDialog`'s translucent barrier.
///
/// On Flutter Web, MapLibre's map is a real platform view (an actual DOM
/// element) — confirmed live in the desktop trail designer that a
/// translucent overlay (`showDialog`'s default barrier,
/// `showModalBottomSheet`) does *not* reliably stop clicks from reaching it
/// underneath, including clicks on the overlay's own buttons, which made
/// dialogs look permanently stuck. Flutter's engine hides a platform view
/// that's fully obscured by the route above it, but only when that route is
/// opaque — a `MaterialPageRoute` is `opaque: true` by default, which is
/// what actually triggers this; a `Dialog`'s barrier is visually translucent
/// and doesn't count. Used by every desktop-designer overlay that can
/// appear above the live map.
Future<T?> showOpaqueDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double maxWidth = 480,
  double maxHeight = 640,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      fullscreenDialog: true,
      builder: (ctx) => ColoredBox(
        color: Colors.black54,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
            child: Material(
              borderRadius: BorderRadius.circular(12),
              elevation: 8,
              clipBehavior: Clip.antiAlias,
              child: builder(ctx),
            ),
          ),
        ),
      ),
    ),
  );
}
