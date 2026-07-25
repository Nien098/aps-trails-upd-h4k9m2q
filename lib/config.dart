/// App-wide configuration constants.
///
/// The Protomaps API key is embedded in the app (it's not a secret for a
/// native client — anyone can read it from the APK). It powers the online map
/// used to frame + download new offline regions.
const String kProtomapsKey = '2cb9eb6ae263fc16';

/// XYZ vector-tile endpoint for a single tile (Protomaps basemap v4 schema —
/// the same schema our bundled offline maps use, so downloaded regions render
/// with the identical style.json).
String protomapsTileUrl(int z, int x, int y) =>
    'https://api.protomaps.com/tiles/v4/$z/$x/$y.mvt?key=$kProtomapsKey';

/// The `{z}/{x}/{y}` template form for a MapLibre online style source.
const String kProtomapsTileTemplate =
    'https://api.protomaps.com/tiles/v4/{z}/{x}/{y}.mvt?key=$kProtomapsKey';

/// Zoom range downloaded for an offline region (matches the basemap detail;
/// 15 is Protomaps' max data zoom, over-zoomed to 18 when rendering).
const int kRegionMinZoom = 10;
const int kRegionMaxZoom = 15;

/// GitHub "owner/repo" hosting release APKs for in-app updates. Must be a
/// PUBLIC repo — the app fetches the latest-release API and downloads the
/// attached APK with no auth token, so a private repo would require
/// embedding a credential in the app binary (extractable by anyone), which
/// this deliberately avoids. Each release's tag must exactly match the
/// `version:` in pubspec.yaml (e.g. tag `1.5.0+11` for `version: 1.5.0+11`)
/// with the built `app-release.apk` attached as a release asset.
const String kUpdateRepo = 'Nien098/aps-trails-upd-h4k9m2q';

String get kUpdateApiUrl =>
    'https://api.github.com/repos/$kUpdateRepo/releases/latest';
