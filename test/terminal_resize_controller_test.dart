import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/render/cell_metrics.dart';
import 'package:flutter_alacritty/ui/resize_commit_policy.dart';
import 'package:flutter_alacritty/ui/terminal_resize_controller.dart';
import 'package:flutter_alacritty/ui/viewport_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_binding.dart';

/// A frame scheduler that executes callbacks synchronously and collects
/// them in a list so tests can inspect what was scheduled.
class TestFrameScheduler {
  final List<void Function()> scheduled = [];

  void schedule(void Function() callback) {
    scheduled.add(callback);
  }

  /// Execute and clear all pending frame callbacks.
  void flush() {
    while (scheduled.isNotEmpty) {
      final cb = scheduled.removeAt(0);
      cb();
    }
  }

  /// Execute exactly one pending frame callback.
  void flushOne() {
    if (scheduled.isNotEmpty) {
      scheduled.removeAt(0)();
    }
  }

  void clear() => scheduled.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cw = 9.0;
  const ch = 18.0;
  CellMetrics cell() => CellMetrics(cw, ch);

  ViewportQuery query(int cols, int rows) => ViewportQuery(
        available: Size(cols * cw, rows * ch),
        cell: cell(),
      );

  group('TerminalResizeController', () {
    late TerminalEngine engine;
    late FakeBinding binding;
    late TerminalResizeController controller;
    late TestFrameScheduler frameScheduler;
    late List<({int cols, int rows})> ptyCommits;

    setUp(() {
      binding = FakeBinding();
      engine = TerminalEngine.fromBinding(
        binding,
        config: TerminalConfig.defaults(),
      );
      frameScheduler = TestFrameScheduler();
      ptyCommits = [];
      controller = TerminalResizeController(
        engine: engine,
        policy: ImmediateCommitPolicy(), // deterministic for unit tests
        scheduleFrame: frameScheduler.schedule,
      );
      engine.onPtyResize = (cols, rows) {
        ptyCommits.add((cols: cols, rows: rows));
      };
    });

    tearDown(() {
      controller.dispose();
      engine.dispose();
    });

    // ── Display commit ──────────────────────────────────────────────────

    test('engine resize called on first proposal', () {
      controller.propose(query(80, 24));
      frameScheduler.flush();
      expect(binding.resizeCalls, greaterThan(0));
      expect(controller.current, const TerminalGrid(80, 24));
    });

    test('initialGrid seeds current without committing', () {
      controller.dispose();
      controller = TerminalResizeController(
        engine: engine,
        policy: ImmediateCommitPolicy(),
        scheduleFrame: frameScheduler.schedule,
        initialGrid: const TerminalGrid(100, 30),
      );
      engine.onPtyResize = (cols, rows) {
        ptyCommits.add((cols: cols, rows: rows));
      };

      expect(controller.current, const TerminalGrid(100, 30));
      expect(binding.resizeCalls, 0);
      expect(ptyCommits, isEmpty);
    });

    test('engine not resized on subsequent proposal (only on commit)', () {
      // First proposal initializes the engine
      controller.propose(query(80, 24));
      frameScheduler.flush();
      expect(binding.resizeCalls, greaterThan(0));

      // Second proposal does NOT resize engine — it waits for policy commit
      final callsAfterFirst = binding.resizeCalls;
      controller.propose(query(100, 30));
      expect(binding.resizeCalls, callsAfterFirst); // engine unchanged
    });

    test('null proposal keeps current grid', () {
      controller.propose(query(80, 24));
      frameScheduler.flush();

      // A transition-frame query (too small) → null
      final nullQuery = query(3, 2); // below min 8×4
      controller.propose(nullQuery);
      expect(controller.current, const TerminalGrid(80, 24));
    });

    test('null proposal does not schedule PTY commit callback', () {
      controller.propose(query(80, 24));
      frameScheduler.clear(); // clear frame callback from first proposal

      controller.propose(query(3, 2)); // null — transition frame
      expect(frameScheduler.scheduled, isEmpty); // no frame callback scheduled
    });

    // ── PTY commit through ImmediateCommitPolicy ────────────────────────

    test('commits PTY on frame after proposal', () {
      controller.propose(query(100, 30));
      expect(ptyCommits, isEmpty); // not yet — waiting for frame

      frameScheduler.flush();
      expect(ptyCommits.length, 1);
      expect(ptyCommits.first.cols, 100);
    });

    test('frame callback deduplication — only one callback per frame', () {
      controller.propose(query(100, 30));
      controller.propose(query(100, 30));
      // _frameScheduled flag prevents double-posting
      expect(frameScheduler.scheduled.length, 1);

      frameScheduler.flush();
      expect(ptyCommits.length, 1);
    });

    // ── Transactions ────────────────────────────────────────────────────

    test('transaction queues PTY resize, flushes on end', () {
      controller.propose(query(80, 24));
      frameScheduler.flush();
      final ptyBefore = ptyCommits.length;

      controller.beginTransaction();
      controller.propose(query(100, 30)); // queued, not committed
      controller.propose(query(120, 40)); // overwrites queued
      frameScheduler.flush();
      expect(ptyCommits.length, ptyBefore); // no PTY commit during transaction

      controller.endTransaction(flush: true);
      // flush is synchronous
      expect(ptyCommits.length, ptyBefore + 1);
      expect(ptyCommits.last.cols, 120);
      expect(ptyCommits.last.rows, 40);
    });

    test('endTransaction with flush:false discards queued grid', () {
      controller.propose(query(80, 24));
      frameScheduler.flush();
      final ptyBefore = ptyCommits.length;

      controller.beginTransaction();
      controller.propose(query(100, 30));
      controller.endTransaction(flush: false);

      expect(ptyCommits.length, ptyBefore);
    });

    test('nested transactions flush only on outermost end', () {
      controller.propose(query(80, 24));
      frameScheduler.flush();
      final ptyBefore = ptyCommits.length;

      controller.beginTransaction();
      controller.propose(query(100, 30));
      controller.beginTransaction(); // nested
      controller.propose(query(120, 40));

      // Inner end: does NOT flush
      controller.endTransaction(flush: true);
      expect(ptyCommits.length, ptyBefore);

      // Outer end: flushes
      controller.endTransaction(flush: true);
      expect(ptyCommits.length, ptyBefore + 1);
      expect(ptyCommits.last.cols, 120);
    });

    test('unbalanced endTransaction is safe', () {
      expect(() => controller.endTransaction(), returnsNormally);
    });

    // ── commitNow ───────────────────────────────────────────────────────

    test('commitNow flushes current grid synchronously', () {
      controller.propose(query(100, 30));
      expect(ptyCommits, isEmpty);

      controller.commitNow();
      expect(ptyCommits.length, 1);
      expect(ptyCommits.last.cols, 100);
    });
  });

  group('TerminalResizeController with StableFrameCommitPolicy', () {
    late TerminalEngine engine;
    late FakeBinding binding;
    late TerminalResizeController controller;
    late TestFrameScheduler frameScheduler;
    late List<({int cols, int rows})> ptyCommits;

    setUp(() {
      binding = FakeBinding();
      engine = TerminalEngine.fromBinding(
        binding,
        config: TerminalConfig.defaults(),
      );
      frameScheduler = TestFrameScheduler();
      ptyCommits = [];
      controller = TerminalResizeController(
        engine: engine,
        policy: StableFrameCommitPolicy(),
        scheduleFrame: frameScheduler.schedule,
      );
      engine.onPtyResize = (cols, rows) {
        ptyCommits.add((cols: cols, rows: rows));
      };
    });

    tearDown(() {
      controller.dispose();
      engine.dispose();
    });

    test('commits PTY after 2 stable frames (matches orca)', () {
      controller.propose(query(80, 24));
      frameScheduler.flushOne();
      expect(ptyCommits.length, 1);
      ptyCommits.clear();

      // Resize burst: first stable frame is not enough.
      controller.propose(query(100, 30));
      frameScheduler.flushOne();
      expect(ptyCommits, isEmpty);

      // Second identical proposal → commit
      controller.propose(query(100, 30));
      frameScheduler.flushOne();
      expect(ptyCommits.length, 1);
      expect(ptyCommits.first.cols, 100);
    });

    test('resets on different proposal', () {
      controller.propose(query(80, 24));
      frameScheduler.flushOne();
      ptyCommits.clear();

      // One stable frame on a new size
      controller.propose(query(100, 30));
      frameScheduler.flushOne();

      // Different proposal → stability resets to 1
      controller.propose(query(120, 40));
      frameScheduler.flushOne();
      expect(ptyCommits, isEmpty);

      // One more identical → commit
      controller.propose(query(120, 40));
      frameScheduler.flushOne();
      expect(ptyCommits.length, 1);
      expect(ptyCommits.first.cols, 120);
    });

    test('skips commit when proposal matches committed grid (orca parity)', () {
      for (var i = 0; i < 2; i++) {
        controller.propose(query(100, 30));
        frameScheduler.flushOne();
      }
      expect(ptyCommits.length, 1);

      controller.propose(query(100, 30));
      frameScheduler.flushOne();
      expect(ptyCommits.length, 1);
    });
  });
}
