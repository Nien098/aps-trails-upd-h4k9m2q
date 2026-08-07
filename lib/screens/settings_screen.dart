import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/native_bridge.dart';
import '../services/settings.dart';
import 'voice_settings_screen.dart';

/// Safety-alert configuration (emergency contact, stillness timing) and the
/// battery-optimization guidance that helps it — and background tracking —
/// actually run reliably.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _phone =
      TextEditingController(text: Settings.instance.emergencyPhone.value);
  bool? _batteryOk; // null = not checked yet

  @override
  void initState() {
    super.initState();
    _checkBattery();
  }

  Future<void> _checkBattery() async {
    final ok = await NativeBridge.isIgnoringBatteryOptimizations();
    if (mounted) setState(() => _batteryOk = ok);
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _toggleSafety(bool value) async {
    if (!value) {
      await Settings.instance.setSafetyEnabled(false);
      setState(() {});
      return;
    }
    final smsStatus = await Permission.sms.request();
    if (!smsStatus.isGranted) {
      _toast('SMS permission is needed for the safety alert');
      return;
    }
    await Settings.instance.setSafetyEnabled(true);
    setState(() {});
  }

  Future<void> _sendTestSms() async {
    final phone = _phone.text.trim();
    if (phone.isEmpty) {
      _toast('Enter an emergency contact number first');
      return;
    }
    await Settings.instance.setEmergencyPhone(phone);
    final smsStatus = await Permission.sms.request();
    if (!smsStatus.isGranted) {
      _toast('SMS permission is needed to send a test');
      return;
    }
    _toast('Sending test message…');
    final ok = await NativeBridge.sendSms(
        phone, 'APS Trails test message — the safety alert is set up correctly.');
    _toast(ok ? 'Test message sent' : "Couldn't send — check signal and the number");
  }

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Safety & battery')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          const Text('Stillness safety alert',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
              "If you stop moving for a while during a walk, this nudges you "
              "on-screen and out loud. If you don't respond, it texts your "
              "emergency contact your last known location. It needs cell "
              "signal to send — this is a helpful nudge, not a substitute for "
              "calling for help.",
              style: TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
          const SizedBox(height: 12),
          ValueListenableBuilder<bool>(
            valueListenable: s.safetyEnabled,
            builder: (context, enabled, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: enabled,
              onChanged: _toggleSafety,
              title: const Text('Enable safety alert'),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: s.sendEmergencySms,
            builder: (context, smsOn, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: smsOn,
              onChanged: s.setSendEmergencySms,
              title: const Text('Send emergency SMS'),
              subtitle: Text(smsOn
                  ? "Off = reminder only — the nudge keeps repeating instead "
                      "of ever texting your contact. Useful just to catch a "
                      "walk left running after you've stopped."
                  : "Reminder only — no text will ever be sent. Turn this "
                      "back on to restore the emergency SMS."),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Emergency contact phone number',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => Settings.instance.setEmergencyPhone(v.trim()),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<int>(
            valueListenable: s.nudgeMinutes,
            builder: (context, minutes, _) => _MinutesRow(
              label: 'Nudge after being still for',
              minutes: minutes,
              onChanged: s.setNudgeMinutes,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: s.sendEmergencySms,
            builder: (context, smsOn, _) => ValueListenableBuilder<int>(
              valueListenable: s.escalateMinutes,
              builder: (context, minutes, _) => _MinutesRow(
                label: smsOn
                    ? 'Then send the alert after another'
                    : 'Then remind again after another',
                minutes: minutes,
                onChanged: s.setEscalateMinutes,
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _sendTestSms,
            icon: const Icon(Icons.sms_outlined),
            label: const Text('Send test message'),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<bool>(
            valueListenable: s.debugStillness,
            builder: (context, enabled, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: enabled,
              onChanged: s.setDebugStillness,
              title: const Text('Show stillness debug overlay'),
              subtitle: const Text(
                  'Testing only — shows phase, still time, GPS fix age/accuracy '
                  'and anchor resets on the walk/record screens.'),
            ),
          ),
          const Divider(height: 40),
          const Text('Battery settings',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
              'Background tracking and the safety alert need Android to not '
              'restrict this app’s battery use — otherwise they may stop '
              'working with the screen off.',
              style: TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _batteryOk == true ? Icons.check_circle : Icons.error_outline,
              color: _batteryOk == true
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFFC62828),
            ),
            title: Text(_batteryOk == true
                ? 'Unrestricted — good to go'
                : 'Battery optimization is restricting this app'),
            trailing: _batteryOk == true
                ? null
                : FilledButton(
                    onPressed: () async {
                      await NativeBridge.requestIgnoreBatteryOptimizations();
                      await Future.delayed(const Duration(seconds: 1));
                      await _checkBattery();
                    },
                    child: const Text('Fix'),
                  ),
          ),
          const SizedBox(height: 12),
          const Text(
              'Samsung phones also have their own separate power-saving list. '
              'Check Settings → Battery → Background usage limits '
              '(or Device care → Battery) and make sure APS Trails is not '
              'in "Sleeping apps" or "Deep sleeping apps".',
              style: TextStyle(fontSize: 13, color: Color(0xFF4A4A4A))),
          const Divider(height: 40),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('Voice',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            subtitle: const Text('Which voice reads cues out loud during a walk'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const VoiceSettingsScreen()),
            ),
          ),
          const Divider(height: 40),
          const Text('Trail drawing',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
              'How far "Follow trails" (in the trail editor) will detour to '
              "trace a real trail's bends between two taps, before giving up "
              'and drawing a straight line instead.',
              style: TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
          const SizedBox(height: 12),
          const _DetourFactorControl(),
          const Divider(height: 40),
          const Text('Map trail lines',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
              "Colour and pattern of the background map's hiking-path lines — "
              "the other trails shown in the area, not the one you're "
              "authoring or following (that always draws in its own colour, "
              "on top). Pick whatever's easiest to follow when a few trails "
              "run close together.",
              style: TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
          const SizedBox(height: 12),
          ValueListenableBuilder<String>(
            valueListenable: s.trailLineColor,
            builder: (context, selected, _) => Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final hex in _trailColorChoices)
                  _ColorSwatch(
                    hex: hex,
                    selected: hex == selected,
                    onTap: () => s.setTrailLineColor(hex),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          ValueListenableBuilder<bool>(
            valueListenable: s.trailLineDashed,
            builder: (context, dashed, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: dashed,
              onChanged: s.setTrailLineDashed,
              title: const Text('Dashed line'),
              subtitle: Text(dashed
                  ? 'Dashed — off for a solid line, easier to follow where '
                      'trails cross or run close together.'
                  : 'Solid line.'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Slider + exact-value text box for [Settings.detourFactor], kept in sync
/// with each other and with the persisted setting.
class _DetourFactorControl extends StatefulWidget {
  const _DetourFactorControl();

  @override
  State<_DetourFactorControl> createState() => _DetourFactorControlState();
}

class _DetourFactorControlState extends State<_DetourFactorControl> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _fmt(Settings.instance.detourFactor.value));
    Settings.instance.detourFactor.addListener(_onExternalChange);
  }

  @override
  void dispose() {
    Settings.instance.detourFactor.removeListener(_onExternalChange);
    _controller.dispose();
    super.dispose();
  }

  static String _fmt(double v) => v.toStringAsFixed(2);

  void _onExternalChange() {
    final text = _fmt(Settings.instance.detourFactor.value);
    if (_controller.text != text) _controller.text = text;
  }

  void _submitText(String text) {
    final v = double.tryParse(text.trim());
    if (v != null) {
      Settings.instance.setDetourFactor(v);
    } else {
      _controller.text = _fmt(Settings.instance.detourFactor.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: Settings.instance.detourFactor,
      builder: (context, value, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Slider(
              value: value,
              min: 1.5,
              max: 6.0,
              divisions: 18, // 0.25x steps
              label: '${value.toStringAsFixed(2)}x',
              onChanged: (v) => Settings.instance.setDetourFactor(v),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 76,
            child: TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                suffixText: 'x',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: _submitText,
              onTapOutside: (_) => _submitText(_controller.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Preset colours offered for the background trail line — distinct from
/// every cue-marker colour and from each other, and legible against the
/// basemap's tan/cream terrain.
const _trailColorChoices = <String>[
  '#3F51B5', // indigo (default)
  '#00695C', // deep teal
  '#B5451F', // the original red-brown, for anyone who preferred it
  '#4E342E', // dark brown
  '#212121', // near-black
  '#6A1B9A', // purple
];

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch(
      {required this.hex, required this.selected, required this.onTap});

  final String hex;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(int.parse('FF${hex.substring(1)}', radix: 16));
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.black : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 20)
            : null,
      ),
    );
  }
}

class _MinutesRow extends StatelessWidget {
  const _MinutesRow(
      {required this.label, required this.minutes, required this.onChanged});
  final String label;
  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 15))),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: minutes > 2 ? () => onChanged(minutes - 1) : null,
          ),
          SizedBox(
            width: 56,
            child: Text('$minutes min',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: minutes < 60 ? () => onChanged(minutes + 1) : null,
          ),
        ],
      ),
    );
  }
}
