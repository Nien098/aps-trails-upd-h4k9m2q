import 'package:flutter/foundation.dart';

/// In-memory ring-buffer diagnostic log, built for the desktop web designer's
/// "Debug" panel — a way to get fine-grained timing (routing calls, offline
/// graph merges, live Overpass fetches) out of a real user's browser session
/// without needing DevTools access or a live-connected automation browser
/// (both proved unreliable/unavailable for diagnosing the desktop designer's
/// perf issues in earlier sessions — see the project's memory file). The
/// panel's "Copy" button hands the raw text back for a human to paste
/// straight into chat.
///
/// [enabled] defaults false — every call site checks it before building a
/// log string, so this costs nothing (not even a `DateTime.now()` call) when
/// the panel has never been opened. Shared code (`trail_router.dart`) logs
/// through this too; since it's off by default and only ever toggled on by
/// desktop's debug panel, mobile is completely unaffected either way.
class DebugLog {
  DebugLog._();
  static final DebugLog instance = DebugLog._();

  static const _maxLines = 800;

  bool enabled = false;
  final List<String> _lines = [];

  /// Bumped on every [log]/[clear] call — panels listen to this with an
  /// `AnimatedBuilder`/`ListenableBuilder` to know when to re-render.
  final ValueNotifier<int> version = ValueNotifier(0);

  void log(String message) {
    if (!enabled) return;
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    _lines.add('[$ts] $message');
    if (_lines.length > _maxLines) _lines.removeAt(0);
    version.value++;
  }

  /// Runs [action], logging its wall-clock duration alongside [label]
  /// regardless of whether it throws — the common shape for timing an
  /// existing async call without restructuring it.
  Future<T> time<T>(String label, Future<T> Function() action) async {
    if (!enabled) return action();
    final sw = Stopwatch()..start();
    try {
      final result = await action();
      log('$label — ${sw.elapsedMilliseconds}ms');
      return result;
    } catch (e) {
      log('$label — ${sw.elapsedMilliseconds}ms — threw: $e');
      rethrow;
    }
  }

  List<String> get lines => List.unmodifiable(_lines);
  String get text => _lines.join('\n');

  void clear() {
    _lines.clear();
    version.value++;
  }
}
