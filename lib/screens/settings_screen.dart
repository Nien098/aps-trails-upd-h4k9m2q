import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/native_bridge.dart';
import '../services/settings.dart';

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
        ],
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
