import 'dart:async';

import 'viewport_geometry.dart';

/// A callback the policy uses to deliver a committed resize to the PTY.
typedef PtyResizeCommit = void Function(int cols, int rows);

/// Strategy that decides WHEN to send a proposed grid to the PTY.
///
/// The controller calls [onProposal] during layout (synchronous, every frame)
/// and [onFrame] once per frame after layout settles. The policy uses these
/// two signals to decide when the grid is stable enough to commit.
///
/// Pluggable: [ImmediateCommitPolicy] for tests, [StableFrameCommitPolicy]
/// for production. Commit timing is driven by the frame cycle ([onFrame]); the
/// production policy adds a single 150 ms settle timer as a fallback for
/// discrete resizes that go silent before the frame-stability gate converges.
abstract class ResizeCommitPolicy {
  /// Record a grid proposal from this frame's layout pass.
  ///
  /// Called synchronously inside [LayoutBuilder]. May be called multiple
  /// times per frame if the parent rebuilds; consecutive identical proposals
  /// from the same frame are harmless (the policy ignores duplicates).
  void onProposal(TerminalGrid proposed, TerminalGrid current);

  /// Called once per frame after layout (from
  /// `SchedulerBinding.addPostFrameCallback`). The policy may commit now if
  /// its stability criteria are met.
  void onFrame(PtyResizeCommit commit);

  /// Force-commit immediately (transaction end, font-zoom, manual resize).
  void flush(TerminalGrid grid, PtyResizeCommit commit);

  /// Discard pending state (controller disposed, transaction cancelled).
  void cancel();
}

// ---------------------------------------------------------------------------
// Production policy
// ---------------------------------------------------------------------------

/// Waits for the proposed grid to stay identical across consecutive frames
/// before committing to the PTY.
///
/// Counterpart of orca's `pane-fit-resize-observer.ts`. During continuous
/// resize (window drag, divider drag) most frames produce a different grid,
/// so the counter keeps resetting. When the user stops, consecutive identical
/// proposals arrive and the commit fires.
///
/// **Settle timer fallback.** Discrete resizes (sidebar toggle, maximize,
/// worktree switch) produce only 1–2 frames then go silent — the stability
/// count would never reach [maxStabilityFrames]. A settle timer acts as a
/// safety net: if no new proposal arrives within [_settleDuration] of the
/// last [onFrame], the pending proposal is committed. This is the same
/// 150 ms debounce orca uses on its container-level ResizeObserver.
///
/// Safety valve: if the grid changes every frame for
/// [safetyValveFrames] without stabilizing, commit the latest anyway
/// (e.g. animated font-zoom).
class StableFrameCommitPolicy implements ResizeCommitPolicy {
  /// How many consecutive identical proposals must arrive before committing.
  /// Orca uses 2 (adjacent frames with identical proposeDimensions → safeFit).
  /// We match that here — Flutter's single-threaded UI means one layout pass
  /// per frame, so 2 consecutive identical proposals means the grid is stable.
  static const int maxStabilityFrames = 2;

  /// Safety valve: if this many frames pass without the stability gate firing,
  /// commit the latest proposal anyway. Counts TOTAL frames (like orca's rAF
  /// frameCount cap of 8), not just frames where the proposal changed — so
  /// A-B-A jitter and slow continuous drags both converge here.
  static const int safetyValveFrames = 8;

  /// How long to wait after the last [onFrame] before committing a pending
  /// proposal. Matches orca's container-level 150 ms debounce.
  static const _settleDuration = Duration(milliseconds: 150);

  TerminalGrid? _lastProposal;
  int _stabilityCount = 0;
  // Total frames observed since the current pending proposal sequence began —
  // independent of whether the proposal changed each frame (orca's frameCount).
  int _frameCount = 0;
  bool _skipUntilChange = false;
  Timer? _settleTimer;

  @override
  void onProposal(TerminalGrid proposed, TerminalGrid current) {
    // A new proposal arrived — cancel any pending settle timer.
    _settleTimer?.cancel();
    _settleTimer = null;

    // No-op: same as what's already on the PTY. Also sets the skip-until-
    // change flag so subsequent frames don't re-commit the same size.
    if (proposed.cols == current.cols && proposed.rows == current.rows) {
      _stabilityCount = 0;
      _lastProposal = null;
      _frameCount = 0;
      _skipUntilChange = true;
      return;
    }

    // Same as last frame's proposal → stability counter ticks up.
    if (_lastProposal != null &&
        proposed.cols == _lastProposal!.cols &&
        proposed.rows == _lastProposal!.rows) {
      _stabilityCount++;
    } else {
      // Different proposal → reset the stability gate (but NOT the total-frame
      // counter, which spans the whole resize burst).
      _stabilityCount = 1;
      _lastProposal = proposed;
      _skipUntilChange = false;
    }
  }

  @override
  void onFrame(PtyResizeCommit commit) {
    if (_skipUntilChange) return;
    _frameCount++;

    // Converged: at least maxStabilityFrames identical proposals.
    if (_stabilityCount >= maxStabilityFrames && _lastProposal != null) {
      _commit(commit);
      return;
    }

    // Safety valve: too many total frames without the stability gate firing.
    if (_frameCount >= safetyValveFrames && _lastProposal != null) {
      _commit(commit);
      return;
    }

    // Unconverged — arm the settle timer. If no new proposal arrives before
    // it fires, we're in a discrete resize (sidebar toggle, maximize) and
    // should commit now instead of waiting forever.
    _settleTimer ??= Timer(_settleDuration, () {
      _settleTimer = null;
      if (_lastProposal != null && !_skipUntilChange) {
        _commit(commit);
      }
    });
  }

  /// Commit the pending proposal and reset to the post-commit idle state.
  void _commit(PtyResizeCommit commit) {
    _settleTimer?.cancel();
    _settleTimer = null;
    commit(_lastProposal!.cols, _lastProposal!.rows);
    _stabilityCount = 0;
    _lastProposal = null;
    _frameCount = 0;
    _skipUntilChange = true;
  }

  @override
  void flush(TerminalGrid grid, PtyResizeCommit commit) {
    _settleTimer?.cancel();
    _settleTimer = null;
    commit(grid.cols, grid.rows);
    _stabilityCount = 0;
    _lastProposal = null;
    _frameCount = 0;
    _skipUntilChange = true;
  }

  @override
  void cancel() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _stabilityCount = 0;
    _lastProposal = null;
    _frameCount = 0;
    _skipUntilChange = false;
  }
}

// ---------------------------------------------------------------------------
// Test / headless policy
// ---------------------------------------------------------------------------

/// Every proposal is committed synchronously in [onFrame].
///
/// Use in tests where stability gating would add non-determinism, or in
/// headless environments where the frame cycle isn't relevant.
class ImmediateCommitPolicy implements ResizeCommitPolicy {
  TerminalGrid? _pending;

  @override
  void onProposal(TerminalGrid proposed, TerminalGrid current) {
    if (proposed.cols == current.cols && proposed.rows == current.rows) {
      _pending = null;
      return;
    }
    _pending = proposed;
  }

  @override
  void onFrame(PtyResizeCommit commit) {
    final p = _pending;
    if (p != null) {
      _pending = null;
      commit(p.cols, p.rows);
    }
  }

  @override
  void flush(TerminalGrid grid, PtyResizeCommit commit) {
    commit(grid.cols, grid.rows);
    _pending = null;
  }

  @override
  void cancel() {
    _pending = null;
  }
}
