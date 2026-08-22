import 'package:maplibre_gl/maplibre_gl.dart';

/// Web build of [RouteGraphStore] — see `route_graph_store.dart`'s
/// conditional export. There's no bundled `route_graph.sqlite` on web (no
/// `dart:io`/`sqlite3` there at all), so this always reports an empty
/// network. [TrailRouter] treats that exactly like "nothing offline found
/// in this area" — it still routes fine using whatever's currently
/// rendered on the live map (`queryRenderedFeaturesInRect`), which is all
/// the desktop designer needs since it only ever shows online tiles.
typedef RouteWay = ({List<LatLng> coords, String kind});

class RouteGraphStore {
  RouteGraphStore._();
  static final RouteGraphStore instance = RouteGraphStore._();

  Future<List<RouteWay>> waysInBounds(LatLngBounds bounds) async => const [];

  Future<void> addWays(String regionId, List<RouteWay> ways) async {
    throw UnsupportedError('RouteGraphStore.addWays is not available on web');
  }
}
