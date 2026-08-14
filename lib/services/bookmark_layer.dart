import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/bookmark.dart';

/// Draws saved [Bookmark] pins on the map: a category-colored circle plus a
/// one-letter glyph, using the plugin's circle/symbol annotation API (not a
/// GeoJSON style layer) so each marker gets its own tappable id — the same
/// approach [AuthorScreen] already uses for cue markers (see
/// `_onCueTapped`/`c.onSymbolTapped`), which is known to report taps
/// reliably; a data-driven GeoJSON layer (like [CueLayer]/[BoundaryLayer])
/// would need `queryRenderedFeaturesInRect` plumbing for no benefit here,
/// since bookmark counts are always small (tens, not thousands).
class BookmarkLayer {
  BookmarkLayer(this.controller);

  final MapLibreMapController controller;

  final _circleToBookmark = <String, Bookmark>{};
  final _symbolToBookmark = <String, Bookmark>{};
  final List<Circle> _circles = [];
  final List<Symbol> _symbols = [];

  /// Registers the tap listeners. Call once after the map is created.
  void listen(void Function(Bookmark) onTapped) {
    controller.onCircleTapped.add((c) {
      final b = _circleToBookmark[c.id];
      if (b != null) onTapped(b);
    });
    controller.onSymbolTapped.add((s) {
      final b = _symbolToBookmark[s.id];
      if (b != null) onTapped(b);
    });
  }

  /// Replaces every drawn marker with one per [bookmarks].
  Future<void> setBookmarks(List<Bookmark> bookmarks) async {
    if (_circles.isNotEmpty) await controller.removeCircles(_circles);
    if (_symbols.isNotEmpty) await controller.removeSymbols(_symbols);
    _circles.clear();
    _symbols.clear();
    _circleToBookmark.clear();
    _symbolToBookmark.clear();

    for (final b in bookmarks) {
      final circle = await controller.addCircle(CircleOptions(
        geometry: b.position,
        circleRadius: 12,
        circleColor: b.category.colorHex,
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 2,
      ));
      final symbol = await controller.addSymbol(SymbolOptions(
        geometry: b.position,
        textField: b.category.glyph,
        textSize: 13,
        textColor: '#ffffff',
        // No halo — the circle underneath is the "background" for this
        // letter, unlike CueLayer's numbered markers which sit on the bare
        // basemap and need one for contrast.
      ));
      _circles.add(circle);
      _symbols.add(symbol);
      _circleToBookmark[circle.id] = b;
      _symbolToBookmark[symbol.id] = b;
    }
  }

  Future<void> clear() => setBookmarks(const []);
}
