import 'package:flutter/material.dart';

import 'screens/desktop_designer_screen.dart';

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
void main() {
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
      home: const DesktopDesignerScreen(),
    );
  }
}
