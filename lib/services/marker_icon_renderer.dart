import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Rasterizes a Material [IconData] onto a colored circular badge (white
/// glyph, white ring, [background] fill) and returns it as PNG bytes, for
/// registering via [MapLibreMapController.addImage] and drawing as a
/// [SymbolOptions.iconImage] — MapLibre's annotation API takes actual images
/// for icons, not Flutter widgets/glyphs directly, so an icon has to be
/// drawn to a bitmap once before it can appear on the map. [size] is the
/// bitmap's pixel width/height (square) — kept well above the marker's
/// actual on-screen size (see [BookmarkLayer]'s `iconSize` scale-down) so it
/// stays sharp on high-density phone screens.
Future<Uint8List> renderMarkerIcon({
  required IconData icon,
  required Color background,
  double size = 96,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final radius = size / 2;
  final center = Offset(radius, radius);

  canvas.drawCircle(center, radius, Paint()..color = background);
  final strokeWidth = size * 0.06;
  canvas.drawCircle(
    center,
    radius - strokeWidth / 2,
    Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth,
  );

  final iconSize = size * 0.52;
  final painter = TextPainter(textDirection: TextDirection.ltr)
    ..text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: iconSize,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: Colors.white,
      ),
    )
    ..layout();
  painter.paint(
      canvas, Offset(radius - painter.width / 2, radius - painter.height / 2));

  final picture = recorder.endRecording();
  final image = await picture.toImage(size.toInt(), size.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
