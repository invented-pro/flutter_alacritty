import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/main.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

const _linuxLib =
    'build/linux/x64/release/bundle/lib/librust_lib_flutter_alacritty.so';

Future<void> _initRustLib() async {
  final libFile = File(_linuxLib);
  if (!libFile.existsSync()) {
    return;
  }
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(libFile.absolute.path),
  );
}

void main() {
  setUpAll(_initRustLib);

  testWidgets(
    'Rust greet round-trip',
    (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      expect(find.textContaining('Hello, Tom!'), findsOneWidget);
    },
    skip: !File(_linuxLib).existsSync(),
  );
}
