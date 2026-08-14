import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/bookmark.dart';
import 'marker_icon_renderer.dart';

/// Draws saved [Bookmark] pins on the map — each one its actual chosen icon
/// (see [Bookmark.icon]) on a category-colored circular badge, rasterized
/// via [renderMarkerIcon] and registered as a named map image, then drawn as
/// a single tappable [Symbol] annotation. One symbol per bookmark (not a
/// GeoJSON style layer) mirrors what [AuthorScreen] already does for cue
/// markers — reliable per-annotation tap detection via `onSymbolTapped` —
/// and bookmark counts are always small (tens, not thousands), so there's no
/// need for `queryRenderedFeaturesInRect`-style batched hit-testing.
class BookmarkLayer {
  BookmarkLayer(this.controller);

  final MapLibreMapController controller;

  final _symbolToBookmark = <String, Bookmark>{};
  final List<Symbol> _symbols = [];

  /// Names already registered via [controller.addImage] this session — an
  /// (icon, color) pairing is redrawn identically every time, so this skips
  /// re-rasterizing/re-registering one that's already on the map style
  /// (each registration is its own platform-channel round trip).
  final Set<String> _registeredImages = {};

  /// Registers the tap listener. Call once after the map is created.
  void listen(void Function(Bookmark) onTapped) {
    controller.onSymbolTapped.add((s) {
      final b = _symbolToBookmark[s.id];
      if (b != null) onTapped(b);
    });
  }

  String _imageName(Bookmark b) =>
      'bm_${b.icon.codePoint}_${b.category.colorHex.substring(1)}';

  Future<void> _ensureImage(Bookmark b) async {
    final name = _imageName(b);
    if (_registeredImages.contains(name)) return;
    final bytes = await renderMarkerIcon(
        icon: b.icon, background: b.category.color);
    await controller.addImage(name, bytes);
    _registeredImages.add(name);
  }

  /// Replaces every drawn marker with one per [bookmarks].
  Future<void> setBookmarks(List<Bookmark> bookmarks) async {
    if (_symbols.isNotEmpty) await controller.removeSymbols(_symbols);
    _symbols.clear();
    _symbolToBookmark.clear();

    for (final b in bookmarks) {
      await _ensureImage(b);
      final symbol = await controller.addSymbol(SymbolOptions(
        geometry: b.position,
        iconImage: _imageName(b),
        // The badge is rendered oversized (see renderMarkerIcon's `size`)
        // for sharpness, so it's scaled back down to a sensible on-screen
        // footprint here.
        iconSize: 0.4,
      ));
      _symbols.add(symbol);
      _symbolToBookmark[symbol.id] = b;
    }
  }

  Future<void> clear() => setBookmarks(const []);
}
