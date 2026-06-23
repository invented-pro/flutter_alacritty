import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/src/rust/frb_generated.dart';

/// Rust cdylib filename for the current OS (see cargokit `getArtifactNames`).
String rustLibFileName() {
  if (Platform.isWindows) return 'rust_lib_flutter_alacritty.dll';
  if (Platform.isMacOS) return 'librust_lib_flutter_alacritty.dylib';
  return 'librust_lib_flutter_alacritty.so';
}

/// Locations a built Rust cdylib may live, fastest/most-likely first.
const rustDir = 'packages/rust_lib_flutter_alacritty/rust';

List<String> rustLibCandidates() {
  final name = rustLibFileName();
  final cargoDebug = '$rustDir/target/debug/$name';
  final cargoRelease = '$rustDir/target/release/$name';

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
Future<String> findOrBuildRustLib({bool release = false}) async {
  for (final p in rustLibCandidates()) {
    if (File(p).existsSync()) return p;
  }
  final args = release ? ['build', '--release'] : ['build'];
  final result = await Process.run('cargo', args, workingDirectory: rustDir);
  if (result.exitCode != 0) {
    fail('Failed to build the Rust lib (`cargo ${args.join(' ')}` in $rustDir/ '
        'exited ${result.exitCode}):\n${result.stderr}');
  }
  final profile = release ? 'release' : 'debug';
  final built = '$rustDir/target/$profile/${rustLibFileName()}';
  if (!File(built).existsSync()) {
    fail('cargo build succeeded but $built was not produced.');
  }
  return built;
}

/// Initializes FRB against a real cdylib. Safe to call from multiple test files'
/// `setUpAll` — [RustLib.init] is idempotent once loaded.
Future<void> initRustLibForTests({bool preferRelease = true}) async {
  // Prefer release for benchmark stability; fall back to debug if not built.
  String? lib;
  if (preferRelease) {
    final release = '$rustDir/target/release/${rustLibFileName()}';
    if (File(release).existsSync()) lib = release;
  }
  lib ??= await findOrBuildRustLib(release: preferRelease);
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(File(lib).absolute.path),
  );
}
