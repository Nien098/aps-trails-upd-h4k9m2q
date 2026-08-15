import 'dart:io';
import 'dart:typed_data';

import 'pmtiles_ids.dart';

/// Reads tiles back out of a `.pmtiles` archive written by [PmTilesWriter] —
/// the mirror image of that class, decoding the exact same narrow PMTiles v3
/// shape it produces (no internal/tile compression, MVT-only, no
/// content-level dedup — see [PmTilesWriter]'s header doc). Deliberately
/// does *not* try to handle the general PMTiles spec (gzip-compressed
/// directories/tiles, other tile types, etc.) — this project fully controls
/// both ends of the format, so a reader that tried to be more general would
/// be untested surface area for zero real benefit. [open] rejects anything
/// outside that exact shape outright (a [FormatException], not a silent
/// misread) rather than guessing.
///
/// Used to reuse already-downloaded tile bytes (skip a network fetch for a
/// tile this archive — or another one — already has) and, for a merge, to
/// pull every tile out of a region's file before it's deleted. Read-only:
/// nothing in this class ever writes to the file it opens.
class PmTilesReader {
  PmTilesReader._(this._file, this._header, this._rootEntries);

  final RandomAccessFile _file;
  final _Header _header;
  final List<_DirEntry> _rootEntries;

  /// Leaf directories are small and only ever needed for a large archive —
  /// fetched and decoded lazily on first lookup that needs them, then kept
  /// for the life of this reader (directories don't change while a file is
  /// open, and this project never mutates an existing archive in place).
  final Map<int, List<_DirEntry>> _leafCache = {};

  static const _headerLen = 127;
  static const _magic = [0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73]; // "PMTiles"

  double get west => _header.west;
  double get south => _header.south;
  double get east => _header.east;
  double get north => _header.north;
  int get minZoom => _header.minZoom;
  int get maxZoom => _header.maxZoom;

  /// Opens [path] and parses its header + root directory. Throws
  /// [FormatException] if the file isn't a PmTilesWriter-shaped PMTiles v3
  /// archive (wrong magic/version, or a compression/tile-type this reader
  /// doesn't support) — callers should always wrap this in a try/catch and
  /// degrade to "treat as absent" rather than let a corrupt/foreign file
  /// abort whatever reuse/merge operation is in progress.
  static Future<PmTilesReader> open(String path) async {
    final file = await File(path).open(mode: FileMode.read);
    try {
      final headerBytes = await _readAt(file, 0, _headerLen);
      final header = _parseHeader(headerBytes);
      final rootBytes = await _readAt(file, header.rootOffset, header.rootLen);
      final rootEntries = _deserializeDirectory(rootBytes);
      return PmTilesReader._(file, header, rootEntries);
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  Future<void> close() => _file.close();

  /// Raw tile bytes for (z,x,y), or null if not present in this archive.
  Future<Uint8List?> getTile(int z, int x, int y) async {
    final loc = await locate(z, x, y);
    if (loc == null) return null;
    return readAt(loc.offset, loc.length);
  }

  /// Cheap presence check — same lookup as [getTile] minus the tile-byte
  /// read, for a caller that only needs to know whether to bother reading.
  Future<bool> hasTile(int z, int x, int y) async => (await locate(z, x, y)) != null;

  /// (offset, length) of a tile's bytes within this archive's tile-data
  /// region, or null if the tile isn't present.
  Future<({int offset, int length})?> locate(int z, int x, int y) async {
    final tileId = zxyToTileId(z, x, y);
    var entries = _rootEntries;
    while (true) {
      final idx = _floorIndex(entries, tileId);
      if (idx == null) return null;
      final e = entries[idx];
      if (e.runLength == 0) {
        // Leaf-directory pointer: e.offset/e.length are within the leaf
        // section (header.leafOffset), not the tile-data region.
        entries = await _leaf(e.offset, e.length);
        continue;
      }
      if (tileId >= e.tileId + e.runLength) return null; // gap, not covered
      return (offset: e.offset, length: e.length);
    }
  }

  /// Raw bytes at [offset]/[length] within the tile-data region — the
  /// primitive [getTile] uses once it already has a location, and what a
  /// merge uses directly to copy an existing tile's bytes without a
  /// round-trip through [getTile]'s own [locate] call.
  Future<Uint8List> readAt(int offset, int length) =>
      _readAt(_file, _header.tileOffset + offset, length);

  /// Every tile id present in the archive, ascending — built by walking the
  /// root directory (and every leaf, if any) and expanding each entry's
  /// run. Only ever touches directory bytes (kilobytes, even for a large
  /// archive), never the tile-data region — cheap enough to call once per
  /// reuse/merge operation to build a fast in-memory presence set instead
  /// of one file-seek-per-tile via [hasTile].
  Future<List<int>> listTileIds() async {
    final ids = <int>[];
    Future<void> walk(List<_DirEntry> entries) async {
      for (final e in entries) {
        if (e.runLength == 0) {
          await walk(await _leaf(e.offset, e.length));
        } else {
          for (var i = 0; i < e.runLength; i++) {
            ids.add(e.tileId + i);
          }
        }
      }
    }
    await walk(_rootEntries);
    return ids;
  }

  Future<List<_DirEntry>> _leaf(int offsetInLeafSection, int length) async {
    final cached = _leafCache[offsetInLeafSection];
    if (cached != null) return cached;
    final bytes = await _readAt(_file, _header.leafOffset + offsetInLeafSection, length);
    final entries = _deserializeDirectory(bytes);
    _leafCache[offsetInLeafSection] = entries;
    return entries;
  }

  /// Largest index whose tileId is <= [target], or null if every entry's
  /// tileId is greater than [target] (target isn't covered by this
  /// directory at all). Entries are sorted ascending, same order
  /// PmTilesWriter.finish() sorts them into before serializing.
  static int? _floorIndex(List<_DirEntry> entries, int target) {
    var lo = 0, hi = entries.length - 1, result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (entries[mid].tileId <= target) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result == -1 ? null : result;
  }

  static Future<Uint8List> _readAt(RandomAccessFile file, int offset, int length) async {
    await file.setPosition(offset);
    final bytes = await file.read(length);
    if (bytes.length != length) {
      throw const FormatException('Unexpected end of file reading a PMTiles section');
    }
    return bytes;
  }

  /// Inverse of PmTilesWriter._header() — same fixed 127-byte layout.
  static _Header _parseHeader(Uint8List bytes) {
    if (bytes.length < _headerLen) {
      throw const FormatException('File too short to be a PMTiles archive');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw const FormatException('Not a PMTiles file (bad magic bytes)');
      }
    }
    final h = ByteData.sublistView(bytes);
    if (h.getUint8(7) != 3) {
      throw const FormatException('Unsupported PMTiles spec version');
    }
    // Bytes 97-99: internal compression, tile compression, tile type — this
    // reader only understands the exact narrow shape PmTilesWriter produces
    // (see this class's doc): None/None/MVT (values 1/1/1).
    if (h.getUint8(97) != 1 || h.getUint8(98) != 1 || h.getUint8(99) != 1) {
      throw const FormatException(
          'PMTiles archive uses compression/tile-type this reader doesn\'t support');
    }
    return _Header(
      rootOffset: h.getUint64(8, Endian.little),
      rootLen: h.getUint64(16, Endian.little),
      leafOffset: h.getUint64(40, Endian.little),
      tileOffset: h.getUint64(56, Endian.little),
      minZoom: h.getUint8(100),
      maxZoom: h.getUint8(101),
      west: h.getInt32(102, Endian.little) / 1e7,
      south: h.getInt32(106, Endian.little) / 1e7,
      east: h.getInt32(110, Endian.little) / 1e7,
      north: h.getInt32(114, Endian.little) / 1e7,
    );
  }

  /// Inverse of PmTilesWriter._serialize(). See that method's doc for the
  /// contiguous-offset ("0 means adjacent to the previous entry") encoding
  /// this mirrors — the single easiest part of this format to get backwards.
  static List<_DirEntry> _deserializeDirectory(Uint8List bytes) {
    final r = _VarintReader(bytes);
    final n = r.readVarint();
    final tileIds = List<int>.filled(n, 0);
    var last = 0;
    for (var i = 0; i < n; i++) {
      last += r.readVarint();
      tileIds[i] = last;
    }
    final runLengths = List<int>.generate(n, (_) => r.readVarint());
    final lengths = List<int>.generate(n, (_) => r.readVarint());
    final entries = <_DirEntry>[];
    var prevOffset = 0, prevLength = 0;
    for (var i = 0; i < n; i++) {
      final raw = r.readVarint();
      final offset = (i > 0 && raw == 0) ? prevOffset + prevLength : raw - 1;
      entries.add(_DirEntry(tileIds[i], offset, lengths[i], runLengths[i]));
      prevOffset = offset;
      prevLength = lengths[i];
    }
    return entries;
  }
}

class _Header {
  _Header({
    required this.rootOffset,
    required this.rootLen,
    required this.leafOffset,
    required this.tileOffset,
    required this.minZoom,
    required this.maxZoom,
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });
  final int rootOffset, rootLen, leafOffset, tileOffset;
  final int minZoom, maxZoom;
  final double west, south, east, north;
}

class _DirEntry {
  _DirEntry(this.tileId, this.offset, this.length, this.runLength);
  final int tileId;
  final int offset;
  final int length;
  final int runLength;
}

/// Reads the same unsigned LEB128 varints PmTilesWriter._varint() writes.
class _VarintReader {
  _VarintReader(this._bytes);
  final Uint8List _bytes;
  int _pos = 0;

  int readVarint() {
    var result = 0, shift = 0;
    while (true) {
      final b = _bytes[_pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }
}
