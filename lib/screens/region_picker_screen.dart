import 'package:flutter/material.dart';

import '../models/region.dart';

/// Full-screen area picker — replaces the old cramped app-bar dropdown, now
/// that downloaded areas can pile up alongside the built-in bookmarks. Styled
/// like [DownloadRegionScreen] (a plain full Scaffold) rather than a bottom
/// sheet or dropdown, so it doesn't look out of place next to it.
class RegionPickerScreen extends StatelessWidget {
  const RegionPickerScreen({super.key, required this.current});

  final Region current;

  @override
  Widget build(BuildContext context) {
    final regions = allRegions();
    return Scaffold(
      appBar: AppBar(title: const Text('Choose an area')),
      body: ListView.separated(
        itemCount: regions.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final r = regions[i];
          return ListTile(
            leading: Icon(r.isDownloaded ? Icons.map_outlined : Icons.public),
            title: Text(r.name),
            trailing: r.id == current.id
                ? const Icon(Icons.check, color: Color(0xFF1B5E20))
                : null,
            onTap: () => Navigator.pop(context, r),
          );
        },
      ),
    );
  }
}
