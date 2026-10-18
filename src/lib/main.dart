import 'package:flutter/material.dart';
import 'screens/main_route_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MockLocationApp());
}

class MockLocationApp extends StatelessWidget {
  const MockLocationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mock Location Simulator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MainRouteScreen(),
    );
  }
}