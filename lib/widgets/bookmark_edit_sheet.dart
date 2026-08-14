import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/bookmark.dart';

/// Bottom sheet to create a new [Bookmark] at [position], or edit [existing]
/// in place (position unchanged — moving a bookmark isn't supported, the
/// same way moving a search result isn't; delete and re-add instead).
/// Returns the bookmark to save, or null if cancelled/deleted.
///
/// Returning a sentinel deleted-marker isn't needed: the caller
/// ([BrowseMapScreen]/[AuthorScreen]) offers its own separate "Delete"
/// action on an existing bookmark's tap sheet, before this editor ever
/// opens — this sheet only ever needs to hand back "save this" or nothing.
Future<Bookmark?> showBookmarkEditSheet(
  BuildContext context, {
  required LatLng position,
  Bookmark? existing,
}) {
  return showModalBottomSheet<Bookmark>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _BookmarkEditForm(position: position, existing: existing),
    ),
  );
}

class _BookmarkEditForm extends StatefulWidget {
  const _BookmarkEditForm({required this.position, this.existing});
  final LatLng position;
  final Bookmark? existing;

  @override
  State<_BookmarkEditForm> createState() => _BookmarkEditFormState();
}

class _BookmarkEditFormState extends State<_BookmarkEditForm> {
  late final _nameController =
      TextEditingController(text: widget.existing?.name ?? '');
  late final _noteController =
      TextEditingController(text: widget.existing?.note ?? '');
  late BookmarkCategory _category =
      widget.existing?.category ?? BookmarkCategory.scenic;

  @override
  void dispose() {
    _nameController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final b = widget.existing ??
        Bookmark(name: name, category: _category, position: widget.position);
    b.name = name;
    b.category = _category;
    b.note = _noteController.text.trim();
    Navigator.pop(context, b);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.existing == null ? 'Add bookmark' : 'Edit bookmark',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              autofocus: widget.existing == null,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.words,
              // Rebuilds so the Save button's enabled state (below) tracks
              // whether a name has been typed yet.
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in BookmarkCategory.values)
                  ChoiceChip(
                    label: Text(c.label),
                    avatar: Icon(c.icon, size: 18,
                        color: _category == c ? Colors.white : c.color),
                    selected: _category == c,
                    selectedColor: c.color,
                    labelStyle: TextStyle(
                        color: _category == c ? Colors.white : null),
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(
                  labelText: 'Note (optional)', alignLabelWithHint: true),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _nameController.text.trim().isEmpty ? null : _save,
                  child: Text(widget.existing == null ? 'Save' : 'Save changes'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
