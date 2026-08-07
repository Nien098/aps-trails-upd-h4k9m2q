import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/native_bridge.dart';
import '../services/settings.dart';

/// Which voice reads cues out loud during a walk — its own screen (reached
/// from a "Voice" row in the main Settings screen) since the live,
/// phone-specific voice list can run long and dominated that screen when it
/// was inline there.
class VoiceSettingsScreen extends StatelessWidget {
  const VoiceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          const Text(
              "Which voice reads cues out loud during a walk. Includes "
              'English, Cantonese, Mandarin, and Indonesian voices '
              "installed on this phone — tap the speaker icon to hear one "
              "before choosing it. Walking cues themselves are still "
              "written in English, so a Cantonese/Mandarin/Indonesian "
              "voice will read them in its own accent rather than "
              "translating them.",
              style: TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
          const SizedBox(height: 12),
          const _VoicePicker(),
        ],
      ),
    );
  }
}

/// Lets a walker pick which installed TTS voice reads cues out loud, with a
/// speaker-icon preview per option. The available list is entirely
/// phone-specific (Android's TTS engine + whatever voice packs are
/// installed), so it's queried live via [FlutterTts.getVoices] rather than
/// offered as a fixed set — a voice this app ships as a "default" might not
/// even exist on a given device.
class _VoicePicker extends StatefulWidget {
  const _VoicePicker();

  @override
  State<_VoicePicker> createState() => _VoicePickerState();
}

class _VoicePickerState extends State<_VoicePicker> {
  final _tts = FlutterTts();
  List<Map<String, String>> _voices = [];
  bool _loading = true;
  bool _failed = false;

  /// "name|locale" of the voice currently being previewed, so its icon can
  /// show a spinner instead of every icon spinning at once.
  String? _previewing;

  static const _localeNames = {
    'en-us': 'English (US)',
    'en-gb': 'English (UK)',
    'en-au': 'English (Australia)',
    'en-ca': 'English (Canada)',
    'en-in': 'English (India)',
    'en-ie': 'English (Ireland)',
    'en-za': 'English (South Africa)',
    'en-ng': 'English (Nigeria)',
    'zh-cn': 'Mandarin (China)',
    'zh-tw': 'Mandarin (Taiwan)',
    'zh-hk': 'Chinese (Hong Kong)',
    'cmn-cn': 'Mandarin (China)',
    'cmn-tw': 'Mandarin (Taiwan)',
    'yue-hk': 'Cantonese (Hong Kong)',
    'id-id': 'Indonesian',
  };

  /// Which locale prefixes show up in the picker at all — the app's own
  /// requested languages, per the user. Anything else installed on the
  /// phone (other languages the walker never asked for) stays hidden so
  /// the list doesn't turn into every voice pack on the device.
  static const _allowedPrefixes = ['en', 'zh', 'yue', 'cmn', 'id'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _tts.getVoices as List<dynamic>;
      final voices = <Map<String, String>>[];
      for (final entry in raw) {
        final m = Map<Object?, Object?>.from(entry as Map);
        final name = m['name']?.toString();
        final locale = m['locale']?.toString();
        if (name == null || locale == null) continue;
        final localeLower = locale.toLowerCase();
        if (!_allowedPrefixes.any((p) => localeLower.startsWith(p))) continue;
        // Google's "star" voice family lists here but, on some phones,
        // never actually produces audio — its model data apparently isn't
        // bundled locally despite the "-local" suffix in the name. There's
        // no way to tell that apart from a working voice ahead of time, so
        // hide the whole family rather than leave dead entries in the list.
        if (name.toLowerCase().contains('star')) continue;
        voices.add({'name': name, 'locale': locale});
      }
      voices.sort((a, b) => a['locale']!.compareTo(b['locale']!));
      if (mounted) setState(() => _voices = voices);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _label(String locale) {
    final lower = locale.toLowerCase();
    if (_localeNames.containsKey(lower)) return _localeNames[lower]!;
    if (lower.startsWith('yue')) return 'Cantonese ($locale)';
    if (lower.startsWith('zh') || lower.startsWith('cmn')) {
      return 'Chinese ($locale)';
    }
    if (lower.startsWith('id')) return 'Indonesian ($locale)';
    if (lower.startsWith('en')) return 'English ($locale)';
    return locale;
  }

  /// A short sample line in the voice's own language/script, so previewing
  /// a Cantonese/Mandarin/Indonesian voice actually demonstrates it —
  /// unlike the real walking cues (still English text; see the note above
  /// the picker), this line is written for the language being previewed.
  String _sampleFor(String locale) {
    final lower = locale.toLowerCase();
    if (lower.startsWith('yue') || lower.contains('hk') || lower.contains('tw')) {
      return '向左轉,前面兩百米。'; // Cantonese/Hong Kong/Taiwan — traditional script
    }
    if (lower.startsWith('zh') || lower.startsWith('cmn')) {
      return '向左转,两百米后到达。'; // Mandarin/mainland China — simplified script
    }
    if (lower.startsWith('id')) return 'Belok kiri dalam dua ratus meter.';
    return 'Turn left in two hundred metres.';
  }

  Future<void> _preview(String name, String locale) async {
    final key = '$name|$locale';
    setState(() => _previewing = key);
    try {
      await _tts.setLanguage(locale);
      await _tts.setVoice({'name': name, 'locale': locale});
      await _tts.setSpeechRate(0.44);
      await _tts.speak(_sampleFor(locale));
    } catch (_) {
      // Nothing to show for a failed preview beyond just not speaking —
      // the picker itself still works even if this particular voice can't
      // be previewed right now.
    } finally {
      if (mounted) setState(() => _previewing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
            child: SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator())),
      );
    }
    if (_failed || _voices.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              _failed
                  ? "Couldn't read this phone's installed voices."
                  : 'No English, Cantonese, Mandarin, or Indonesian voices '
                      'found on this phone — using the system default.',
              style: const TextStyle(fontSize: 13, color: Color(0xFF4A4A4A))),
          const SizedBox(height: 8),
          _manageVoicesButton(),
        ],
      );
    }
    return ValueListenableBuilder<String>(
      valueListenable: Settings.instance.ttsVoice,
      builder: (context, selected, _) => RadioGroup<String>(
        groupValue: selected,
        onChanged: (val) => Settings.instance.setTtsVoice(val ?? ''),
        child: Column(
          children: [
            const RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              value: '',
              title: Text('System default'),
            ),
            for (final v in _voices)
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: '${v['name']}|${v['locale']}',
                title: Text(_label(v['locale']!)),
                subtitle: Text(v['name']!,
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFF9A9A9A))),
                secondary: IconButton(
                  icon: _previewing == '${v['name']}|${v['locale']}'
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.volume_up),
                  onPressed: _previewing == null
                      ? () => _preview(v['name']!, v['locale']!)
                      : null,
                ),
              ),
            const SizedBox(height: 4),
            Align(alignment: Alignment.centerLeft, child: _manageVoicesButton()),
          ],
        ),
      ),
    );
  }

  /// Opens Android's own TTS voice-data manager — the only real fix when a
  /// voice is listed here but silent (its model data isn't downloaded), and
  /// also where Cantonese/Mandarin/Indonesian voices can be added if none
  /// showed up above.
  Widget _manageVoicesButton() {
    return TextButton.icon(
      onPressed: NativeBridge.openTtsVoiceData,
      icon: const Icon(Icons.download_outlined, size: 18),
      label: const Text('Manage voices on this phone'),
    );
  }
}
