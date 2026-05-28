import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/src/rust/api/terminal.dart';
import 'package:flutter_alacritty/src/rust/engine.dart';
import 'package:flutter_alacritty/src/rust/event_proxy.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

/// Rust cdylib filename for the current OS (see cargokit `getArtifactNames`).
String _rustLibFileName() {
  if (Platform.isWindows) return 'rust_lib_flutter_alacritty.dll';
  if (Platform.isMacOS) return 'librust_lib_flutter_alacritty.dylib';
  return 'librust_lib_flutter_alacritty.so';
}

/// Locations a built Rust cdylib may live, fastest/most-likely first.
const _rustDir = 'packages/rust_lib_flutter_alacritty/rust';

List<String> _libCandidates() {
  final name = _rustLibFileName();
  final cargoDebug = '$_rustDir/target/debug/$name';
  final cargoRelease = '$_rustDir/target/release/$name';

  if (Platform.isLinux) {
    return [
      'build/linux/x64/release/bundle/lib/$name',
      'build/linux/x64/debug/bundle/lib/$name',
      cargoRelease,
      cargoDebug,
    ];
  }
  if (Platform.isMacOS) {
    return [
      'build/macos/Build/Products/Release/$name',
      'build/macos/Build/Products/Debug/$name',
      cargoRelease,
      cargoDebug,
    ];
  }
  if (Platform.isWindows) {
    return [
      'build/windows/x64/runner/Release/$name',
      'build/windows/x64/runner/Debug/$name',
      cargoRelease,
      cargoDebug,
    ];
  }
  return [cargoRelease, cargoDebug];
}

/// Returns the path to a usable Rust lib, building it if none is present.
/// Never returns null silently — throws/fails so the FFI boundary is always
/// exercised (no false-green skip).
Future<String> _findOrBuildLib() async {
  for (final p in _libCandidates()) {
    if (File(p).existsSync()) return p;
  }
  // No artifact yet: build it so this test actually runs.
  final result =
      await Process.run('cargo', ['build'], workingDirectory: _rustDir);
  if (result.exitCode != 0) {
    fail('Failed to build the Rust lib for the FFI test '
        '(`cargo build` in $_rustDir/ exited ${result.exitCode}):\n${result.stderr}');
  }
  final built = '$_rustDir/target/debug/${_rustLibFileName()}';
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

  test('advanceAndTakeDamage round-trips and DSR emits a PtyWrite event', () async {
    final engine = engineNew(
      columns: 20,
      rows: 5,
      config: TerminalConfig.defaults().engineConfig,
    );

    final u = await engineAdvanceAndTakeDamage(engine: engine, bytes: 'hi'.codeUnits);
    final line0 = u.lines.firstWhere((l) => l.line == 0);
    expect(String.fromCharCode(line0.cells[0].codepoint), 'h');
    expect(String.fromCharCode(line0.cells[1].codepoint), 'i');

    // DSR cursor-position query → a PtyWrite event, drained by polling.
    await engineAdvanceAndTakeDamage(engine: engine, bytes: '\x1b[6n'.codeUnits);
    final events = engineTakeEvents(engine: engine);
    expect(events.whereType<EngineEvent_PtyWrite>(), isNotEmpty);
  });

  test('search next/prev across the FFI boundary actually moves focus', () async {
    // Mirrors the user's failing scenario: 3 matches on a single line, then
    // verify next/prev cycle the focused match across the real dylib.
    final engine = engineNew(
        columns: 20, rows: 5, config: TerminalConfig.defaults().engineConfig);
    await engineAdvanceAndTakeDamage(engine: engine, bytes: 'foofoofoo'.codeUnits);

    expect(engineSearchSet(engine: engine, pattern: 'foo'), isTrue);
    const flagCurrent = 1 << 10;
    int focusedCol(RenderUpdate u) {
      for (var c = 0; c < u.lines[0].cells.length; c++) {
        if (u.lines[0].cells[c].flags & flagCurrent != 0) return c;
      }
      return -1;
    }

    var u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 0, reason: 'set focuses first match');

    expect(engineSearchNext(engine: engine), isTrue);
    u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 3, reason: 'next should reach col 3');

    expect(engineSearchNext(engine: engine), isTrue);
    u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 6, reason: 'next should reach col 6');

    expect(engineSearchPrev(engine: engine), isTrue);
    u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 3, reason: 'prev should move back to col 3');

    expect(engineSearchPrev(engine: engine), isTrue);
    u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 0, reason: 'prev should move back to col 0');
  });

  test('OSC 8 hyperlink carries hyperlinkId on CellData', () async {
    final engine = engineNew(
      columns: 40,
      rows: 3,
      config: TerminalConfig.defaults().engineConfig,
    );
    // OSC 8: ESC ] 8 ; id ; uri ESC \ TEXT ESC ] 8 ; ; ESC \
    const osc8 = '\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\';
    final u = await engineAdvanceAndTakeDamage(
      engine: engine,
      bytes: osc8.codeUnits,
    );
    final u2 = engineFullSnapshotSearched(engine: engine);
    final snap = u2.lines.isNotEmpty ? u2 : u;
    final cell = snap.lines.firstWhere((l) => l.line == 0).cells[0];
    expect(cell.hyperlinkId, isNonZero);
    expect(cell.flags & (1 << 11), isNonZero);
  });
}
