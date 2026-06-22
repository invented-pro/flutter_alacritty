import 'package:flutter/scheduler.dart';

import '../engine/terminal_engine.dart';
import 'resize_commit_policy.dart';
import 'viewport_geometry.dart';

/// One per [TerminalView]. Owns the resize lifecycle for a single terminal pane.
///
/// ## Lock-step commit (engine + PTY together)
///
/// Engine and PTY resize **together**, only when the [ResizeCommitPolicy]
/// commits — matching orca. `propose()` measures the grid every frame and
/// records it with the policy, but does NOT resize the engine (except the
/// one-time init on the first proposal). During a continuous drag the painter
/// keeps rendering the last committed grid (empty space on the right, like
/// orca's CSS-stretched canvas); when the policy converges — 2-frame stability,
/// the 150 ms settle, or a [commitNow]/transaction flush — [_commitPty] resizes
/// the engine and the PTY in one atomic step. This avoids the per-cell-boundary
/// reflow that made drags feel janky.
///
/// During a [beginTransaction]/[endTransaction] bracket, PTY commits are queued
/// and flushed once at the outermost end.
///
/// ## Transaction API
///
/// [beginTransaction] / [endTransaction] bracket structural layout changes.
/// Nesting-safe — only the outermost [endTransaction] flushes. Use via
/// [TerminalLayoutCoordinator] for app-level coordination across panes.
class TerminalResizeController {
  TerminalResizeController({
    required TerminalEngine engine,
    ResizeCommitPolicy? policy,
    ViewportGeometryResolver? resolver,
    void Function(void Function())? scheduleFrame,
  })  : _engine = engine,
        _policy = policy ?? StableFrameCommitPolicy(),
        _resolver = resolver ?? const ViewportGeometryResolver(),
        _scheduleFrame = scheduleFrame ??
            ((cb) => SchedulerBinding.instance.addPostFrameCallback((_) => cb()));

  final TerminalEngine _engine;
  final ResizeCommitPolicy _policy;
  final ViewportGeometryResolver _resolver;

  /// Latest *proposed* grid from layout — the size the viewport could host this
  /// frame. Under lock-step this can LEAD the engine/PTY during a drag (it only
  /// becomes authoritative once the policy commits it via [_commitPty]). Read
  /// [committed] for what the subprocess actually has.
  TerminalGrid _current = const TerminalGrid(80, 24);

  /// The latest proposed grid (see [_current]). Used at spawn time as the
  /// best fresh measurement before anything has been committed.
  TerminalGrid get current => _current;

  /// The grid last committed to the engine + PTY (what the subprocess received
  /// via SIGWINCH). Lags [current] during a continuous drag. Null until the
  /// first commit, ensuring the first proposal is NEVER skipped by a same-size
  /// check.
  TerminalGrid? _committedPty;

  /// The grid actually committed to the engine + PTY, or null before the first
  /// commit. Prefer this over [current] when you need the authoritative size
  /// the subprocess is running at.
  TerminalGrid? get committed => _committedPty;

  /// Whether the controller ran at least one proposal (engine initialized).
  bool _initialized = false;

  /// How many layout-transaction holds are active (nesting-safe).
  int _transactionDepth = 0;

  /// Grid queued during a transaction — flushed on outermost endTransaction.
  TerminalGrid? _queuedTransactionGrid;

  /// Callback to the transport layer. Set once by the session host.
  void Function(int cols, int rows)? onPtyResize;

  /// Whether a frame callback is already scheduled (prevents double-posting).
  bool _frameScheduled = false;

  final void Function(void Function()) _scheduleFrame;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Called from [TerminalView]'s [LayoutBuilder] every frame.
  ///
  /// Returns the grid the viewport CAN support. The engine is NOT resized
  /// here — matching orca's behavior where the xterm.js canvas stretches
  /// via CSS but the grid only changes when [safeFit] fires. During
  /// continuous resize the display shows the committed grid (with empty
  /// space on the right), then transitions cleanly when the policy commits.
  TerminalGrid propose(ViewportQuery query) {
    final proposed = _resolver.resolve(query);

    // Transition frame with unusable geometry: keep current grid.
    final effective = proposed ?? _current;
    _current = effective;

    // Initialize the engine on first real proposal — it must exist before
    // any PTY output arrives. After init, engine stays at committed size
    // until _commitPty resizes it.
    if (!_initialized && proposed != null) {
      _engine.resize(columns: effective.cols, rows: effective.rows);
      _engine.initializeEmpty(effective.rows, effective.cols);
      _initialized = true;
    }

    // ── PTY commit (gated by policy) ──
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

  /// Begin a layout transaction. PTY resizes are queued instead of sent.
  /// Nesting-safe: each call must be matched by [endTransaction].
  void beginTransaction() {
    _transactionDepth++;
  }

  /// End a layout transaction. If this was the outermost, flush the queued
  /// grid to the PTY (if [flush] is true) or discard it.
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

  /// Force an immediate PTY commit (font-zoom, manual resize, startup).
  void commitNow() {
    _policy.flush(_current, _commitPty);
  }

  /// Free resources. Call when the [TerminalView] is disposed.
  ///
  /// The controller is bound to one engine for life; an engine swap requires a
  /// fresh controller (the host disposes this one and creates a new one).
  void dispose() {
    _policy.cancel();
    onPtyResize = null;
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  void _commitPty(int cols, int rows) {
    _committedPty = TerminalGrid(cols, rows);
    // Engine resize HERE, not in propose(). Matches orca: grid changes only
    // at stability, not every cell-boundary crossing during a drag.
    _engine.resize(columns: cols, rows: rows);
    onPtyResize?.call(cols, rows);
  }

  void _scheduleFrameCallback() {
    if (_frameScheduled) return;
    _frameScheduled = true;
    _scheduleFrame(() {
      _frameScheduled = false;
      // During a transaction, PTY commits are deferred — don't let a stale
      // frame callback fire policy decisions with pre-transaction state.
      if (_transactionDepth > 0) return;
      _policy.onFrame(_commitPty);
    });
  }
}
