import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_alacritty/render/cell_metrics.dart';
import 'package:flutter_alacritty/ui/viewport_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cw = 9.0; // typical cell width at default font size
  const ch = 18.0; // typical cell height

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

  group('ViewportGeometryResolver', () {
    const resolver = ViewportGeometryResolver();

    ViewportQuery query(double w, double h) => ViewportQuery(
          available: Size(w, h),
          cell: cell(),
        );

    test('normal 80x24 viewport', () {
      final grid = resolver.resolve(query(80 * cw, 24 * ch));
      expect(grid, isNotNull);
      expect(grid!.cols, 80);
      expect(grid.rows, 24);
    });

    test('fractional width floors down', () {
      // 80 * 9 + 4.5 = 724.5 → cols = floor(724.5/9) = 80
      final grid = resolver.resolve(query(80 * cw + 4.5, 24 * ch));
      expect(grid!.cols, 80);

      // 81 * 9 - 0.5 = 728.5 → cols = floor(728.5/9) = 80
      final grid2 = resolver.resolve(query(81 * cw - 0.5, 24 * ch));
      expect(grid2!.cols, 80);
    });

    test('fractional height floors down', () {
      final grid = resolver.resolve(query(80 * cw, 24 * ch + 8));
      expect(grid!.rows, 24);
    });

    test('rejects too-small but non-zero viewport (transition frame)', () {
      // Below 8 cols
      expect(resolver.resolve(query(7 * cw, 24 * ch)), isNull);
      // Below 4 rows
      expect(resolver.resolve(query(80 * cw, 3 * ch)), isNull);
    });

    test('rejects zero or negative viewport', () {
      expect(resolver.resolve(query(0, 100)), isNull);
      expect(resolver.resolve(query(100, 0)), isNull);
    });

    test('rejects sub-pixel-floor container even when cell grid would be usable',
        () {
      // Tiny cells (2px) would satisfy the 8x4 cell floor at only 16x8 px, but
      // the container is below orca's 48x24 px floor — a transition frame.
      final q = ViewportQuery(
        available: const Size(16, 8),
        cell: CellMetrics(2, 2),
      );
      expect(resolver.resolve(q), isNull);

      // Same tiny cells but a container above the pixel floor → usable grid.
      final q2 = ViewportQuery(
        available: const Size(60, 30),
        cell: CellMetrics(2, 2),
      );
      final grid = resolver.resolve(q2);
      expect(grid, isNotNull);
      expect(grid!.cols, 30);
      expect(grid.rows, 15);
    });

    test('exactly at minimum returns grid', () {
      expect(
        resolver.resolve(query(TerminalGrid.minCols * cw, TerminalGrid.minRows * ch)),
        isNotNull,
      );
    });

    test('reserve subtracts from available', () {
      final q = ViewportQuery(
        available: Size(100 * cw + 14, 30 * ch + 14),
        cell: cell(),
        reserve: const EdgeInsets.only(right: 14, bottom: 14),
      );
      final grid = resolver.resolve(q);
      expect(grid!.cols, 100); // (100*cw+14 - 14) / cw = 100
      expect(grid!.rows, 30); // (30*ch+14 - 14) / ch = 30
    });

    test('reserve horizontal and vertical', () {
      final q = ViewportQuery(
        available: Size(80 * cw + 20, 24 * ch + 20),
        cell: cell(),
        reserve: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      );
      final grid = resolver.resolve(q);
      // (80*cw+20 - 20) / cw = 80, (24*ch+20 - 20) / ch = 24
      expect(grid!.cols, 80);
      expect(grid!.rows, 24);
    });
  });
}
