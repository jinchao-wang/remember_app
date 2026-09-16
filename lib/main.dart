import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const RememberApp());
}

class RememberApp extends StatelessWidget {
  const RememberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remember 记账',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}