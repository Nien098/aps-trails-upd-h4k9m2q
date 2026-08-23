import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'models/region.dart';
import 'screens/home_screen.dart';
import 'services/crash_log.dart';
import 'services/native_bridge.dart';
import 'services/settings.dart';

/// Runs the whole app inside one error zone so an uncaught exception —
/// anywhere, including inside a GPS stream or timer callback during a walk,
/// which is exactly where this app has no other safety net — gets logged
/// instead of silently taking down the app with no trace of why. This is
/// deliberately a local file (see [CrashLog]), not a cloud crash reporter:
/// this app has no backend and no user accounts to attach a report to.
Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details); // keep default console output
      CrashLog.log('FlutterError', details.exception, details.stack);
    };
    // Errors from the platform side of a Dart isolate (e.g. an async gap the
    // framework itself doesn't wrap) that would otherwise never reach either
    // handler above.
    PlatformDispatcher.instance.onError = (error, stack) {
      CrashLog.log('PlatformDispatcher', error, stack);
      return true; // handled — don't also crash the isolate
    };
    await Settings.instance.load();
    await loadUserRegions();
    NativeBridge.init();
    runApp(const TrailGuideApp());
  }, (error, stack) {
    CrashLog.log('Uncaught', error, stack);
  });
}

class TrailGuideApp extends StatelessWidget {
  const TrailGuideApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E7D32),
        primary: const Color(0xFF1B5E20),
      ),
      // Comfortable, finger-friendly spacing for older hands.
      visualDensity: VisualDensity.comfortable,
    );

    return MaterialApp(
      title: 'TrailGuide',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        // Higher-contrast default text (enlarged via the textScaler below).
        textTheme: base.textTheme.apply(
          bodyColor: const Color(0xFF1A1A1A),
          displayColor: const Color(0xFF1A1A1A),
        ),
        listTileTheme: const ListTileThemeData(
          minVerticalPadding: 14,
          titleTextStyle: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A1A)),
          subtitleTextStyle: TextStyle(fontSize: 16, color: Color(0xFF4A4A4A)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          contentTextStyle: TextStyle(fontSize: 17),
        ),
      ),
      builder: (context, child) {
        // Bump text at least 15% larger, but still honour the user's system
        // font-size setting when they've made it bigger. Settings.uiScale is
        // then applied on top as its own independent multiplier — added for
        // accessibility (parents with low vision), separate from whatever
        // the phone's own system font size already does. Icon glyphs get
        // the same multiplier via IconTheme so unlabelled buttons (map
        // toolbars, FABs) grow too, not just text — note this resizes the
        // icon *glyph*, not a fixed-size widget like FloatingActionButton's
        // own circular footprint (Android has no continuous-size FAB); a
        // few screens (GuideScreen's FAB column, see HudScale) additionally
        // scale the whole button, not just its icon.
        return ValueListenableBuilder<double>(
          valueListenable: Settings.instance.uiScale,
          builder: (context, uiScale, child) {
            final mq = MediaQuery.of(context);
            final systemScale = mq.textScaler.scale(1.0);
            final floor = systemScale < 1.15 ? 1.15 : systemScale;
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(floor * uiScale),
              ),
              child: IconTheme.merge(
                data: IconThemeData(size: 24 * uiScale),
                child: child!,
              ),
            );
          },
          child: child,
        );
      },
      home: const HomeScreen(),
    );
  }
}
