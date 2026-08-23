import 'package:flutter/material.dart';

import 'screens/desktop_designer_screen.dart';
import 'services/settings.dart';

/// Separate entry point for the desktop trail designer (Flutter Web, run via
/// `flutter build web --target lib/main_web.dart` / `flutter run -d chrome -t
/// lib/main_web.dart`) — deliberately NOT `lib/main.dart`'s `TrailGuideApp`.
/// That entry point's import graph (via `HomeScreen` → `NativeBridge`,
/// `CrashLog`, `region.dart`, `offline_map.dart`, ...) pulls in `dart:io` in
/// several places, none of which compile for Flutter web at all — trying to
/// share one entry point between phone and desktop would mean either
/// breaking the web build or stripping `dart:io` out of code the phone app
/// still needs. A second, small, self-contained entry point sidesteps that
/// entirely: it only ever imports the desktop designer's own screen and the
/// handful of pure-Dart services it needs (see that screen's doc for exactly
/// which ones, and why `TrailRouter`/`BaseMap` aren't among them yet either).
Future<void> main() async {
  // Loads Settings.uiScale/chevronScale (and anything else Settings holds)
  // from the browser's localStorage via shared_preferences' web
  // implementation — without this call every ValueNotifier here just keeps
  // its in-memory default forever, so the designer's own "Display size"
  // control (see DesktopDesignerScreen._showDisplaySize) would silently
  // reset on every page reload instead of persisting like it does on
  // mobile.
  await Settings.instance.load();
  runApp(const _DesignerApp());
}

class _DesignerApp extends StatelessWidget {
  const _DesignerApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TrailGuide Designer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          primary: const Color(0xFF1B5E20),
        ),
      ),
      // Mirrors lib/main.dart's own builder: Settings.uiScale multiplies
      // both text and the default icon glyph size app-wide (toolbar/AppBar
      // icons here aren't a fixed-footprint widget like a mobile FAB, so
      // growing the glyph via IconTheme genuinely grows the whole
      // IconButton's tappable area too — no Transform-based HudScale needed
      // on this entry point). Reactive to a live change from
      // DesktopDesignerScreen._showDisplaySize without needing a reload.
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: Settings.instance.uiScale,
        builder: (context, uiScale, child) {
          final mq = MediaQuery.of(context);
          return MediaQuery(
            data: mq.copyWith(textScaler: TextScaler.linear(uiScale)),
            child: IconTheme.merge(
              data: IconThemeData(size: 24 * uiScale),
              child: child!,
            ),
          );
        },
        child: child,
      ),
      home: const DesktopDesignerScreen(),
    );
  }
}
