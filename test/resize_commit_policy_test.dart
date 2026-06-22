import 'dart:async';

import 'package:flutter_alacritty/ui/resize_commit_policy.dart';
import 'package:flutter_alacritty/ui/viewport_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final c80x24 = const TerminalGrid(80, 24); // "current" (what PTY already has)
  final p100x30 = const TerminalGrid(100, 30);
  final p120x40 = const TerminalGrid(120, 40);
  final p140x50 = const TerminalGrid(140, 50);

  /// Makes a [PtyResizeCommit] that captures its last call.
  PtyResizeCommit capture(void Function(int cols, int rows) onCommit) {
    return (cols, rows) => onCommit(cols, rows);
  }

  group('StableFrameCommitPolicy', () {
    late StableFrameCommitPolicy policy;
    late int lastCols, lastRows, commitCount;

    void commit(int cols, int rows) {
      lastCols = cols;
      lastRows = rows;
      commitCount++;
    }

    setUp(() {
      policy = StableFrameCommitPolicy();
      lastCols = 0;
      lastRows = 0;
      commitCount = 0;
    });

    // Cancel any armed 150ms settle timer so it can't fire during a later
    // (async) test and bump its commit counter.
    tearDown(() => policy.cancel());

    test('does not commit on first proposal', () {
      policy.onProposal(p100x30, c80x24);
      policy.onFrame(commit);
      expect(commitCount, 0);
    });

    test('commits after maxStabilityFrames identical proposals', () {
      for (var i = 0; i < StableFrameCommitPolicy.maxStabilityFrames; i++) {
        policy.onProposal(p100x30, c80x24);
        policy.onFrame(commit);
      }
      expect(commitCount, 1);
      expect(lastCols, 100);
      expect(lastRows, 30);
    });

    test('commits on second identical proposal (matches orca 2-frame stability)', () {
      // 1st proposal: stability=1, no commit
      policy.onProposal(p100x30, c80x24);
      policy.onFrame(commit);
      expect(commitCount, 0);

      // 2nd identical proposal: stability=2 → commit
      policy.onProposal(p100x30, c80x24);
      policy.onFrame(commit);
      expect(commitCount, 1);
    });

    test('resets stability counter on different proposal', () {
      // 1 identical proposal
      policy.onProposal(p100x30, c80x24);
      policy.onFrame(commit);

      // Different proposal — counter resets to stability=1
      policy.onProposal(p120x40, c80x24);
      policy.onFrame(commit);
      expect(commitCount, 0);

      // 1 more identical: stability=2 → commit
      policy.onProposal(p120x40, c80x24);
      policy.onFrame(commit);
      expect(commitCount, 1);
      expect(lastCols, 120);
    });

    test('skips when proposal matches current', () {
      // Propose same as current
      policy.onProposal(c80x24, c80x24);
      policy.onFrame(commit);

      // Then propose something different — should need full stability count
      for (var i = 0; i < StableFrameCommitPolicy.maxStabilityFrames; i++) {
        policy.onProposal(p100x30, c80x24);
        policy.onFrame(commit);
      }
      expect(commitCount, 1);
    });

    test('does not re-commit same size after stabilize', () {
      // Commit once
      for (var i = 0; i < StableFrameCommitPolicy.maxStabilityFrames; i++) {
        policy.onProposal(p100x30, c80x24);
        policy.onFrame(commit);
      }
      expect(commitCount, 1);

      // Keep proposing the same — should not commit again (skipUntilChange)
      for (var i = 0; i < 10; i++) {
        policy.onProposal(p100x30, p100x30); // now current == proposed
        policy.onFrame(commit);
      }
      expect(commitCount, 1);
    });

    test('safety valve after prolonged continuous change (8 frames)', () {
      final grids = [p100x30, p120x40, p140x50];
      for (var i = 0; i < StableFrameCommitPolicy.safetyValveFrames; i++) {
        final g = grids[i % grids.length];
        policy.onProposal(g, c80x24);
        policy.onFrame(commit);
      }
      // Safety valve should have fired
      expect(commitCount, 1);
    });

    test('settle timer commits a pending proposal after the frames go silent',
        () async {
      // Discrete resize (sidebar toggle): one proposal + one frame, then
      // silence. The stability gate never reaches maxStabilityFrames, so the
      // 150ms settle timer is what eventually commits.
      policy.onProposal(p100x30, c80x24);
      policy.onFrame(commit);
      expect(commitCount, 0); // stability=1, not yet converged

      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(commitCount, 1);
      expect(lastCols, 100);
      expect(lastRows, 30);
    });

    test('settle timer is cancelled when proposal matches current', () async {
      // A proposal equal to current arms nothing — after the settle window
      // there must be no commit.
      policy.onProposal(c80x24, c80x24);
      policy.onFrame(commit);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(commitCount, 0);
    });

    test('a fresh proposal resets the settle window', () async {
      policy.onProposal(p100x30, c80x24);
      policy.onFrame(commit);
      // New proposal before the timer fires cancels the old window.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      policy.onProposal(p120x40, c80x24);
      policy.onFrame(commit);
      // The remaining wait of the first window has elapsed, but the second
      // window restarted the clock, so still nothing committed yet.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(commitCount, 0);
      // After the second window fully elapses, the latest proposal commits.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(commitCount, 1);
      expect(lastCols, 120);
      expect(lastRows, 40);
    });

    test('flush commits immediately', () {
      policy.flush(p100x30, commit);
      expect(commitCount, 1);
      expect(lastCols, 100);
    });

    test('cancel resets state', () {
      policy.onProposal(p100x30, c80x24);
      policy.onFrame(commit);
      policy.cancel();

      // After cancel, need full stability count again
      for (var i = 0; i < StableFrameCommitPolicy.maxStabilityFrames; i++) {
        policy.onProposal(p100x30, c80x24);
        policy.onFrame(commit);
      }
      expect(commitCount, 1);
    });
  });

  group('ImmediateCommitPolicy', () {
    late ImmediateCommitPolicy policy;
    late int lastCols, lastRows, commitCount;

    void commit(int cols, int rows) {
      lastCols = cols;
      lastRows = rows;
      commitCount++;
    }

    setUp(() {
      policy = ImmediateCommitPolicy();
      lastCols = 0;
      lastRows = 0;
      commitCount = 0;
    });

    test('commits on first onFrame', () {
      policy.onProposal(p100x30, c80x24);
      policy.onFrame(commit);
      expect(commitCount, 1);
      expect(lastCols, 100);
    });

    test('skips when proposal matches current', () {
      policy.onProposal(c80x24, c80x24);
      policy.onFrame(commit);
      expect(commitCount, 0);
    });

    test('flush commits immediately', () {
      policy.flush(p120x40, commit);
      expect(commitCount, 1);
      expect(lastCols, 120);
    });
  });
}
