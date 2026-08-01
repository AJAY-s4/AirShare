import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/home_screen.dart';
import 'services/socket_service.dart';

final ValueNotifier<ThemeMode> appThemeNotifier =
    ValueNotifier(ThemeMode.system);

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Pre-connect to the Render Socket.IO server on app startup
  SocketService().connect();

  runApp(const AirShareApp());
}

class AirShareApp extends StatelessWidget {
  const AirShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'AirShare',
          debugShowCheckedModeBanner: false,
          themeMode: currentMode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF1F5F9), // Light Slate
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0077FF), // Bright Blue
              brightness: Brightness.light,
            ),
            textTheme: GoogleFonts.outfitTextTheme(ThemeData.light().textTheme),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF0B0F19), // Deep Space Blue
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF00F0FF), // Neon Cyan
              brightness: Brightness.dark,
            ),
            textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
          ),
          home: const HomeScreen(),
        );
      },
    );
  }
}
