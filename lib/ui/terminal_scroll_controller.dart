import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/program_scroll_encoder.dart';
import 'package:flutter_alacritty/input/scroll_accumulator.dart';
import 'package:flutter_alacritty/input/scroll_destination.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

/// Owns scroll gesture state for [TerminalView]: pixel accumulator, routing,
/// per-tick flush to either local history scroll or batched PTY writes.
class TerminalScrollController {
  TerminalScrollController({
    required this.engine,
    required double cellHeight,
    required int scrollMultiplier,
  })  : _accumulator = ScrollAccumulator(cellHeight: cellHeight),
        _multiplier = scrollMultiplier / 3.0;

  final TerminalEngine engine;
  ScrollAccumulator _accumulator;
  final double _multiplier;

  bool _historyScheduled = false;
  double _pendingHistoryPx = 0;
  int _wheelCol = 1;
  int _wheelRow = 1;

  Ticker? _flingTicker;
  double _flingVelocity = 0;
  double _flingDecel = 0.998;
  Duration? _flingLastTick;
  bool _flingShiftHeld = false;

  /// Rebuilds the pixel accumulator when cell metrics change (font zoom).
  /// Sub-line [ScrollAccumulator.remainderPx] is intentionally discarded.
  void updateCellHeight(double cellHeight) {
    _cancelPendingProgram();
    _accumulator = ScrollAccumulator(cellHeight: cellHeight);
  }

  void _cancelPendingProgram() {
    _pendingProgramBytes.clear();
    _programScheduled = false;
  }

  void dispose() => stopFling();

  void onGestureStart() {
    _accumulator.reset();
    stopFling();
  }

  void setWheelCell({required int col, required int row}) {
    _wheelCol = col;
    _wheelRow = row;
  }

  void onWheelSignal({required double dyPx, required bool shiftHeld}) {
    _ingestDy(dyPx, shiftHeld: shiftHeld, wheelStyle: true);
  }

  void onPanDelta({required double dyPx, required bool shiftHeld}) {
    _ingestDy(dyPx, shiftHeld: shiftHeld, wheelStyle: false);
  }

  void _ingestDy(
    double dyPx, {
    required bool shiftHeld,
    required bool wheelStyle,
  }) {
    final modeFlags = engine.grid.modeFlags;
    final dest = scrollDestination(modeFlags: modeFlags, shiftHeld: shiftHeld);

    // Scrollback: sub-cell pixel scroll (local engine path).
    // Wheel ([PointerScrollEvent.scrollDelta]) and drag/pan use opposite signs —
    // same split as the pre-controller [terminal_view_pointer] paths.
    if (dest == ScrollDestination.history) {
      final scaled = dyPx * _multiplier;
      _scheduleHistoryPixels(wheelStyle ? -scaled : scaled);
      return;
    }

    // TUI / mouse-report: accumulate pixels → whole-line PTY events.
    // Wheel ([PointerScrollEvent.scrollDelta]) and drag/pan use opposite dy
    // signs for the same user intent — same split as pre-controller pointer code.
    final programMultiplier = anyMouse(modeFlags) ? 1.0 : _multiplier;
    final signedDy = wheelStyle ? -dyPx : dyPx;
    final signedLines = _accumulator.ingest(
      dyPx: signedDy,
      multiplier: programMultiplier,
    );
    if (signedLines == 0) return;

    final up = signedLines > 0;
    final n = signedLines.abs();
    final bytes = anyMouse(modeFlags)
        ? encodeMouseWheelLines(
            lines: n,
            up: up,
            col: _wheelCol,
            row: _wheelRow,
            modeFlags: modeFlags,
          )
        : encodeAlternateScrollLines(lines: n, up: up);
    if (bytes.isNotEmpty) _scheduleProgramWrite(bytes);
  }

  final BytesBuilder _pendingProgramBytes = BytesBuilder(copy: false);
  bool _programScheduled = false;

  void _scheduleProgramWrite(Uint8List bytes) {
    _pendingProgramBytes.add(bytes);
    if (_programScheduled) return;
    _programScheduled = true;
    engine.scheduleTask(_flushProgram);
  }

  void _flushProgram() {
    _programScheduled = false;
    if (_pendingProgramBytes.isEmpty) return;
    engine.scheduleWrite(_pendingProgramBytes.toBytes());
    _pendingProgramBytes.clear();
  }

  void _scheduleHistoryPixels(double deltaPx) {
    if (deltaPx == 0) return;
    _pendingHistoryPx += deltaPx;
    if (_historyScheduled) return;
    _historyScheduled = true;
    engine.scheduleTask(_flushHistory);
  }

  void _flushHistory() {
    _historyScheduled = false;
    final px = _pendingHistoryPx;
    _pendingHistoryPx = 0;
    if (px != 0) engine.scrollByPixels(px);
  }

  void startFling({
    required double velocityPxPerSec,
    required double deceleration,
    required bool shiftHeld,
    required Ticker Function(TickerCallback) createTicker,
  }) {
    stopFling();
    if (velocityPxPerSec.abs() < 80) return;
    _flingVelocity = velocityPxPerSec;
    _flingDecel = deceleration;
    _flingShiftHeld = shiftHeld;
    _flingLastTick = null;
    _flingTicker = createTicker(_onFlingTick)..start();
  }

  void stopFling() {
    _flingTicker?.dispose();
    _flingTicker = null;
    _flingVelocity = 0;
    _flingLastTick = null;
  }

  void _onFlingTick(Duration elapsed) {
    final last = _flingLastTick;
    if (last == null) {
      _flingLastTick = elapsed;
      return;
    }
    final dtMs = (elapsed - last).inMicroseconds / 1000.0;
    _flingLastTick = elapsed;
    if (dtMs <= 0) return;
    _flingVelocity *= math.pow(_flingDecel, dtMs).toDouble();
    if (_flingVelocity.abs() < 18) {
      stopFling();
      return;
    }
    onPanDelta(dyPx: _flingVelocity * dtMs / 1000.0, shiftHeld: _flingShiftHeld);
  }

  @visibleForTesting
  bool get isFlinging => _flingTicker != null;
}
