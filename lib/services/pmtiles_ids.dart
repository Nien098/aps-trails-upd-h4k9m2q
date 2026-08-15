/// PMTiles' Hilbert-curve tile-id encoding, shared verbatim by
/// [PmTilesWriter] and [PmTilesReader] so the two can never silently drift
/// out of sync — a divergence here would be silent data corruption (reading
/// back the wrong tile for a given z/x/y), not a crash, so this is kept as
/// the single source of truth rather than duplicated in each file.
library;

/// ZXY → PMTiles Hilbert tile id.
int zxyToTileId(int z, int x, int y) {
  var acc = 0;
  for (var t = 0; t < z; t++) {
    acc += (1 << t) * (1 << t);
  }
  final n = 1 << z;
  var rx = 0, ry = 0, d = 0;
  var tx = x, ty = y;
  for (var s = n >> 1; s > 0; s >>= 1) {
    rx = (tx & s) > 0 ? 1 : 0;
    ry = (ty & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    if (ry == 0) {
      if (rx == 1) {
        tx = s - 1 - tx;
        ty = s - 1 - ty;
      }
      final tmp = tx;
      tx = ty;
      ty = tmp;
    }
  }
  return acc + d;
}
