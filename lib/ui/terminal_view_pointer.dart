part of 'terminal_view.dart';

/// Pointer, scroll, fling, and selection hit-testing for [TerminalViewState].
extension _TerminalViewPointer on TerminalViewState {
  (int, int, bool) _cellAt(Offset local) {
    // Clamp to the COMMITTED grid (`_grid`, the engine's actual size), not the
    // proposed `_cols/_rows`. Under lock-step the proposed grid can lead the
    // engine during a drag; clamping to it would let selection/hit-tests address
    // columns the engine hasn't allocated yet (ghost cells).
    final maxCol = _grid.columns > 0 ? _grid.columns - 1 : 0;
    final maxRow = _grid.rows > 0 ? _grid.rows - 1 : 0;
    final col = (local.dx / _metrics.width).floor().clamp(0, maxCol);
    // The painter shifts content down by `scrollFraction * cellHeight` for
    // sub-cell scroll; undo it here so hit-testing (selection, hover) lands on
    // the row the user actually sees rather than the unscrolled grid row.
    final yRows = local.dy / _metrics.height - _grid.scrollFraction;
    final row = yRows.floor().clamp(0, maxRow);
    final rightHalf = (local.dx / _metrics.width) - col > 0.5;
    return (row, col, rightHalf);
  }

  void _updateHoverCursor(Offset local) {
    final (r, c, _) = _cellAt(local);
    final inBounds = _grid.rows > r && _grid.columns > c;
    final isLink = inBounds &&
        (isHyperlink(_grid.flagsAt(r, c)) || _linkOverlay.isLinkCell(r, c));
    final next = hoverCursorFor(
      hyperlink: isLink,
      modeFlags: _grid.modeFlags,
      base: widget.mouseCursor,
    );
    if (next != _hoverCursor) {
      // ignore: invalid_use_of_protected_member
      setState(() => _hoverCursor = next);
    }
  }

  void _refreshSelection() => _engine.refreshView();

  void _reportMouse(Offset local, int button, MouseAction action) {
    // Report against the committed engine grid (see [_cellAt]) so a drag that
    // outpaces the PTY never sends out-of-range mouse coordinates to the program.
    final maxCol = _grid.columns > 0 ? _grid.columns - 1 : 0;
    final maxRow = _grid.rows > 0 ? _grid.rows - 1 : 0;
    final col = (local.dx / _metrics.width).floor().clamp(0, maxCol) + 1;
    final row = (local.dy / _metrics.height).floor().clamp(0, maxRow) + 1;
    final hw = HardwareKeyboard.instance;
    final bytes = encodeMouse(button, action, col, row,
        shift: hw.isShiftPressed,
        alt: hw.isAltPressed,
        ctrl: hw.isControlPressed,
        modeFlags: _grid.modeFlags);
    if (bytes != null) _writeToEngine(bytes);
  }

  int _btn(int buttons) => (buttons & kSecondaryButton) != 0
      ? 2
      : (buttons & kMiddleMouseButton) != 0
          ? 1
          : 0;

  void _touchScrollBy(double dy) {
    // Mouse-report and alt-screen apps consume scroll as discrete events (wheel
    // report / arrow keys), so quantize to whole lines for those. The normal
    // scrollback path scrolls with sub-cell pixel precision.
    if (anyMouse(_grid.modeFlags) || _grid.modeFlags & kModeAltScreen != 0) {
      _touchScrollAccum += dy;
      final lines = _touchScrollAccum ~/ _metrics.height;
      if (lines == 0) return;
      _touchScrollAccum -= lines * _metrics.height;
      final up = lines > 0;
      final n = lines.abs();
      if (anyMouse(_grid.modeFlags)) {
        for (var i = 0; i < n; i++) {
          _reportMouse(Offset.zero, 0,
              up ? MouseAction.scrollUp : MouseAction.scrollDown);
        }
      } else {
        final arrow = up ? [0x1b, 0x4f, 0x41] : [0x1b, 0x4f, 0x42];
        for (var i = 0; i < n; i++) {
          _writeToEngine(Uint8List.fromList(arrow));
        }
      }
      return;
    }
    // Dragging the finger down (dy > 0) reveals older content → scroll up into
    // history, which is the engine's positive pixel delta.
    _engine.scrollByPixels(dy);
  }

  void _stopFling() {
    _flingTicker?.dispose();
    _flingTicker = null;
    _flingVelocity = 0;
  }

  /// Start a kinetic fling from a gesture-end [velocityPxPerSec] (positive =
  /// downward drag = scrolling up into history), decaying on a vsync Ticker with
  /// [decel] (GNOME's per-ms multiplier: 0.998 touch, 0.997 touchpad).
  void _startFling(double velocityPxPerSec,
      {double decel = _kFlingDecelerationTouch}) {
    _stopFling();
    if (velocityPxPerSec.abs() < _kFlingStartVelocity) return;
    // Don't kinetic-scroll into mouse-report / alt-screen apps.
    if (anyMouse(_grid.modeFlags) || _grid.modeFlags & kModeAltScreen != 0) {
      return;
    }
    _flingVelocity = velocityPxPerSec;
    _flingDecel = decel;
    _flingLastTick = null;
    _flingTicker = createTicker(_onFlingTick)..start();
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
    // GNOME swipeTracker: velocity *= deceleration^dt_ms.
    _flingVelocity *= math.pow(_flingDecel, dtMs);
    if (_flingVelocity.abs() < _kFlingStopVelocity) {
      _stopFling();
      return;
    }
    _engine.scrollByPixels(_flingVelocity * dtMs / 1000.0);
  }

  /// Record a trackpad pan sample and trim to the trailing velocity window.
  void _recordPanSample(Duration t, double dy) {
    _panSamples.add((t, dy));
    final cutoff = t - const Duration(milliseconds: _kVelocityWindowMs);
    while (_panSamples.length > 1 && _panSamples.first.$1 < cutoff) {
      _panSamples.removeAt(0);
    }
  }

  /// Release velocity (px/s) over the trailing window, matching swipeTracker's
  /// `calculateVelocity`: total delta after the first sample / elapsed period.
  double _panReleaseVelocity() {
    if (_panSamples.length < 2) return 0;
    final periodMs =
        (_panSamples.last.$1 - _panSamples.first.$1).inMicroseconds / 1000.0;
    if (periodMs <= 0) return 0;
    var total = 0.0;
    for (var i = 1; i < _panSamples.length; i++) {
      total += _panSamples[i].$2;
    }
    return total / periodMs * 1000.0;
  }

  void _syncViewportToHost(int cols, int rows) {
    if (cols <= 0 || rows <= 0) return;
    _pendingResizeCols = cols;
    _pendingResizeRows = rows;
    // Throttle window already open: just record the latest size; the trailing
    // flush will apply it. (Avoids per-frame reflow during a drag.)
    if (_resizeThrottle != null) return;
    // Leading edge: apply the first change immediately. Runs during
    // build/layout, so defer the actual resize to the post-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyViewportResize());
    _resizeThrottle = Timer(TerminalViewState._resizeWindow, () {
      _resizeThrottle = null;
      // Trailing flush: apply the latest size seen during the window. A no-op
      // (same size) is coalesced away by the engine's same-size guard.
      _applyViewportResize();
    });
  }

  void _applyViewportResize() {
    if (!mounted) return;
    final cols = _pendingResizeCols;
    final rows = _pendingResizeRows;
    if (cols <= 0 || rows <= 0) return;
    _engine.resize(columns: cols, rows: rows);
    widget.onViewportResize?.call(cols, rows);
  }

  void __pointerEnsureSizing(int cols, int rows) {
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    // Mirror alacritty display/mod.rs: cell grid changes (first layout, font
    // zoom, window resize) → term.resize(). First layout must notify the host
    // too — otherwise PTY stays at whatever size the host guessed before the
    // view mounted (e.g. 80×24) while the painter uses a taller grid.
    _syncViewportToHost(cols, rows);
  }

  void __pointerOnDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    _focus.requestFocus();
    _linkActivatedOnDown = false;
    final hw = HardwareKeyboard.instance;
    // Left-click on a link cell → host launches URI. Always on Ctrl/Cmd-click;
    // also on a plain click when [primaryTapActivatesLink] is set (Shift still
    // forces selection). Non-link cells fall through to normal handling, so
    // they keep selecting / reporting to the program.
    final wantLinkActivate = e.buttons & kPrimaryButton != 0 &&
        (hw.isControlPressed ||
            hw.isMetaPressed ||
            (widget.primaryTapActivatesLink && !hw.isShiftPressed));
    if (wantLinkActivate) {
      final (r, c, _) = _cellAt(e.localPosition);
      final uri = _engine.hyperlinkAt(r, c);
      if (uri != null) {
        _linkActivatedOnDown = true;
        widget.onLinkActivate?.call(uri);
        return;
      }
      final payload = _payloadAt(r, c);
      if (payload != null) {
        _linkActivatedOnDown = true;
        widget.onLinkActivate?.call(payload);
        return;
      }
    }
    final localSelect = !anyMouse(_grid.modeFlags) || hw.isShiftPressed;
    if (localSelect && e.buttons & kPrimaryButton != 0) {
      final now = DateTime.now();
      _clickCount = (now.difference(_lastClick) < widget.doubleClickThreshold)
          ? (_clickCount % 3) + 1
          : 1;
      _lastClick = now;
      final (r, c, rh) = _cellAt(e.localPosition);
      if (widget.onTapDown != null) {
        widget.onTapDown!(
          TapDownDetails(
            globalPosition: e.position,
            localPosition: e.localPosition,
            kind: e.kind,
          ),
          CellOffset(r, c),
        );
      }
      _controller.selectionStart(r, c, rh, _clickCount - 1);
      _selecting = true;
      _refreshSelection();
      return;
    }
    if (!anyMouse(_grid.modeFlags) &&
        e.buttons & kMiddleMouseButton != 0 &&
        _controller.primary.isNotEmpty) {
      _onTerminalInputStart();
      _writeToEngine(
          pasteBytes(_controller.primary, modeFlags: _grid.modeFlags));
      return;
    }
    if (e.buttons & kSecondaryButton != 0 && !hw.isShiftPressed) {
      // Track this as a pending secondary tap so [_onPointerUp] can fire
      // `onSecondaryTapUp` on real release — fixes the press-time double-fire
      // caught in review. `onSecondaryTapDown` still fires immediately on
      // press; `onSecondaryTapUp` waits for the release event.
      final (r, c, _) = _cellAt(e.localPosition);
      _secondaryDownCell = CellOffset(r, c);
      _secondaryDownLocal = e.localPosition;
      _secondaryDownGlobal = e.position;
      if (widget.onSecondaryTapDown != null) {
        widget.onSecondaryTapDown!(
          TapDownDetails(
            globalPosition: e.position,
            localPosition: e.localPosition,
            kind: e.kind,
          ),
          _secondaryDownCell!,
        );
      }
      return;
    }
    _pressedButton = _btn(e.buttons);
    _reportMouse(e.localPosition, _pressedButton, MouseAction.down);
  }

  void __pointerOnMove(PointerMoveEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    // A link-activating press is in flight; don't report drag to the program.
    if (_linkActivatedOnDown) return;
    if (_selecting) {
      final (r, c, rh) = _cellAt(e.localPosition);
      _controller.selectionUpdate(r, c, rh);
      _refreshSelection();
      return;
    }
    if (e.buttons == 0) {
      if ((_grid.modeFlags & kModeMouseMotion) == 0) return;
      _reportMouse(e.localPosition, 3, MouseAction.move);
    } else {
      _reportMouse(e.localPosition, _btn(e.buttons), MouseAction.move);
    }
  }

  void __pointerOnUp(PointerUpEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    // The press activated a link and was not reported to the program; swallow
    // the release too so the program doesn't see a phantom click.
    if (_linkActivatedOnDown) {
      _linkActivatedOnDown = false;
      return;
    }
    // Drain a pending secondary press. Use the down-time cell so the
    // callback reports where the right click started, matching the
    // GestureDetector.onSecondaryTapUp convention.
    if (_secondaryDownCell != null) {
      final downCell = _secondaryDownCell!;
      final downLocal = _secondaryDownLocal ?? e.localPosition;
      final downGlobal = _secondaryDownGlobal ?? e.position;
      _secondaryDownCell = null;
      _secondaryDownLocal = null;
      _secondaryDownGlobal = null;
      if (widget.onSecondaryTapUp != null) {
        widget.onSecondaryTapUp!(
          TapUpDetails(
            globalPosition: downGlobal,
            localPosition: downLocal,
            kind: e.kind,
          ),
          downCell,
        );
      }
      return;
    }
    if (_selecting) {
      _selecting = false;
      _controller.capturePrimary();
      if (widget.onTapUp != null) {
        final (r, c, _) = _cellAt(e.localPosition);
        widget.onTapUp!(
          TapUpDetails(
            globalPosition: e.position,
            localPosition: e.localPosition,
            kind: e.kind,
          ),
          CellOffset(r, c),
        );
      }
      return;
    }
    _reportMouse(e.localPosition, _pressedButton, MouseAction.up);
  }

  void __pointerOnSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    // A live fling shouldn't fight a fresh wheel/trackpad gesture.
    _stopFling();
    final up = e.scrollDelta.dy < 0;
    if (anyMouse(_grid.modeFlags)) {
      _reportMouse(
          e.localPosition, 0, up ? MouseAction.scrollUp : MouseAction.scrollDown);
      return;
    }
    if (_grid.modeFlags & kModeAltScreen != 0) {
      final arrow = up ? [0x1b, 0x4f, 0x41] : [0x1b, 0x4f, 0x42];
      for (var i = 0; i < 3; i++) {
        _writeToEngine(Uint8List.fromList(arrow));
      }
      return;
    }
    // Smooth, sub-cell scrollback. We intentionally track scrollDelta.dy (the
    // platform's already-scaled scroll distance, honoring the user's system
    // scroll-speed setting) rather than a fixed line count — so per-notch travel
    // varies with the OS, unlike alacritty's fixed `scrolling.multiplier` lines.
    // scrollMultiplier scales that delta with its historical default (3) as the
    // neutral 1.0×. down (dy > 0) scrolls toward the live edge = negative engine
    // delta.
    _engine.scrollByPixels(-e.scrollDelta.dy * widget.scrollMultiplier / 3.0);
  }

  void __pointerOnTouchTap() {
    _focus.requestFocus();
    if (_controller.selectionActive) {
      _controller.clearSelection();
      _refreshSelection();
    }
  }

  void __pointerOnVerticalDragEnd(DragEndDetails e) {
    // primaryVelocity is Flutter's smoothed gesture velocity (px/s, downward
    // positive) — already a multi-sample estimate, so it maps straight onto the
    // engine's positive-into-history pixel scroll.
    _startFling(e.primaryVelocity ?? 0);
  }

  void __pointerOnLongPressStart(LongPressStartDetails e) {
    _stopFling();
    _focus.requestFocus();
    final (r, c, rh) = _cellAt(e.localPosition);
    _controller.selectionStart(r, c, rh, 0);
    _selecting = true;
    _refreshSelection();
  }

  void __pointerOnLongPressMoveUpdate(LongPressMoveUpdateDetails e) {
    final (r, c, rh) = _cellAt(e.localPosition);
    _controller.selectionUpdate(r, c, rh);
    _refreshSelection();
  }

  void __pointerOnLongPressEnd(LongPressEndDetails e) {
    _selecting = false;
    _controller.capturePrimary();
  }
}
