import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'screens/home_screen.dart';

// Hlavní spouštěcí funkce programu
void main() async {
  await dotenv.load(fileName: ".env");
  runApp(const FoodSwipeApp());
}

// Základní konfigurace aplikace
class FoodSwipeApp extends StatelessWidget {
  const FoodSwipeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FoodSwipe 🔥',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: const Color(0xFFFF6B6B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF6B6B),
          secondary: Color(0xFFFF6B6B),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF121212),
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}