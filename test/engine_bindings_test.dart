import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/src/rust/api/terminal.dart';
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

  test(
    'engine advance + snapshot round-trips through FFI',
    () {
      final engine = engineNew(columns: 20, rows: 5);
      engineAdvance(engine: engine, bytes: 'hi'.codeUnits);
      final snap = engineSnapshot(engine: engine);
      expect(snap.columns, 20);
      expect(snap.rows, 5);
      expect(String.fromCharCode(snap.cells[0].codepoint), 'h');
      expect(String.fromCharCode(snap.cells[1].codepoint), 'i');
    },
    skip: !File(_linuxLib).existsSync(),
  );
}
