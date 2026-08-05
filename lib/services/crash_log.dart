import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A minimal, local-only crash/error log — this app has no cloud backend and
/// no crash-reporting SDK (Crashlytics/Sentry), so without this there is
/// zero visibility into what actually went wrong when a walker reports "the
/// app crashed." Appends plain-text entries to a file in app documents;
/// never throws itself (a logger that can crash the app it's trying to
/// diagnose would defeat the point), and is capped so it can't grow forever
/// on a phone that's rarely connected to a computer to clear it.
class CrashLog {
  CrashLog._();

  static const _fileName = 'crash_log.txt';
  static const _maxBytes = 512 * 1024; // ~512 KB, trimmed from the head

  /// Records one entry: a short [context] label, the error, and (if
  /// available) its stack trace. Safe to call from any error handler —
  /// failures writing the log are swallowed rather than rethrown.
  static Future<void> log(String context, Object error, [StackTrace? stack]) async {
    try {
      final file = await _file();
      final entry = StringBuffer()
        ..writeln('${DateTime.now().toIso8601String()} [$context]')
        ..writeln(error.toString());
      if (stack != null) entry.writeln(stack.toString());
      entry.writeln('---');
      await file.writeAsString(entry.toString(),
          mode: FileMode.append, flush: true);
      await _trimIfNeeded(file);
    } catch (_) {
      // Logging must never itself throw.
    }
  }

  /// Reads back the whole log (for a future "send diagnostics" screen, or
  /// simply pulling the file off the phone over USB) — empty string if
  /// nothing's ever been logged.
  static Future<String> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<void> _trimIfNeeded(File file) async {
    final len = await file.length();
    if (len <= _maxBytes) return;
    final bytes = await file.readAsBytes();
    // Keep the tail (most recent entries), drop the rest.
    await file.writeAsBytes(bytes.sublist(bytes.length - _maxBytes));
  }
}
