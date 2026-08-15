import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Writes a PMTiles v3 archive from downloaded MVT tiles, so a downloaded
/// region is byte-compatible with the same offline pipeline (style.json,
/// routing, glyphs) the bundled maps use.
///
/// Tiles are streamed to a temp file as they arrive (memory-safe for large
/// areas); [finish] then assembles the final archive: header + directories +
/// metadata + the tile data.
class PmTilesWriter {
  PmTilesWriter._(this._temp, this._tempPath);

  final RandomAccessFile _temp;
  final String _tempPath;
  final List<_Entry> _entries = [];
  int _offset = 0;

  static Future<PmTilesWriter> create(String tempPath) async {
    final f = await File(tempPath).open(mode: FileMode.write);
    return PmTilesWriter._(f, tempPath);
  }

  int get tileCount => _entries.length;
  int get byteCount => _offset;

  /// Appends one tile's bytes. Empty tiles are skipped (nothing to store).
  Future<void> addTile(int z, int x, int y, List<int> bytes) async {
    if (bytes.isEmpty) return;
    await _temp.writeFrom(bytes);
    _entries.add(_Entry(_zxyToTileId(z, x, y), _offset, bytes.length));
    _offset += bytes.length;
  }

  /// Discards the in-progress temp file without building a final archive —
  /// for a cancelled download. Distinct from [finish] specifically so a
  /// cancelled *update* of an existing region (same id, same `outPath` as
  /// an already-working file) can never touch that existing file at all.
  Future<void> abort() async {
    try {
      await _temp.close();
    } catch (_) {}
    try {
      await File(_tempPath).delete();
    } catch (_) {}
  }

  /// Assembles the final `.pmtiles` at [outPath]. Bounds are in degrees.
  ///
  /// [onCopyProgress] — bytes copied so far / total — covers the one
  /// genuinely slow part of this method: streaming the whole temp tile file
  /// (hundreds of MB for a large region) into the staged output file below.
  /// Without it, a caller-side progress dialog has nothing to show for
  /// however long that takes and looks stuck at whatever the tile-fetch
  /// phase's own progress last read (typically 100%) — real reported bug,
  /// not a hypothetical.
  Future<void> finish(
    String outPath, {
    required double west,
    required double south,
    required double east,
    required double north,
    required int minZoom,
    required int maxZoom,
    void Function(int copied, int total)? onCopyProgress,
  }) async {
    await _temp.flush();
    await _temp.close();
    _entries.sort((a, b) => a.tileId.compareTo(b.tileId));

    final dirs = _buildDirectories(_entries);
    final metadata = utf8.encode(jsonEncode(_metadata(
        west, south, east, north, minZoom, maxZoom)));

    const headerLen = 127;
    final rootOffset = headerLen;
    final rootLen = dirs.root.length;
    final metaOffset = rootOffset + rootLen;
    final metaLen = metadata.length;
    final leafOffset = metaOffset + metaLen;
    final leafLen = dirs.leaves.length;
    final tileOffset = leafOffset + leafLen;
    final tileLen = _offset;

    final header = _header(
      rootOffset: rootOffset,
      rootLen: rootLen,
      metaOffset: metaOffset,
      metaLen: metaLen,
      leafOffset: leafOffset,
      leafLen: leafLen,
      tileOffset: tileOffset,
      tileLen: tileLen,
      numTiles: _entries.length,
      west: west,
      south: south,
      east: east,
      north: north,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );

    // Written to a side path and renamed into place only once complete —
    // updating an existing region reuses its id (and so this exact
    // `outPath`); writing directly into it would leave that region's map
    // half-written (and unusable) if the app died partway through.
    final stagingPath = '$outPath.new';
    final out = await File(stagingPath).open(mode: FileMode.write);
    try {
      await out.writeFrom(header);
      await out.writeFrom(dirs.root);
      await out.writeFrom(metadata);
      if (dirs.leaves.isNotEmpty) await out.writeFrom(dirs.leaves);
      // Append the tile data from the temp file in chunks, reporting
      // progress at a bounded rate (~1% steps, floored at 1MB) regardless of
      // file size — a naive per-chunk callback would fire thousands of
      // times for a large archive, well beyond what a UI progress listener
      // needs.
      final tin = File(_tempPath).openRead();
      var copied = 0;
      final reportEvery = math.max(_offset ~/ 100, 1 << 20);
      var sinceReport = 0;
      await for (final chunk in tin) {
        await out.writeFrom(chunk);
        copied += chunk.length;
        sinceReport += chunk.length;
        if (sinceReport >= reportEvery) {
          sinceReport = 0;
          onCopyProgress?.call(copied, _offset);
        }
      }
      onCopyProgress?.call(copied, _offset);
    } finally {
      await out.close();
    }
    await File(stagingPath).rename(outPath);
    try {
      await File(_tempPath).delete();
    } catch (_) {}
  }

  // --- PMTiles v3 encoding ---

  Map<String, dynamic> _metadata(double w, double s, double e, double n,
          int minZ, int maxZ) =>
      {
        'name': 'trailguide-region',
        'format': 'pbf',
        'minzoom': minZ,
        'maxzoom': maxZ,
        'bounds': [w, s, e, n],
        // MapLibre reads these to know the source-layers (must match style.json).
        'vector_layers': [
          {'id': 'landcover', 'fields': {'kind': 'String'}},
          {'id': 'landuse', 'fields': {'kind': 'String'}},
          {'id': 'water', 'fields': {'kind': 'String'}},
          {'id': 'buildings', 'fields': <String, String>{}},
          {
            'id': 'roads',
            'fields': {
              'kind': 'String',
              'kind_detail': 'String',
              'name': 'String'
            }
          },
          {'id': 'places', 'fields': {'name': 'String'}},
        ],
      };

  Uint8List _header({
    required int rootOffset,
    required int rootLen,
    required int metaOffset,
    required int metaLen,
    required int leafOffset,
    required int leafLen,
    required int tileOffset,
    required int tileLen,
    required int numTiles,
    required double west,
    required double south,
    required double east,
    required double north,
    required int minZoom,
    required int maxZoom,
  }) {
    final h = ByteData(127);
    const magic = [0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73]; // "PMTiles"
    for (var i = 0; i < 7; i++) {
      h.setUint8(i, magic[i]);
    }
    h.setUint8(7, 3); // spec version
    h.setUint64(8, rootOffset, Endian.little);
    h.setUint64(16, rootLen, Endian.little);
    h.setUint64(24, metaOffset, Endian.little);
    h.setUint64(32, metaLen, Endian.little);
    h.setUint64(40, leafOffset, Endian.little);
    h.setUint64(48, leafLen, Endian.little);
    h.setUint64(56, tileOffset, Endian.little);
    h.setUint64(64, tileLen, Endian.little);
    h.setUint64(72, numTiles, Endian.little); // addressed tiles
    h.setUint64(80, numTiles, Endian.little); // tile entries
    h.setUint64(88, numTiles, Endian.little); // tile contents (no dedup)
    h.setUint8(96, 0); // clustered = false (tile data in fetch order)
    h.setUint8(97, 1); // internal compression = None
    h.setUint8(98, 1); // tile compression = None (raw MVT)
    h.setUint8(99, 1); // tile type = MVT
    h.setUint8(100, minZoom);
    h.setUint8(101, maxZoom);
    h.setInt32(102, (west * 1e7).round(), Endian.little);
    h.setInt32(106, (south * 1e7).round(), Endian.little);
    h.setInt32(110, (east * 1e7).round(), Endian.little);
    h.setInt32(114, (north * 1e7).round(), Endian.little);
    h.setUint8(118, minZoom); // center zoom
    h.setInt32(119, ((west + east) / 2 * 1e7).round(), Endian.little);
    h.setInt32(123, ((south + north) / 2 * 1e7).round(), Endian.little);
    return h.buffer.asUint8List();
  }

  _Dirs _buildDirectories(List<_Entry> entries) {
    final root = _serialize(entries);
    if (root.length <= 16384) {
      return _Dirs(root, Uint8List(0));
    }
    // Too big for a root-only directory: chunk into leaves.
    const leafSize = 4000;
    final leafBuf = BytesBuilder();
    final rootEntries = <_Entry>[];
    for (var i = 0; i < entries.length; i += leafSize) {
      final end = (i + leafSize < entries.length) ? i + leafSize : entries.length;
      final chunk = entries.sublist(i, end);
      final leaf = _serialize(chunk);
      // A root entry with runLength 0 points at a leaf directory.
      rootEntries.add(_Entry(chunk.first.tileId, leafBuf.length, leaf.length,
          runLength: 0));
      leafBuf.add(leaf);
    }
    return _Dirs(_serialize(rootEntries), leafBuf.toBytes());
  }

  /// Serializes a directory per the PMTiles v3 spec (uncompressed).
  Uint8List _serialize(List<_Entry> entries) {
    final b = BytesBuilder();
    _varint(b, entries.length);
    var last = 0;
    for (final e in entries) {
      _varint(b, e.tileId - last);
      last = e.tileId;
    }
    for (final e in entries) {
      _varint(b, e.runLength);
    }
    for (final e in entries) {
      _varint(b, e.length);
    }
    for (var i = 0; i < entries.length; i++) {
      if (i > 0 &&
          entries[i].offset == entries[i - 1].offset + entries[i - 1].length) {
        _varint(b, 0);
      } else {
        _varint(b, entries[i].offset + 1);
      }
    }
    return b.toBytes();
  }

  static void _varint(BytesBuilder b, int value) {
    var v = value;
    while (v >= 0x80) {
      b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    b.addByte(v & 0x7f);
  }

  /// ZXY → PMTiles Hilbert tile id.
  static int _zxyToTileId(int z, int x, int y) {
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
}

class _Entry {
  _Entry(this.tileId, this.offset, this.length, {this.runLength = 1});
  final int tileId;
  final int offset;
  final int length;
  final int runLength;
}

class _Dirs {
  _Dirs(this.root, this.leaves);
  final Uint8List root;
  final Uint8List leaves;
}
