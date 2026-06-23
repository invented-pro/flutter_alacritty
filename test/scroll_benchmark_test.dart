@Tags(['benchmark'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/src/rust/api/terminal.dart';
import 'package:flutter_alacritty/src/rust/engine.dart';

import 'support/benchmark_thresholds.dart';
import 'support/rust_test_lib.dart';

const _cols = 80;
const _rows = 24;

/// How far into scrollback the viewport sits before each timed sample.
const _scrollOffset = 50;

int _median(List<int> samples) {
  final sorted = [...samples]..sort();
  return sorted[sorted.length ~/ 2];
}

int _cellCount(RenderUpdate u) {
  var n = 0;
  for (final line in u.lines) {
    n += line.codepoints.length;
  }
  return n;
}

/// Rough FFI payload estimate: columnar u32/u32/u32/u16/u32 per cell.
int _payloadBytes(RenderUpdate u) {
  var bytes = 0;
  for (final line in u.lines) {
    final n = line.codepoints.length;
    bytes += n * 4 * 4 + n * 2; // 4×u32 + u16
  }
  return bytes;
}

Future<void> _fillHistory(TerminalEngine engine) async {
  final sb = StringBuffer();
  for (var i = 0; i < 200; i++) {
    sb.write('line ${i.toString().padLeft(3)}');
    sb.writeCharCode(13);
    sb.writeCharCode(10);
  }
  await engineAdvanceAndTakeDamage(
    engine: engine,
    bytes: Uint8List.fromList(sb.toString().codeUnits),
  );
}

Future<TerminalEngine> _engineAtOffset(int offset) async {
  final engine = engineNew(
    columns: _cols,
    rows: _rows,
    config: TerminalConfig.defaults().engineConfig,
  );
  await _fillHistory(engine);
  await engineScrollToBottom(engine: engine);
  if (offset != 0) {
    await engineScrollLines(engine: engine, delta: offset);
  }
  return engine;
}

Future<({int medianUs, RenderUpdate sample})> _benchFullSnapshot() async {
  RenderUpdate? last;
  final samples = <int>[];
  for (var i = 0; i < kEngineWarmupRuns + kEngineTimedRuns; i++) {
    final engine = await _engineAtOffset(_scrollOffset);
    final sw = Stopwatch()..start();
    last = engineFullSnapshot(engine: engine);
    sw.stop();
    if (i >= kEngineWarmupRuns) samples.add(sw.elapsedMicroseconds);
  }
  return (medianUs: _median(samples), sample: last!);
}

Future<({int medianUs, RenderUpdate sample})> _benchScrollRefresh() async {
  RenderUpdate? last;
  final samples = <int>[];
  for (var i = 0; i < kEngineWarmupRuns + kEngineTimedRuns; i++) {
    final engine = await _engineAtOffset(_scrollOffset - 1);
    final sw = Stopwatch()..start();
    last = await engineScrollLines(engine: engine, delta: 1);
    sw.stop();
    if (i >= kEngineWarmupRuns) samples.add(sw.elapsedMicroseconds);
  }
  return (medianUs: _median(samples), sample: last!);
}

void _reportScroll({
  required String name,
  required int medianUs,
  required RenderUpdate sample,
}) {
  final cells = _cellCount(sample);
  final bytes = _payloadBytes(sample);
  // ignore: avoid_print
  print('[$name] offset=$_scrollOffset  lines=${sample.lines.length}  '
      'cells=$cells  ~${bytes}B payload  median=${medianUs}µs  '
      'full=${sample.full}  scrollLineDelta=${sample.scrollLineDelta}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initRustLibForTests();
  });

  test('scroll refresh vs full snapshot — FFI time and payload', () async {
    final full = await _benchFullSnapshot();
    final scroll = await _benchScrollRefresh();

    _reportScroll(name: 'scroll-full-snapshot', medianUs: full.medianUs, sample: full.sample);
    _reportScroll(name: 'scroll-incremental', medianUs: scroll.medianUs, sample: scroll.sample);

    final ratio = scroll.medianUs / full.medianUs;
    // ignore: avoid_print
    print('[scroll-speedup] ${(full.medianUs / scroll.medianUs).toStringAsFixed(2)}x faster  '
        'cells ${(_cellCount(full.sample) / _cellCount(scroll.sample)).toStringAsFixed(1)}x fewer  '
        'ratio=$ratio');

    expect(full.sample.full, isTrue);
    expect(scroll.sample.full, isFalse);
    expect(scroll.sample.scrollLineDelta, 1);

    expect(_cellCount(full.sample), greaterThanOrEqualTo(kScrollFullSnapshotMinCells));
    expect(_cellCount(scroll.sample), lessThan(kScrollRefreshMaxCells));

    expect(full.medianUs, lessThan(kScrollFullSnapshotMaxUs));
    expect(scroll.medianUs, lessThan(kScrollRefreshMaxUs));
    expect(
      scroll.medianUs / full.medianUs,
      lessThan(kScrollRefreshVsFullSnapshotMaxRatio),
    );
  });
}
