import 'package:flutter/material.dart';

import '../cue_style.dart';
import '../models/trail.dart';
import '../widgets/cue_editor_sheet.dart';

/// Numbered list of a trail's cues in firing order (see [Cue.order]).
/// Tap a row to edit it directly; drag the handle to reorder (e.g. to insert
/// a forgotten cue mid-sequence); swipe to delete. Mutates [trail.cues] in
/// place — the caller (author screen) re-draws the map on return.
class CueListScreen extends StatefulWidget {
  const CueListScreen({super.key, required this.trail});

  final Trail trail;

  @override
  State<CueListScreen> createState() => _CueListScreenState();
}

class _CueListScreenState extends State<CueListScreen> {
  List<Cue> get _sorted =>
      List.of(widget.trail.cues)..sort((a, b) => a.order.compareTo(b.order));

  /// Inserts [cue] at [order], shifting every cue currently at or after that
  /// position up by one to make room.
  void _insertCueAtOrder(Cue cue, int order) {
    for (final c in widget.trail.cues) {
      if (c.order >= order) c.order++;
    }
    cue.order = order;
    widget.trail.cues.add(cue);
  }

  Future<void> _edit(Cue cue) async {
    final result = await showCueEditor(context, position: cue.position, existing: cue);
    if (result == deletedCueSentinel) {
      setState(() => widget.trail.cues.remove(cue));
    } else if (result == addAnotherCueSentinel) {
      // Insert right after the cue it's stacking with.
      if (!mounted) return;
      final another = await showCueEditor(context, position: cue.position);
      if (!mounted || another == null) return;
      setState(() => _insertCueAtOrder(another, cue.order + 1));
    } else if (result != null) {
      setState(() {
        cue
          ..type = result.type
          ..label = result.label
          ..spoken = result.spoken
          ..radiusMeters = result.radiusMeters;
      });
    }
  }

  void _delete(Cue cue) => setState(() => widget.trail.cues.remove(cue));

  void _reorder(int oldIndex, int newIndex) {
    final list = _sorted;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    setState(() {
      for (var i = 0; i < list.length; i++) {
        list[i].order = i;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cues = _sorted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cue order'),
      ),
      body: cues.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No cues yet.\n\nAdd some in Cue mode, or use "Suggest turn '
                  'cues" — they\'ll show up here in the order they fire.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Color(0xFF4A4A4A)),
                ),
              ),
            )
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom),
              itemCount: cues.length,
              onReorderItem: _reorder,
              itemBuilder: (context, i) {
                final cue = cues[i];
                return Dismissible(
                  key: ValueKey(cue),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: const Color(0xFFC62828),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) => _delete(cue),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: cueColor(cue.type),
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                    title: Text(cue.label, style: const TextStyle(fontSize: 17)),
                    subtitle: Text(cue.spoken,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Show on map',
                          icon: const Icon(Icons.center_focus_strong),
                          onPressed: () => Navigator.pop(context, cue),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_handle),
                        ),
                      ],
                    ),
                    onTap: () => _edit(cue),
                  ),
                );
              },
            ),
    );
  }
}
