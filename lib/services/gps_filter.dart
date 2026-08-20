import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// 2D constant-velocity Kalman filter for smoothing a walked GPS track live,
/// during recording (see `RecordTrailScreen._onPosition`). Fixes the root
/// cause of the "recorded trail wanders" reports: the old recording path only
/// ever checked step distance between fixes, never the phone's own reported
/// horizontal accuracy — so a fix with 30m of forest-canopy GPS error was
/// accepted exactly like a fix with 3m of error, as long as the distance from
/// the last point looked like a normal walking step. This filter instead
/// treats [Position.accuracy] as measurement noise: a tight fix pulls the
/// estimate close to itself, a loose fix barely moves it, letting the
/// filter's own constant-velocity prediction carry through the noisy stretch
/// instead of recording it as real sideways movement.
///
/// State is kept in local ENU (east/north) meters relative to a fixed origin
/// (the recording's first fix), not raw lat/lon degrees — doing the matrix
/// math directly in degrees would need to correct for latitude/longitude
/// having different meters-per-degree, which the ENU conversion sidesteps
/// once, up front, instead of everywhere.
///
/// No general matrix library: the state is always 4x4, and the measurement
/// matrix only ever selects the position rows, so every operation below is
/// hand-written explicit algebra rather than a dependency for a handful of
/// small, fixed-shape matrices.
class GpsKalmanFilter {
  GpsKalmanFilter(this._origin);

  final LatLng _origin;

  /// Process noise (m/s²) — how much the filter expects true walking speed
  /// to change between fixes. Calibrated for walking pace (~1-1.5 m/s), not
  /// vehicle speed. Higher trusts new fixes more (tracks turns faster, but
  /// smooths noise less); lower smooths more (but can round off a sharp
  /// switchback if tuned too low — check a switchback-heavy test walk before
  /// changing this).
  static const double _sigmaA = 0.6;

  static const double _metersPerDegLat = 111320.0;
  late final double _metersPerDegLon =
      _metersPerDegLat * math.cos(_origin.latitude * math.pi / 180);

  /// [E, N, vE, vN].
  List<double>? _x;

  /// 4x4 covariance.
  List<List<double>>? _p;
  DateTime? _lastTime;

  double _toE(LatLng p) => (p.longitude - _origin.longitude) * _metersPerDegLon;
  double _toN(LatLng p) => (p.latitude - _origin.latitude) * _metersPerDegLat;
  LatLng _toLatLng(double e, double n) => LatLng(
        _origin.latitude + n / _metersPerDegLat,
        _origin.longitude + e / _metersPerDegLon,
      );

  /// A fix's reported accuracy, as a measurement-noise variance — floored so
  /// a platform reporting 0/unavailable accuracy can't produce a division
  /// blow-up in the update step below.
  double _accuracyVariance(double accuracy) {
    final a = accuracy.isFinite && accuracy > 3.0 ? accuracy : 3.0;
    return a * a;
  }

  /// Seeds the filter directly from the first fix of a recording — position
  /// exact (that fix *is* the starting point), velocity unknown (large
  /// initial variance, since there's no prior fix to infer heading from).
  /// Returns the fix's own LatLng unchanged (nothing to filter against yet).
  LatLng seed(Position pos) {
    final here = LatLng(pos.latitude, pos.longitude);
    final posVar = _accuracyVariance(pos.accuracy);
    _x = [_toE(here), _toN(here), 0.0, 0.0];
    _p = [
      [posVar, 0.0, 0.0, 0.0],
      [0.0, posVar, 0.0, 0.0],
      [0.0, 0.0, 4.0, 0.0], // ~2 m/s std-dev velocity uncertainty
      [0.0, 0.0, 0.0, 4.0],
    ];
    _lastTime = pos.timestamp;
    return here;
  }

  /// Feeds one fix through predict + update, returning the filtered LatLng.
  /// Calls [seed] automatically for the very first fix.
  LatLng update(Position pos) {
    final x = _x, p = _p;
    if (x == null || p == null) return seed(pos);

    final dt = pos.timestamp.difference(_lastTime ?? pos.timestamp).inMilliseconds /
        1000.0;
    // Clamped, not just floored — a long gap (app backgrounded, GPS lost)
    // would otherwise blow up the process-noise covariance and make the
    // filter swing wildly toward whatever fix arrives next.
    final dtClamped = dt.clamp(0.1, 10.0);
    _lastTime = pos.timestamp;

    // --- predict ---
    final xPred = [
      x[0] + x[2] * dtClamped,
      x[1] + x[3] * dtClamped,
      x[2],
      x[3],
    ];
    final f = [
      [1.0, 0.0, dtClamped, 0.0],
      [0.0, 1.0, 0.0, dtClamped],
      [0.0, 0.0, 1.0, 0.0],
      [0.0, 0.0, 0.0, 1.0],
    ];
    final q = _sigmaA * _sigmaA;
    final dt2 = dtClamped * dtClamped;
    final dt3 = dt2 * dtClamped;
    final dt4 = dt3 * dtClamped;
    final qm = [
      [q * dt4 / 4, 0.0, q * dt3 / 2, 0.0],
      [0.0, q * dt4 / 4, 0.0, q * dt3 / 2],
      [q * dt3 / 2, 0.0, q * dt2, 0.0],
      [0.0, q * dt3 / 2, 0.0, q * dt2],
    ];
    final pPred = _matAdd(_matMul(_matMul(f, p), _transpose(f)), qm);

    // --- update (position-only measurement) ---
    final here = LatLng(pos.latitude, pos.longitude);
    final r = _accuracyVariance(pos.accuracy);
    final yE = _toE(here) - xPred[0];
    final yN = _toN(here) - xPred[1];

    // S = H*Ppred*H^T + R — H selects rows/cols 0,1, so S is just Ppred's
    // top-left 2x2 block plus R on the diagonal.
    final s00 = pPred[0][0] + r;
    final s01 = pPred[0][1];
    final s10 = pPred[1][0];
    final s11 = pPred[1][1] + r;
    final det = s00 * s11 - s01 * s10;
    final invDet = det.abs() < 1e-9 ? 0.0 : 1.0 / det;
    final si00 = s11 * invDet, si01 = -s01 * invDet;
    final si10 = -s10 * invDet, si11 = s00 * invDet;

    // K = Ppred * H^T * S^-1 (4x2) — H^T just selects Ppred's first two
    // columns, so this is a direct 4x2-by-2x2 multiply.
    final k = [
      for (var i = 0; i < 4; i++)
        [
          pPred[i][0] * si00 + pPred[i][1] * si10,
          pPred[i][0] * si01 + pPred[i][1] * si11,
        ],
    ];

    final xNew = [for (var i = 0; i < 4; i++) xPred[i] + k[i][0] * yE + k[i][1] * yN];

    // P = (I - K*H) * Ppred == Ppred - K * (Ppred's first two rows).
    final row0 = pPred[0], row1 = pPred[1];
    final pNew = [
      for (var i = 0; i < 4; i++)
        [for (var j = 0; j < 4; j++) pPred[i][j] - k[i][0] * row0[j] - k[i][1] * row1[j]],
    ];

    _x = xNew;
    _p = pNew;
    return _toLatLng(xNew[0], xNew[1]);
  }

  /// Rough 1-sigma position uncertainty (metres) — sqrt of the position
  /// block's trace. Not currently surfaced in the UI (RecordTrailScreen
  /// tracks raw fix accuracy directly for its own post-walk quality note);
  /// exposed for future tuning/diagnostics.
  double get positionUncertaintyMeters {
    final p = _p;
    if (p == null) return 0;
    return math.sqrt(math.max(0, p[0][0]) + math.max(0, p[1][1]));
  }

  static List<List<double>> _matMul(List<List<double>> a, List<List<double>> b) {
    final n = a.length, k = b.length, m = b[0].length;
    return [
      for (var i = 0; i < n; i++)
        [
          for (var j = 0; j < m; j++)
            [for (var t = 0; t < k; t++) a[i][t] * b[t][j]].reduce((x, y) => x + y),
        ],
    ];
  }

  static List<List<double>> _transpose(List<List<double>> a) => [
        for (var j = 0; j < a[0].length; j++) [for (var i = 0; i < a.length; i++) a[i][j]],
      ];

  static List<List<double>> _matAdd(List<List<double>> a, List<List<double>> b) => [
        for (var i = 0; i < a.length; i++)
          [for (var j = 0; j < a[i].length; j++) a[i][j] + b[i][j]],
      ];
}
