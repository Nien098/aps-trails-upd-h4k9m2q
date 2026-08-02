import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../cue_style.dart';
import '../models/trail.dart';

/// Returned by [showCueEditor] when the user deletes the cue being edited,
/// distinct from `null` (cancelled) or a real [Cue] (saved).
final Cue deletedCueSentinel = Cue(
  type: CueType.note,
  position: const LatLng(0, 0),
  order: -1,
);

/// Returned by [showCueEditor] when the user asks to stack another cue at
/// the same spot instead of saving/editing this one — the caller should
/// immediately open a fresh (non-`existing`) editor at the same position and
/// append it to the stack, same as any other new cue.
final Cue addAnotherCueSentinel = Cue(
  type: CueType.note,
  position: const LatLng(0, 0),
  order: -2,
);

/// Shows the cue editor as a modal bottom sheet. Returns the edited cue,
/// [deletedCueSentinel] if deleted, [addAnotherCueSentinel] if the user chose
/// to stack another cue here (both only possible when [existing] is given),
/// or null if cancelled. The returned cue's [Cue.order] is a placeholder —
/// callers own ordering (new cues: append to the stack; edits: keep the
/// original cue's order unchanged).
Future<Cue?> showCueEditor(
  BuildContext context, {
  required LatLng position,
  Cue? existing,
}) {
  return showModalBottomSheet<Cue>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true, // never draw under the status bar
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.9,
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: CueEditorSheet(
        position: position,
        existing: existing,
        onDelete: existing == null
            ? null
            : () => Navigator.pop(ctx, deletedCueSentinel),
        onAddAnother: existing == null
            ? null
            : () => Navigator.pop(ctx, addAnotherCueSentinel),
      ),
    ),
  );
}

class CueEditorSheet extends StatefulWidget {
  const CueEditorSheet({
    super.key,
    required this.position,
    this.existing,
    this.onDelete,
    this.onAddAnother,
  });

  final LatLng position;
  final Cue? existing;
  final VoidCallback? onDelete;
  final VoidCallback? onAddAnother;

  @override
  State<CueEditorSheet> createState() => _CueEditorSheetState();
}

class _CueEditorSheetState extends State<CueEditorSheet> {
  late CueType _type;
  late TextEditingController _label;
  late TextEditingController _spoken;
  late double _radius;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _type = e?.type ?? CueType.left;
    _label = TextEditingController(text: e?.label ?? _type.label);
    _spoken = TextEditingController(text: e?.spoken ?? _type.defaultSpoken);
    _radius = e?.radiusMeters ?? 25;
  }

  @override
  void dispose() {
    _label.dispose();
    _spoken.dispose();
    super.dispose();
  }

  /// When the type changes, refresh label/spoken if the user hasn't customised
  /// them away from the previous type's defaults.
  void _selectType(CueType t) {
    setState(() {
      if (_label.text == _type.label) _label.text = t.label;
      if (_spoken.text == _type.defaultSpoken) _spoken.text = t.defaultSpoken;
      _type = t;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The sheet fills at most 90% of the screen (useSafeArea keeps it clear of
    // the status bar); the fields scroll while the actions stay pinned above
    // the nav bar.
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.existing == null ? 'New cue' : 'Edit cue',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in CueType.values)
                        ChoiceChip(
                          selected: _type == t,
                          avatar: Icon(cueIcon(t),
                              size: 18,
                              color: _type == t ? Colors.white : cueColor(t)),
                          label: Text(t.label),
                          selectedColor: cueColor(t),
                          labelStyle:
                              TextStyle(color: _type == t ? Colors.white : null),
                          onSelected: (_) => _selectType(t),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _label,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Map label (short)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _spoken,
                    textCapitalization: TextCapitalization.sentences,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Spoken direction (read aloud)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Trigger distance: ${_radius.round()} m'),
                  Slider(
                    value: _radius,
                    min: 10,
                    max: 60,
                    divisions: 10,
                    label: '${_radius.round()} m',
                    onChanged: (v) => setState(() => _radius = v),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (widget.onAddAnother != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: widget.onAddAnother,
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Add another cue at this same spot'),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                if (widget.onDelete != null)
                  TextButton.icon(
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    Cue(
                      type: _type,
                      position: widget.position,
                      // Placeholder — the caller assigns the real order (new
                      // cues append to the stack; edits keep the original).
                      order: widget.existing?.order ?? 0,
                      label: _label.text.trim().isEmpty
                          ? _type.label
                          : _label.text.trim(),
                      spoken: _spoken.text.trim(),
                      radiusMeters: _radius,
                    ),
                  ),
                  child: const Text('Save cue'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
