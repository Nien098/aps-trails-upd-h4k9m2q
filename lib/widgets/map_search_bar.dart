import 'package:flutter/material.dart';

import '../models/region.dart';
import '../services/search_service.dart';

/// Inline, map-stays-visible search box — a floating [Card] the caller
/// positions over its own map (see [GuideScreen], [AuthorScreen],
/// [BrowseMapScreen]), not a full-screen takeover. Replaces an earlier
/// `showSearch`/`SearchDelegate`-based version: `showSearch` always does a
/// hard `Navigator.push` of an opaque route, which unmounts the map's native
/// platform view rather than just covering it — there's no way to keep the
/// map visible/pannable underneath a [SearchDelegate], so this is a
/// hand-rolled overlay instead (matching this app's existing floating-card
/// idiom — see `AuthorScreen._ModeBar`, `DownloadRegionScreen._Hint` — rather
/// than Flutter's `Autocomplete<T>`, which uses a different overlay
/// mechanism than anything else in this app).
///
/// Results re-query on every keystroke — no debounce — since FTS5 lookups at
/// this scale (tens of thousands of rows) are sub-millisecond.
class MapSearchBar extends StatefulWidget {
  const MapSearchBar(
      {super.key, required this.onSelected, required this.onClose, this.confineTo});

  final ValueChanged<SearchResult> onSelected;
  final VoidCallback onClose;

  /// When set, only results reachable by a plain camera pan on this region's
  /// already-loaded basemap are shown — see [SearchService.search]'s doc.
  final Region? confineTo;

  @override
  State<MapSearchBar> createState() => _MapSearchBarState();
}

class _MapSearchBarState extends State<MapSearchBar> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Search streets and trails',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            if (_query.trim().isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: _ResultsList(
                  query: _query,
                  confineTo: widget.confineTo,
                  onPick: widget.onSelected,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({required this.query, required this.confineTo, required this.onPick});
  final String query;
  final Region? confineTo;
  final ValueChanged<SearchResult> onPick;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SearchResult>>(
      future: SearchService.instance.search(query, confineTo: confineTo),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
                child: SizedBox(
                    width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (snap.hasError) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Search error — try again',
                style: TextStyle(color: Colors.redAccent)),
          );
        }
        final results = snap.data!;
        if (results.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No matches'),
          );
        }
        return ListView.builder(
          shrinkWrap: true,
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
