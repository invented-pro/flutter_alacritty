import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_alacritty/render/cell_metrics.dart';
import 'package:flutter_alacritty/ui/viewport_geometry.dart';
import 'package:flutter_alacritty/ui/viewport_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cw = 9.0;
  const ch = 18.0;

  CellMetrics cell() => CellMetrics(cw, ch);

  group('TerminalGrid', () {
    test('equality', () {
      expect(const TerminalGrid(80, 24), const TerminalGrid(80, 24));
      expect(const TerminalGrid(80, 24), isNot(const TerminalGrid(80, 25)));
    });

    test('isUsable', () {
      expect(TerminalGrid.isUsable(8, 4), isTrue);
      expect(TerminalGrid.isUsable(8, 3), isFalse);
      expect(TerminalGrid.isUsable(7, 4), isFalse);
      expect(TerminalGrid.isUsable(0, 0), isFalse);
    });
  });

  group('ViewportResolver', () {
    const resolver = ViewportResolver();

    ViewportQuery query(double w, double h) => ViewportQuery(
          available: Size(w, h),
          cell: cell(),
        );

    test('normal 80x24 viewport', () {
      final vp = resolver.resolve(query(80 * cw, 24 * ch));
      expect(vp.columns, 80);
      expect(vp.screenLines, 24);
      expect(vp.paddingX, 0);
      expect(vp.paddingY, 0);
    });

    test('fractional remainder becomes dynamic padding', () {
      final vp = resolver.resolve(query(80 * cw + 4.5, 24 * ch + 8));
      expect(vp.columns, 80);
      expect(vp.screenLines, 24);
      expect(vp.paddingX, closeTo(2.25, 0.001));
      expect(vp.paddingY, closeTo(4.0, 0.001));
      expect(
        vp.paddingX * 2 + vp.cellAreaWidth,
        closeTo(vp.windowWidth, 0.001),
      );
      expect(
        vp.paddingY * 2 + vp.cellAreaHeight,
        closeTo(vp.windowHeight, 0.001),
      );
    });

    test('clamps to minimum grid when container is tiny', () {
      final vp = resolver.resolve(query(7 * cw, 3 * ch));
      expect(vp.columns, TerminalGrid.minCols);
      expect(vp.screenLines, TerminalGrid.minRows);
    });

    test('zero viewport still returns minimum grid', () {
      final vp = resolver.resolve(query(0, 0));
      expect(vp.columns, TerminalGrid.minCols);
      expect(vp.screenLines, TerminalGrid.minRows);
    });

    test('tiny cells clamp to floor with padding', () {
      final q = ViewportQuery(
        available: const Size(16, 8),
        cell: CellMetrics(2, 2),
      );
      final vp = resolver.resolve(q);
      expect(vp.columns, TerminalGrid.minCols);
      expect(vp.screenLines, TerminalGrid.minRows);
    });

    test('reserve subtracts from available', () {
      final q = ViewportQuery(
        available: Size(100 * cw + 14, 30 * ch + 14),
        cell: cell(),
        reserve: const EdgeInsets.only(right: 14, bottom: 14),
      );
      final vp = resolver.resolve(q);
      expect(vp.columns, 100);
      expect(vp.screenLines, 30);
    });
  });
}
