import 'package:flutter/material.dart';

import 'home_page.dart';

void main() => runApp(const RawCompressorApp());

class RawCompressorApp extends StatelessWidget {
  const RawCompressorApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = Colors.teal;
    return MaterialApp(
      title: 'RAW Compressor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: const HomePage(),
    );
  }
}
