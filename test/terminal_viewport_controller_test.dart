import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/render/cell_metrics.dart';
import 'package:flutter_alacritty/ui/terminal_viewport_controller.dart';
import 'package:flutter_alacritty/ui/viewport_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cw = 9.0;
  const ch = 18.0;
  CellMetrics cell() => CellMetrics(cw, ch);

  ViewportQuery query(int cols, int rows) => ViewportQuery(
        available: Size(cols * cw, rows * ch),
        cell: cell(),
      );

  group('TerminalViewportController', () {
    late TerminalEngine engine;
    late FakeBinding binding;
    late TerminalViewportController controller;
    late List<({int cols, int rows})> ptyCommits;

    setUp(() {
      binding = FakeBinding();
      engine = TerminalEngine.fromBinding(
        binding,
        config: TerminalConfig.defaults(),
        schedule: (_) {},
      );
      ptyCommits = [];
      controller = TerminalViewportController(
        engine: engine,
        onPtyResize: (cols, rows) {
          ptyCommits.add((cols: cols, rows: rows));
        },
      );
    });

    tearDown(() {
      controller.dispose();
      engine.dispose();
    });

    test('apply resizes engine synchronously on first layout', () {
      controller.apply(query(80, 24));
      expect(binding.resizeCalls, 1);
      expect(binding.lastResizeCols, 80);
      expect(binding.lastResizeRows, 24);
      expect(ptyCommits.length, 1);
      expect(controller.committed!.columns, 80);
    });

    test('apply resizes engine immediately when grid changes', () {
      controller.apply(query(80, 24));
      final callsAfterFirst = binding.resizeCalls;

      controller.apply(query(100, 30));
      expect(binding.resizeCalls, callsAfterFirst + 1);
      expect(binding.lastResizeCols, 100);
      expect(ptyCommits.length, 2);
    });

    test('same grid skips redundant engine resize', () {
      controller.apply(query(80, 24));
      final calls = binding.resizeCalls;
      final ptyCount = ptyCommits.length;

      controller.apply(query(80, 24));
      expect(binding.resizeCalls, calls);
      expect(ptyCommits.length, ptyCount);
    });

    test('cell-boundary drag within one column emits no extra PTY resize', () {
      controller.apply(query(80, 24));
      final ptyCount = ptyCommits.length;

      for (var w = 80 * cw; w < 81 * cw; w += 2) {
        controller.apply(ViewportQuery(
          available: Size(w, 24 * ch),
          cell: cell(),
        ));
      }
      expect(ptyCommits.length, ptyCount);
    });

    test('pty hold defers SIGWINCH until endPtyHold', () {
      controller.apply(query(80, 24));
      ptyCommits.clear();

      controller.beginPtyHold();
      controller.apply(query(100, 30));
      expect(binding.resizeCalls, greaterThan(1));
      expect(ptyCommits, isEmpty);

      controller.endPtyHold();
      expect(ptyCommits.length, 1);
      expect(ptyCommits.first.cols, 100);
    });

    test('nested pty hold flushes on outermost end', () {
      controller.apply(query(80, 24));
      ptyCommits.clear();

      controller.beginPtyHold();
      controller.apply(query(100, 30));
      controller.beginPtyHold();
      controller.apply(query(120, 40));
      controller.endPtyHold();
      expect(ptyCommits, isEmpty);

      controller.endPtyHold();
      expect(ptyCommits.length, 1);
      expect(ptyCommits.first.cols, 120);
    });

    test('endPtyHold with flush:false discards held resize', () {
      controller.apply(query(80, 24));
      ptyCommits.clear();

      controller.beginPtyHold();
      controller.apply(query(100, 30));
      controller.endPtyHold(flush: false);
      expect(ptyCommits, isEmpty);
    });
  });
}
