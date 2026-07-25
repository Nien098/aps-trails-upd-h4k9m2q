import 'package:flutter/material.dart';

import 'models/region.dart';
import 'screens/home_screen.dart';
import 'services/native_bridge.dart';
import 'services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.instance.load();
  await loadUserRegions();
  NativeBridge.init();
  runApp(const TrailGuideApp());
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
        // font-size setting when they've made it bigger.
        final mq = MediaQuery.of(context);
        final scale = mq.textScaler.scale(1.0);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(scale < 1.15 ? 1.15 : scale),
          ),
          child: child!,
        );
      },
      home: const HomeScreen(),
    );
  }
}
