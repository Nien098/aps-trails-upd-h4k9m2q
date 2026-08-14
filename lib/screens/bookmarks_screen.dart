import 'package:flutter/material.dart';

import '../models/bookmark.dart';
import '../services/trail_store.dart';
import '../widgets/bookmark_edit_sheet.dart';

/// Full list of saved bookmarks. Tapping one pops it back to the caller
/// (map screens use this to jump the camera there) — editing/deleting
/// happen in place via each row's trailing menu instead of a separate pop
/// result, so the list keeps working normally after either.
class BookmarksScreen extends StatefulWidget {
  const BookmarksScreen({super.key});

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  List<Bookmark> _bookmarks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await TrailStore.instance.allBookmarks();
    if (mounted) {
      setState(() {
        _bookmarks = list;
        _loading = false;
      });
    }
  }

  Future<void> _edit(Bookmark b) async {
    final updated =
        await showBookmarkEditSheet(context, position: b.position, existing: b);
    if (updated != null) {
      await TrailStore.instance.saveBookmark(updated);
      await _load();
    }
  }

  Future<void> _delete(Bookmark b) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete bookmark?'),
        content: Text('"${b.name}" will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true && b.id != null) {
      await TrailStore.instance.deleteBookmark(b.id!);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bookmarks')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _bookmarks.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No bookmarks yet — long-press anywhere on the map '
                      'to drop one.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _bookmarks.length,
                  itemBuilder: (context, i) {
                    final b = _bookmarks[i];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: b.category.color,
                        child: Icon(b.icon, color: Colors.white, size: 18),
                      ),
                      title: Text(b.name),
                      subtitle: Text(
                          b.note.isEmpty ? b.category.label : '${b.category.label} · ${b.note}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'edit') _edit(b);
                          if (v == 'delete') _delete(b);
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                      onTap: () => Navigator.pop(context, b),
                    );
                  },
                ),
    );
  }
}
