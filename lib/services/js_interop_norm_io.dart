/// Native platforms' `queryRenderedFeaturesInRect` already returns genuine
/// Dart Maps/Lists via the platform channel — nothing to convert.
dynamic normalizeJs(dynamic value) => value;
