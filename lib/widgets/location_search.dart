import 'package:flutter/material.dart';

import '../models/region.dart';
import '../services/search_service.dart';

/// Offline search over street names (bundled/downloaded regions) and the
/// user's own trail names — see [SearchService]. Shared by [GuideScreen],
/// [AuthorScreen], and [BrowseMapScreen] so all three jump the camera the
/// same way. Built-in [SearchDelegate] gives the field/list/back-button
/// chrome for free; results query on every keystroke since FTS5 lookups at
/// this scale (tens of thousands of rows) are sub-millisecond, so a debounce
/// isn't worth the added complexity.
class LocationSearchDelegate extends SearchDelegate<SearchResult?> {
  LocationSearchDelegate({this.confineTo});

  /// When set, only results reachable by a plain camera pan on this region's
  /// already-loaded basemap are shown — a result in a different (separately
  /// downloaded) region's own pmtiles file would otherwise jump the camera
  /// to nothing rendered. Null (used by the view-only Browse Map screen,
  /// which can swap basemaps on demand) means unconfined.
  final Region? confineTo;

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _ResultsList(
      query: query, confineTo: confineTo, onPick: (r) => close(context, r));

  @override
  Widget buildSuggestions(BuildContext context) => _ResultsList(
      query: query, confineTo: confineTo, onPick: (r) => close(context, r));
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({required this.query, required this.confineTo, required this.onPick});
  final String query;
  final Region? confineTo;
  final ValueChanged<SearchResult> onPick;

  @override
  Widget build(BuildContext context) {
    if (query.trim().isEmpty) {
      return const Center(child: Text('Search for a street or trail name'));
    }
    return FutureBuilder<List<SearchResult>>(
      future: SearchService.instance.search(query, confineTo: confineTo),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final results = snap.data!;
        if (results.isEmpty) {
          return const Center(child: Text('No matches'));
        }
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, i) {
            final r = results[i];
            return ListTile(
              leading: Icon(
                  r.type == SearchResultType.trail ? Icons.route : Icons.signpost),
              title: Text(r.name),
              subtitle: Text(r.type == SearchResultType.trail ? 'Trail' : 'Street'),
              onTap: () => onPick(r),
            );
          },
        );
      },
    );
  }
}
