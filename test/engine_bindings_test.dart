import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/src/rust/api/terminal.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

const _libName = 'librust_lib_flutter_alacritty.so';

/// Locations a built Rust cdylib may live, fastest/most-likely first.
const _candidates = [
  'build/linux/x64/release/bundle/lib/$_libName',
  'build/linux/x64/debug/bundle/lib/$_libName',
  'rust/target/release/$_libName',
  'rust/target/debug/$_libName',
];

/// Returns the path to a usable Rust lib, building it if none is present.
/// Never returns null silently — throws/fails so the FFI boundary is always
/// exercised (no false-green skip).
Future<String> _findOrBuildLib() async {
  for (final p in _candidates) {
    if (File(p).existsSync()) return p;
  }
  // No artifact yet: build it so this test actually runs.
  final result = await Process.run('cargo', ['build'], workingDirectory: 'rust');
  if (result.exitCode != 0) {
    fail('Failed to build the Rust lib for the FFI test '
        '(`cargo build` in rust/ exited ${result.exitCode}):\n${result.stderr}');
  }
  const built = 'rust/target/debug/$_libName';
  if (!File(built).existsSync()) {
    fail('cargo build succeeded but $built was not produced.');
  }
  return built;
}

void main() {
  setUpAll(() async {
    final lib = await _findOrBuildLib();
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(File(lib).absolute.path),
    );
  });

  test('engine advance + snapshot round-trips through FFI', () {
    final engine = engineNew(columns: 20, rows: 5);
    engineAdvance(engine: engine, bytes: 'hi'.codeUnits);
    final snap = engineSnapshot(engine: engine);
    expect(snap.columns, 20);
    expect(snap.rows, 5);
    expect(String.fromCharCode(snap.cells[0].codepoint), 'h');
    expect(String.fromCharCode(snap.cells[1].codepoint), 'i');
  });
}
