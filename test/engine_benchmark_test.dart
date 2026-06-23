@Tags(['benchmark'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/src/rust/api/terminal.dart';

import 'support/benchmark_thresholds.dart';
import 'support/rust_test_lib.dart';

const _fixtureDir = 'test/fixtures/vtebench';
const _cols = 80;
const _rows = 24;

/// RIS — reset terminal state between timed samples (matches vtebench).
final _ris = Uint8List.fromList('\x1bc'.codeUnits);

Uint8List _loadFixture(String name) =>
    File('$_fixtureDir/$name').readAsBytesSync();

int _median(List<int> samples) {
  final sorted = [...samples]..sort();
  return sorted[sorted.length ~/ 2];
}

Future<int> _timeAdvance(Uint8List payload) async {
  final engine = engineNew(
    columns: _cols,
    rows: _rows,
    config: TerminalConfig.defaults().engineConfig,
  );
  final sw = Stopwatch()..start();
  await engineAdvanceAndTakeDamage(engine: engine, bytes: payload);
  sw.stop();
  return sw.elapsedMicroseconds;
}

Future<int> _benchFixture(String binName, {Uint8List? prefix}) async {
  final body = _loadFixture(binName);
  final payload = prefix != null
      ? Uint8List.fromList([...prefix, ...body])
      : body;

  for (var i = 0; i < kEngineWarmupRuns; i++) {
    await _timeAdvance(Uint8List.fromList([..._ris, ...payload]));
  }

  final samples = <int>[];
  for (var i = 0; i < kEngineTimedRuns; i++) {
    samples.add(await _timeAdvance(Uint8List.fromList([..._ris, ...payload])));
  }
  return _median(samples);
}

void _reportEngine(String name, int medianUs, int bytes) {
  final mbps = bytes / medianUs; // bytes per µs → MB/s at 1e6 scale
  final mbPerS = mbps; // µs → s divides by 1e6, bytes → MB divides by 1e6
  // ignore: avoid_print
  print('[$name] ${bytes}B  median=${medianUs}µs  '
      '${mbPerS.toStringAsFixed(1)} MB/s (engineAdvanceAndTakeDamage @ ${_cols}x$_rows)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    for (final f in [
      'medium_cells.bin',
      'unicode.bin',
      'dense_cells.bin',
      'light_cells.bin',
    ]) {
      expect(File('$_fixtureDir/$f').existsSync(), isTrue,
          reason: 'missing fixture $_fixtureDir/$f — see README there');
    }
    await initRustLibForTests();
  });

  test('vtebench medium_cells — vim reflow session', () async {
    final bytes = _loadFixture('medium_cells.bin').length;
    final median = await _benchFixture('medium_cells.bin');
    _reportEngine('medium_cells', median, bytes);
    expect(median, lessThan(kEngineMediumCellsMaxUs));
  });

  test('vtebench unicode — wide glyph flood', () async {
    final bytes = _loadFixture('unicode.bin').length;
    final median = await _benchFixture('unicode.bin');
    _reportEngine('unicode', median, bytes);
    expect(median, lessThan(kEngineUnicodeMaxUs));
  });

  test('vtebench dense_cells — full-grid color/bold churn', () async {
    final bytes = _loadFixture('dense_cells.bin').length;
    final median = await _benchFixture('dense_cells.bin');
    _reportEngine('dense_cells', median, bytes);
    expect(median, lessThan(kEngineDenseCellsMaxUs));
  });

  test('vtebench light_cells — sparse updates', () async {
    final bytes = _loadFixture('light_cells.bin').length;
    final median = await _benchFixture('light_cells.bin');
    _reportEngine('light_cells', median, bytes);
    expect(median, lessThan(kEngineLightCellsMaxUs));
  });
}
