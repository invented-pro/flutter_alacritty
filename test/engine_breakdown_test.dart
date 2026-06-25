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

final _ris = Uint8List.fromList('\x1bc'.codeUnits);

Uint8List _payload(String name) {
  final body = File('$_fixtureDir/$name.bin').readAsBytesSync();
  return Uint8List.fromList([..._ris, ...body]);
}

int _median(List<int> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

Future<int> _medianUs(Future<int> Function() run) async {
  for (var i = 0; i < kEngineWarmupRuns; i++) {
    await run();
  }
  final samples = <int>[];
  for (var i = 0; i < kEngineTimedRuns; i++) {
    samples.add(await run());
  }
  return _median(samples);
}

void _printBreakdown(String fixture, Map<String, int> us) {
  final total = us['combined']!;
  // ignore: avoid_print
  print('[$fixture breakdown]  bytes=${us['bytes']}  damage.full=${us['full'] == 1}');
  for (final k in ['parse', 'damage_only', 'two_hop_sum', 'combined']) {
    final v = us[k]!;
    final pct = total > 0 ? (100.0 * v / total) : 0.0;
    // ignore: avoid_print
    print('  $k: ${v}µs (${pct.toStringAsFixed(1)}%)');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    for (final f in [
      'light_cells.bin',
      'medium_cells.bin',
      'unicode.bin',
      'dense_cells.bin',
    ]) {
      expect(File('$_fixtureDir/$f').existsSync(), isTrue,
          reason: 'missing fixture $_fixtureDir/$f — see README there');
    }
    await initRustLibForTests();
  });

  final config = TerminalConfig.defaults().engineConfig;

  for (final fixture in ['light_cells', 'medium_cells', 'unicode', 'dense_cells']) {
    test('breakdown — $fixture', () async {
      final bytes = _payload(fixture);

      final parseUs = await _medianUs(() async {
        final e = engineNew(columns: _cols, rows: _rows, config: config);
        final sw = Stopwatch()..start();
        await engineAdvance(engine: e, bytes: bytes);
        sw.stop();
        return sw.elapsedMicroseconds;
      });

      final combined = await _medianUs(() async {
        final e = engineNew(columns: _cols, rows: _rows, config: config);
        final sw = Stopwatch()..start();
        await engineAdvanceAndTakeDamage(engine: e, bytes: bytes);
        sw.stop();
        return sw.elapsedMicroseconds;
      });

      final fullFlag = await (() async {
        final e = engineNew(columns: _cols, rows: _rows, config: config);
        final u = await engineAdvanceAndTakeDamage(engine: e, bytes: bytes);
        return u.full;
      })();

      final damageOnly = await _medianUs(() async {
        final e = engineNew(columns: _cols, rows: _rows, config: config);
        await engineAdvance(engine: e, bytes: bytes);
        final sw = Stopwatch()..start();
        await engineTakeDamage(engine: e);
        sw.stop();
        return sw.elapsedMicroseconds;
      });

      final twoHop = parseUs + damageOnly;
      _printBreakdown(fixture, {
        'bytes': File('$_fixtureDir/$fixture.bin').lengthSync(),
        'parse': parseUs,
        'damage_only': damageOnly,
        'two_hop_sum': twoHop,
        'combined': combined,
        'full': fullFlag ? 1 : 0,
      });
    });
  }
}
