import 'package:flutter/material.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';
import 'package:flutter_alacritty/ui/terminal_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: TerminalScreen(),
    );
  }
}
