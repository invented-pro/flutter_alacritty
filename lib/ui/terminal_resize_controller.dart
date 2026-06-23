import 'package:flutter/scheduler.dart';

import '../engine/terminal_engine.dart';
import 'resize_commit_policy.dart';
import 'viewport_geometry.dart';

/// One per [TerminalView]. Owns the resize lifecycle for a single terminal pane.
///
/// ## Lock-step commit (engine + PTY together)
///
/// Commits are gated by [ResizeCommitPolicy] — matching orca. `propose()`
/// measures the grid every frame but does not resize until the policy converges
/// (2-frame stability, 150 ms settle, or [commitNow]/transaction flush).
///
/// Actual resize goes through [TerminalEngine.resize], which reflows the engine
/// and mirror before firing [TerminalEngine.onPtyResize] — never the reverse.
///
/// During a [beginTransaction]/[endTransaction] bracket, commits are queued
/// and flushed once at the outermost end.
class TerminalResizeController {
  TerminalResizeController({
    required TerminalEngine engine,
    ResizeCommitPolicy? policy,
    ViewportGeometryResolver? resolver,
    void Function(void Function())? scheduleFrame,
    TerminalGrid? initialGrid,
  })  : _engine = engine,
        _policy = policy ?? StableFrameCommitPolicy(),
        _resolver = resolver ?? const ViewportGeometryResolver(),
        _scheduleFrame = scheduleFrame ??
            ((cb) => SchedulerBinding.instance.addPostFrameCallback((_) => cb())),
        _current = initialGrid ?? const TerminalGrid(80, 24);

  final TerminalEngine _engine;
  final ResizeCommitPolicy _policy;
  final ViewportGeometryResolver _resolver;
  final void Function(void Function()) _scheduleFrame;

  TerminalGrid _current;

  TerminalGrid get current => _current;

  TerminalGrid? _committedPty;

  TerminalGrid? get committed => _committedPty;

  int _transactionDepth = 0;

  TerminalGrid? _queuedTransactionGrid;

  bool _frameScheduled = false;

  TerminalGrid propose(ViewportQuery query) {
    final proposed = _resolver.resolve(query);

    final effective = proposed ?? _current;
    _current = effective;

    if (_transactionDepth > 0 && proposed != null) {
      _queuedTransactionGrid = proposed;
    } else if (proposed != null) {
      _policy.onProposal(
        proposed,
        _committedPty ?? TerminalGrid.sentinel,
      );
      _scheduleFrameCallback();
    }

    return effective;
  }

  void beginTransaction() {
    _transactionDepth++;
  }

  void endTransaction({bool flush = true}) {
    if (_transactionDepth <= 0) return;
    _transactionDepth--;
    if (_transactionDepth == 0) {
      final grid = _queuedTransactionGrid;
      _queuedTransactionGrid = null;
      if (flush && grid != null) {
        _policy.flush(grid, _commitPty);
      }
    }
  }

  void commitNow() {
    _policy.flush(_current, _commitPty);
  }

  void dispose() {
    _policy.cancel();
  }

  void _commitPty(int cols, int rows) {
    if (_committedPty != null &&
        _committedPty!.cols == cols &&
        _committedPty!.rows == rows) {
      return;
    }
    _committedPty = TerminalGrid(cols, rows);
    _engine.resize(columns: cols, rows: rows);
  }

  void _scheduleFrameCallback() {
    if (_frameScheduled) return;
    _frameScheduled = true;
    _scheduleFrame(() {
      _frameScheduled = false;
      if (_transactionDepth > 0) return;
      // First commit bootstraps the PTY — skip stability gating so the shell
      // spawns on the first layout frame instead of waiting 2 frames / 150 ms.
      if (_committedPty == null) {
        _commitPty(_current.cols, _current.rows);
        return;
      }
      _policy.onFrame(_commitPty);
    });
  }
}
