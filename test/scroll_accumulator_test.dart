import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/scroll_accumulator.dart';

void main() {
  test('retains sub-line remainder', () {
    final a = ScrollAccumulator(cellHeight: 20);
    expect(a.ingest(dyPx: 12, multiplier: 1), 0);
    expect(a.remainderPx, closeTo(12, 1e-9));
    expect(a.ingest(dyPx: 12, multiplier: 1), 1);
    expect(a.remainderPx, closeTo(4, 1e-9));
  });

  test('negative scroll', () {
    final a = ScrollAccumulator(cellHeight: 10);
    expect(a.ingest(dyPx: -25, multiplier: 1), -2);
    expect(a.remainderPx, closeTo(-5, 1e-9));
  });

  test('cellHeight <= 0 returns 0 lines', () {
    final a = ScrollAccumulator(cellHeight: 0);
    expect(a.ingest(dyPx: 100, multiplier: 1), 0);
  });
}
