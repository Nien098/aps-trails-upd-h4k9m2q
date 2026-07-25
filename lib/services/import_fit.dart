import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/activity.dart';
import 'geo.dart';

/// Parsers for bringing fitness history in from Runkeeper (and any GPX source),
/// converting it into TrailGuide [Activity] records that merge with app walks.
class FitImport {
  /// True if [text] looks like a Runkeeper `cardioActivities.csv` export.
  static bool looksLikeCsv(String text) {
    final first = text.trimLeft().split('\n').first.toLowerCase();
    return first.contains('distance') && first.contains('duration');
  }

  /// True if [text] looks like a GPX track file.
  static bool looksLikeGpx(String text) =>
      text.trimLeft().toLowerCase().contains('<gpx');

  /// Parses a Runkeeper `cardioActivities.csv` into activities (no GPS track —
  /// summary stats only). Handles both metric and imperial exports.
  static List<Activity> parseCsv(String csv) {
    final lines = const LineSplitter().convert(csv);
    if (lines.length < 2) return [];
    final header = _csvRow(lines.first);
    int col(String key) =>
        header.indexWhere((h) => h.toLowerCase().contains(key));
    final iDate = col('date');
    final iType = col('type');
    final iName = header.indexWhere(
        (h) => h.toLowerCase().contains('route name'));
    final iDist = col('distance');
    final iDur = col('duration');
    final iClimb = col('climb');
    final distMiles =
        iDist >= 0 && header[iDist].toLowerCase().contains('(mi');
    final climbFeet =
        iClimb >= 0 && header[iClimb].toLowerCase().contains('(ft');

    String cell(List<String> f, int i) =>
        (i >= 0 && i < f.length) ? f[i].trim() : '';
    double numCell(List<String> f, int i) =>
        double.tryParse(cell(f, i).replaceAll(',', '')) ?? 0;

    final out = <Activity>[];
    for (var li = 1; li < lines.length; li++) {
      if (lines[li].trim().isEmpty) continue;
      final f = _csvRow(lines[li]);
      final date = DateTime.tryParse(cell(f, iDate));
      if (date == null) continue;
      final dist = numCell(f, iDist);
      final climb = numCell(f, iClimb);
      final name = cell(f, iName).isNotEmpty
          ? cell(f, iName)
          : (cell(f, iType).isNotEmpty ? cell(f, iType) : 'Runkeeper walk');
      out.add(Activity(
        trailName: name,
        startedAt: date,
        durationSec: _parseDuration(cell(f, iDur)),
        distanceMeters: distMiles ? dist * 1609.344 : dist * 1000,
        elevGainMeters: climbFeet ? climb / 3.28084 : climb,
      ));
    }
    return out;
  }

  /// Parses a single GPX track into one activity, including its route + splits.
  static Activity? parseGpx(String gpx) {
    final blockRe = RegExp(
        r'<trkpt\b([^>]*)>(.*?)</trkpt>|<trkpt\b([^>/]*)/>',
        caseSensitive: false, dotAll: true);
    final latRe = RegExp(r'lat="([-0-9.]+)"', caseSensitive: false);
    final lonRe = RegExp(r'lon="([-0-9.]+)"', caseSensitive: false);
    final eleRe = RegExp(r'<ele>([-0-9.]+)</ele>', caseSensitive: false);
    final timeRe = RegExp(r'<time>([^<]+)</time>', caseSensitive: false);

    final pts = <LatLng>[];
    final eles = <double?>[];
    final times = <DateTime?>[];
    for (final m in blockRe.allMatches(gpx)) {
      final attrs = m.group(1) ?? m.group(3) ?? '';
      final inner = m.group(2) ?? '';
      final lat = double.tryParse(latRe.firstMatch(attrs)?.group(1) ?? '');
      final lon = double.tryParse(lonRe.firstMatch(attrs)?.group(1) ?? '');
      if (lat == null || lon == null) continue;
      pts.add(LatLng(lat, lon));
      eles.add(double.tryParse(eleRe.firstMatch(inner)?.group(1) ?? ''));
      times.add(DateTime.tryParse(timeRe.firstMatch(inner)?.group(1) ?? ''));
    }
    if (pts.length < 2) return null;

    final start = times.firstWhere((t) => t != null, orElse: () => null);
    final startTime = start ?? DateTime.now();

    var distance = 0.0;
    for (var i = 1; i < pts.length; i++) {
      distance += metersBetween(pts[i - 1], pts[i]);
    }

    // Elevation gain with the same smoothing/hysteresis as live tracking.
    var gain = 0.0;
    double? smooth;
    double? ref;
    for (final e in eles) {
      if (e == null) continue;
      smooth = smooth == null ? e : smooth * 0.6 + e * 0.4;
      ref ??= smooth;
      if (smooth - ref > 4.0) {
        gain += smooth - ref;
        ref = smooth;
      } else if (smooth - ref < -4.0) {
        ref = smooth;
      }
    }

    final track = <TrackPoint>[];
    for (var i = 0; i < pts.length; i++) {
      final t = times[i];
      final tSec = t == null ? 0 : t.difference(startTime).inSeconds;
      track.add(TrackPoint(pts[i], tSec < 0 ? 0 : tSec, ele: eles[i]));
    }
    final durSec = times.last != null
        ? times.last!.difference(startTime).inSeconds
        : (track.isNotEmpty ? track.last.tSec : 0);

    final nameMatch =
        RegExp(r'<name>([^<]+)</name>', caseSensitive: false).firstMatch(gpx);
    return Activity(
      trailName: nameMatch?.group(1)?.trim() ?? 'Imported walk',
      startedAt: startTime,
      durationSec: durSec,
      distanceMeters: distance,
      elevGainMeters: gain,
      track: track,
    );
  }

  /// Splits a CSV line, honouring double-quoted fields (which may contain commas).
  static List<String> _csvRow(String line) {
    final out = <String>[];
    final sb = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        out.add(sb.toString());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    out.add(sb.toString());
    return out;
  }

  /// Parses "H:MM:SS" or "MM:SS" (or plain seconds) into seconds.
  static int _parseDuration(String s) {
    s = s.trim();
    if (s.isEmpty) return 0;
    final parts = s.split(':');
    try {
      if (parts.length == 3) {
        return int.parse(parts[0]) * 3600 +
            int.parse(parts[1]) * 60 +
            double.parse(parts[2]).round();
      } else if (parts.length == 2) {
        return int.parse(parts[0]) * 60 + double.parse(parts[1]).round();
      }
      return double.parse(s).round();
    } catch (_) {
      return 0;
    }
  }
}
