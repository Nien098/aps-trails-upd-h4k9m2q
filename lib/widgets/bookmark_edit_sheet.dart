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
  late IconData _icon = widget.existing?.icon ?? _category.icon;

  /// True once the author has deliberately picked an icon from the grid —
  /// until then, switching category keeps re-seeding [_icon] to that
  /// category's default (see [_onCategorySelected]), so picking a category
  /// alone still gives a sensible icon without the author having to also
  /// open the icon grid every time.
  bool _iconTouched = false;

  @override
  void initState() {
    super.initState();
    _iconTouched = widget.existing != null && widget.existing!.icon != _category.icon;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _onCategorySelected(BookmarkCategory c) {
    setState(() {
      _category = c;
      if (!_iconTouched) _icon = c.icon;
    });
  }

  void _onIconSelected(IconData icon) {
    setState(() {
      _icon = icon;
      _iconTouched = true;
    });
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final b = widget.existing ??
        Bookmark(name: name, category: _category, position: widget.position);
    b.name = name;
    b.category = _category;
    b.icon = _icon;
    b.note = _noteController.text.trim();
    Navigator.pop(context, b);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        // Scrollable: the icon grid alone can run past a small phone's
        // available height once the keyboard is up for the name field.
        child: SingleChildScrollView(
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
                      onSelected: (_) => _onCategorySelected(c),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Icon', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final icon in kBookmarkIcons)
                    _IconChoice(
                      icon: icon,
                      selected: icon == _icon,
                      color: _category.color,
                      onTap: () => _onIconSelected(icon),
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
      ),
    );
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? color : color.withValues(alpha: 0.12),
          border: selected ? Border.all(color: Colors.white, width: 2) : null,
          boxShadow: selected
              ? [BoxShadow(color: color, blurRadius: 0, spreadRadius: 1.5)]
              : null,
        ),
        child: Icon(icon, size: 20, color: selected ? Colors.white : color),
      ),
    );
  }
}
