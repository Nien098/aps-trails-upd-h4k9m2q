import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trailguide/services/pmtiles_reader.dart';
import 'package:trailguide/services/pmtiles_writer.dart';

/// Deterministic, distinct fake tile bytes per (z,x,y) — encodes its own
/// coordinates into the payload so a reader bug that returns the *wrong*
/// tile (not just wrong/garbled bytes) is caught by simple equality, not
/// just a length check.
Uint8List fakeTile(int z, int x, int y) {
  final s = 'tile:$z/$x/$y';
  final base = Uint8List.fromList(s.codeUnits);
  // Pad a bit so tiles aren't all tiny/identical-length — closer to real
  // MVT bytes, and exercises the offset arithmetic more realistically.
  return Uint8List.fromList([...base, ...List.filled(37, z + x + y)]);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pmtiles_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Writes [tiles] (z,x,y triples) via PmTilesWriter and opens the result
  /// with PmTilesReader.
  Future<(String path, PmTilesReader reader)> writeAndOpen(
      List<(int, int, int)> tiles) async {
    final tempPath = '${tmp.path}/build.tmp';
    final outPath = '${tmp.path}/out.pmtiles';
    final writer = await PmTilesWriter.create(tempPath);
    for (final (z, x, y) in tiles) {
      await writer.addTile(z, x, y, fakeTile(z, x, y));
    }
    await writer.finish(outPath,
        west: -123.5, south: 48.3, east: -121.8, north: 50.2,
        minZoom: 10, maxZoom: 15);
    final reader = await PmTilesReader.open(outPath);
    return (outPath, reader);
  }

  group('small archive (root-only directory)', () {
    test('every written tile round-trips byte-for-byte', () async {
      final tiles = [
        for (var x = 0; x < 5; x++)
          for (var y = 0; y < 5; y++) (12, x, y),
      ];
      final (_, reader) = await writeAndOpen(tiles);
      for (final (z, x, y) in tiles) {
        final bytes = await reader.getTile(z, x, y);
        expect(bytes, equals(fakeTile(z, x, y)),
            reason: 'tile $z/$x/$y should round-trip exactly');
      }
      await reader.close();
    });

    test('never-written tiles (including adjacent ones) read as absent',
        () async {
      final (_, reader) = await writeAndOpen([(12, 10, 10), (12, 10, 12)]);
      // Not written at all.
      expect(await reader.getTile(12, 0, 0), isNull);
      // Adjacent to a real tile but itself never added — catches off-by-one
      // directory bugs that "round" a lookup onto a neighbour.
      expect(await reader.getTile(12, 10, 11), isNull);
      expect(await reader.getTile(12, 9, 10), isNull);
      expect(await reader.hasTile(12, 10, 11), isFalse);
      await reader.close();
    });

    test('bounds and zoom round-trip', () async {
      final (_, reader) = await writeAndOpen([(11, 1, 1)]);
      expect(reader.west, closeTo(-123.5, 1e-6));
      expect(reader.south, closeTo(48.3, 1e-6));
      expect(reader.east, closeTo(-121.8, 1e-6));
      expect(reader.north, closeTo(50.2, 1e-6));
      expect(reader.minZoom, 10);
      expect(reader.maxZoom, 15);
      await reader.close();
    });

    test('listTileIds() matches exactly what was written', () async {
      final tiles = [
        for (var x = 0; x < 4; x++)
          for (var y = 0; y < 4; y++) (13, x, y),
      ];
      final (_, reader) = await writeAndOpen(tiles);
      final ids = await reader.listTileIds();
      expect(ids.length, tiles.length);
      expect(ids.toSet().length, ids.length, reason: 'no duplicate ids');
      // Count + individual presence together rule out both missing and
      // extra (phantom) entries without needing to re-derive expected ids.
      for (final (z, x, y) in tiles) {
        expect(await reader.hasTile(z, x, y), isTrue);
      }
      await reader.close();
    });
  });

  group('large archive (forces root -> leaf directory split)', () {
    // _buildDirectories splits into leaves once the root-only serialized
    // directory would exceed 16384 bytes — comfortably forced by enough
    // entries at varying zoom levels (spread across z11-14 so Hilbert ids
    // aren't trivially sequential, closer to a real downloaded region).
    late List<(int, int, int)> tiles;
    late PmTilesReader reader;

    setUp(() async {
      tiles = [
        for (var z = 11; z <= 14; z++)
          for (var x = 0; x < 30; x++)
            for (var y = 0; y < 30; y++) (z, x, y),
      ]; // 4 * 900 = 3600... bump further below if needed.
      // 3600 entries alone may not clear 16384 bytes depending on varint
      // sizes; add a dense z14 block to comfortably force a leaf split.
      tiles = [
        ...tiles,
        for (var x = 100; x < 250; x++)
          for (var y = 100; y < 150; y++) (14, x, y),
      ];
      final (_, r) = await writeAndOpen(tiles);
      reader = r;
    });

    tearDown(() async {
      await reader.close();
    });

    test('every tile round-trips, including ones split across leaves',
        () async {
      // Checking all ~11,100 would be slow; sample across the whole range
      // (start, middle, end, and a scatter) so both early and late leaf
      // chunks are exercised.
      final sample = [
        tiles.first,
        tiles[tiles.length ~/ 4],
        tiles[tiles.length ~/ 2],
        tiles[(tiles.length * 3) ~/ 4],
        tiles.last,
        ...tiles.take(50),
        ...tiles.reversed.take(50),
      ];
      for (final (z, x, y) in sample) {
        final bytes = await reader.getTile(z, x, y);
        expect(bytes, equals(fakeTile(z, x, y)),
            reason: 'tile $z/$x/$y should round-trip exactly even with leaves');
      }
    });

    test('listTileIds() count matches total written', () async {
      final ids = await reader.listTileIds();
      expect(ids.length, tiles.length);
      expect(ids.toSet().length, ids.length, reason: 'no duplicate ids');
    });
  });

  group('contiguous-offset encoding', () {
    test('sequentially-written (byte-contiguous) tiles decode to the exact '
        'offsets they were written at', () async {
      // addTile calls in sequence are always byte-contiguous in the temp
      // file (each starts where the previous one's bytes ended) — this is
      // exactly the "offset encoded as 0" case in PmTilesWriter._serialize,
      // the single highest-risk spot in the reader to get backwards.
      final tiles = [for (var x = 0; x < 20; x++) (12, x, 5)];
      final (_, reader) = await writeAndOpen(tiles);
      var expectedOffset = 0;
      for (final (z, x, y) in tiles) {
        final loc = await reader.locate(z, x, y);
        expect(loc, isNotNull);
        expect(loc!.offset, expectedOffset,
            reason: 'tile $z/$x/$y should sit exactly where it was written');
        expect(loc.length, fakeTile(z, x, y).length);
        expectedOffset += loc.length;
      }
      await reader.close();
    });
  });

  group('format rejection', () {
    test('throws FormatException on a truncated file', () async {
      final (path, reader) = await writeAndOpen([(12, 1, 1)]);
      await reader.close();
      final bytes = await File(path).readAsBytes();
      final truncatedPath = '${tmp.path}/truncated.pmtiles';
      await File(truncatedPath).writeAsBytes(bytes.sublist(0, 50));
      await expectLater(
          PmTilesReader.open(truncatedPath), throwsFormatException);
    });

    test('throws FormatException on wrong magic bytes', () async {
      final badPath = '${tmp.path}/bad_magic.pmtiles';
      final bytes = Uint8List(127);
      bytes.setAll(0, 'NOTPMTIL'.codeUnits);
      await File(badPath).writeAsBytes(bytes);
      await expectLater(PmTilesReader.open(badPath), throwsFormatException);
    });

    test('throws FormatException on wrong version byte', () async {
      final (path, reader) = await writeAndOpen([(12, 1, 1)]);
      await reader.close();
      final bytes = await File(path).readAsBytes();
      bytes[7] = 99; // valid magic, bogus version
      final badPath = '${tmp.path}/bad_version.pmtiles';
      await File(badPath).writeAsBytes(bytes);
      await expectLater(PmTilesReader.open(badPath), throwsFormatException);
    });
  });
}
