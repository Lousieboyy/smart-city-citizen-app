import 'package:flutter/material.dart';
import 'screens/login_screen.dart'; // Import your login screen

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart City App',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFb5dfd6))),
      // APP STARTS HERE: Login is the first thing they see
      home: const LoginScreen(), 
    );
  }
}