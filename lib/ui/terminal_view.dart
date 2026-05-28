import 'dart:async';
import 'dart:convert' show utf8;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/terminal_controller.dart';
import '../engine/terminal_engine.dart';
import '../input/ime_session.dart';
import '../input/key_input.dart';
import '../input/mouse_input.dart';
import '../input/paste.dart';
import '../input/term_mode.dart';
import '../render/cell_flags.dart';
import '../render/cell_metrics.dart';
import '../render/glyph_cache.dart';
import '../render/mirror_grid.dart';
import '../render/terminal_painter.dart';
import '../theme/terminal_theme.dart';
import 'preedit_overlay.dart';

/// Logical cell coordinate (row, column) exposed to callback parameters so
/// consumers can act on tap location without reaching into the painter.
class CellOffset {
  const CellOffset(this.row, this.column);
  final int row;
  final int column;
}

/// Pure render + input view over a [TerminalEngine].
///
/// Owns render state (font, metrics, glyph cache, bell controller, blink
/// timer), IME session, pointer/selection state, and the inline `_onKey`
/// hotkey switch. Does NOT own the engine, the PTY, the search bar widget,
/// drop handling, the right-click context menu, or URL launching — those
/// stay on `TerminalScreen` (or a future host) and are wired in via the
/// callback hooks below.
///
/// TODO(2W-3b): replace the inline `_onKey` with a Shortcuts/Actions split so
/// the view becomes fully pure (no hotkey logic), and add `shortcuts:` /
/// per-callback props for paste/copy/zoom/searchToggle.
class TerminalView extends StatefulWidget {
  const TerminalView(
    this.engine, {
    super.key,
    this.controller,
    this.theme = TerminalTheme.defaults,
    this.textStyle = const TerminalStyle(),
    this.padding,
    this.backgroundOpacity = 1.0,
    this.focusNode,
    this.autofocus = true,
    this.mouseCursor = SystemMouseCursors.text,
    this.readOnly = false,
    this.cursorBlinkInterval = const Duration(milliseconds: 530),
    this.bellDuration = Duration.zero,
    this.doubleClickThreshold = const Duration(milliseconds: 300),
    this.scrollMultiplier = 3,
    this.preeditBg = 0x282828,
    this.preeditFg = 0xD8D8D8,
    this.preeditUnderline = true,
    this.onTapDown,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onLinkActivate,
    this.onPaste,
    this.onCopy,
    this.onRestart,
    this.onSearchToggle,
    this.onBell,
  });

  final TerminalEngine engine;
  final TerminalController? controller;
  final TerminalTheme theme;
  final TerminalStyle textStyle;
  final EdgeInsets? padding;
  final double backgroundOpacity;
  final FocusNode? focusNode;
  final bool autofocus;
  final MouseCursor mouseCursor;
  final bool readOnly;

  /// Cursor blink half-period.
  final Duration cursorBlinkInterval;

  /// Bell flash duration (zero disables the visual bell).
  final Duration bellDuration;

  /// Double/triple-click window for word/line selection.
  final Duration doubleClickThreshold;

  /// Lines per discrete wheel notch when scrolling locally.
  final int scrollMultiplier;

  /// Preedit overlay colors / underline (packed RGB, alpha forced full).
  final int preeditBg;
  final int preeditFg;
  final bool preeditUnderline;

  // Callback hooks — TerminalScreen wires these (context menu, URL launch).
  // For 3a these are accepted as parameters but only the ones we explicitly
  // need pass through (secondary tap → context menu, link → launcher); the
  // rest land with 3b.
  final void Function(TapDownDetails, CellOffset)? onTapDown;
  final void Function(TapUpDetails, CellOffset)? onTapUp;
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;
  final void Function(String uri)? onLinkActivate;

  /// Ctrl+Shift+V: host-controlled paste (Clipboard read happens off-view).
  /// If null, the view falls back to its own Clipboard.getData('text/plain').
  final Future<void> Function()? onPaste;

  /// Ctrl+Shift+C: copy selection. If null, the view writes the engine
  /// selection text to the system clipboard.
  final void Function()? onCopy;

  /// Any key while the engine has exited / errored — restart hook. If null,
  /// the view ignores the keypress in that state.
  final void Function()? onRestart;

  /// Ctrl+Shift+F: search toggle. If null, the view ignores the combo.
  final void Function()? onSearchToggle;

  /// Bell event hook (fires in addition to the visual flash). If null, the
  /// view plays a system alert sound (current behavior).
  final void Function()? onBell;

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView>
    with SingleTickerProviderStateMixin {
  TerminalEngine get _engine => widget.engine;
  late TerminalController _controller;
  bool _ownsController = false;
  late FocusNode _focus;
  bool _ownsFocus = false;

  late AnimationController _bellCtrl;
  late double _fontSize;
  late TextStyle _style;
  late CellMetrics _metrics;
  late GlyphCache _glyphs;

  final ValueNotifier<bool> _blinkOn = ValueNotifier(true);
  Timer? _blinkTimer;

  String? _preedit;
  late final ImeSession _ime = ImeSession(
    onCommit: _writeCommittedText,
    onPreeditChanged: _onPreeditChanged,
  );
  Rect? _lastReportedCaretRect;

  int _cols = 0, _rows = 0;
  bool _lastFocused = false;
  int _pressedButton = 0;
  int _clickCount = 0;
  DateTime _lastClick = DateTime.fromMillisecondsSinceEpoch(0);
  bool _selecting = false;
  double _touchScrollAccum = 0;
  Timer? _flingTimer;
  MouseCursor _hoverCursor = MouseCursor.defer;

  StreamSubscription<void>? _bellSub;

  // The painter and UI helpers read the grid directly; the engine owns the
  // grid (single source of truth), and the view never paints before the
  // engine has been built (TerminalScreen gates this with its error/exit
  // overlay).
  MirrorGrid get _grid => _engine.gridForView;

  @visibleForTesting
  ImeSession get imeForTest => _ime;

  @visibleForTesting
  AnimationController get bellControllerForTest => _bellCtrl;

  @visibleForTesting
  void flashBellForTest() => _flashBell();

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? (TerminalController()..attach(_engine));
    _ownsController = widget.controller == null;
    _focus = widget.focusNode ?? FocusNode();
    _ownsFocus = widget.focusNode == null;
    _fontSize = widget.textStyle.size;
    _style = widget.textStyle.toTextStyle().copyWith(fontSize: _fontSize);
    _metrics = CellMetrics.measure(_style);
    _glyphs = GlyphCache(
      fontFamily: widget.textStyle.family,
      fontFamilyFallback: widget.textStyle.fallback,
      fontSize: _fontSize,
      cellWidth: _metrics.width,
      lineHeight: widget.textStyle.lineHeight,
    );
    _bellCtrl = AnimationController(
      vsync: this,
      duration: widget.bellDuration > Duration.zero
          ? widget.bellDuration
          : const Duration(milliseconds: 1),
    );
    _blinkTimer = Timer.periodic(widget.cursorBlinkInterval, (_) {
      _blinkOn.value = !_blinkOn.value;
    });
    _focus.addListener(_reportFocus);
    _focus.addListener(_handleImeFocusChange);
    _bellSub = _engine.bell.listen((_) => _flashBell());
  }

  @override
  void didUpdateWidget(covariant TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-attach controller / focus if the caller swapped them out. Rare; the
    // host typically creates both once.
    if (!identical(widget.controller, oldWidget.controller)) {
      if (_ownsController) _controller.dispose();
      _controller = widget.controller ?? (TerminalController()..attach(_engine));
      _ownsController = widget.controller == null;
    }
    if (!identical(widget.focusNode, oldWidget.focusNode)) {
      if (_ownsFocus) {
        _focus.removeListener(_reportFocus);
        _focus.removeListener(_handleImeFocusChange);
        _focus.dispose();
      }
      _focus = widget.focusNode ?? FocusNode();
      _ownsFocus = widget.focusNode == null;
      _focus.addListener(_reportFocus);
      _focus.addListener(_handleImeFocusChange);
    }
    if (oldWidget.bellDuration != widget.bellDuration) {
      _bellCtrl.duration = widget.bellDuration > Duration.zero
          ? widget.bellDuration
          : const Duration(milliseconds: 1);
    }
  }

  @override
  void dispose() {
    _flingTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkOn.dispose();
    _bellSub?.cancel();
    _focus.removeListener(_reportFocus);
    _focus.removeListener(_handleImeFocusChange);
    _ime.detach(notify: false);
    if (_ownsFocus) _focus.dispose();
    if (_ownsController) _controller.dispose();
    _bellCtrl.dispose();
    _glyphs.dispose();
    super.dispose();
  }

  void _flashBell() {
    if (widget.onBell != null) {
      widget.onBell!();
    } else {
      SystemSound.play(SystemSoundType.alert);
    }
    if (widget.bellDuration > Duration.zero) {
      _bellCtrl.value = 1.0;
      _bellCtrl.animateTo(0.0, duration: widget.bellDuration);
    }
  }

  void _setZoom(double next) {
    final clamped = next.clamp(6.0, 72.0);
    if (clamped == _fontSize) return;
    setState(() {
      _fontSize = clamped;
      _glyphs.dispose();
      _style = widget.textStyle.toTextStyle().copyWith(fontSize: _fontSize);
      _metrics = CellMetrics.measure(_style);
      _glyphs = GlyphCache(
        fontFamily: widget.textStyle.family,
        fontFamilyFallback: widget.textStyle.fallback,
        fontSize: _fontSize,
        cellWidth: _metrics.width,
        lineHeight: widget.textStyle.lineHeight,
      );
    });
  }

  // TODO(2W-3b): replace inline switch with Shortcuts/Actions + onPaste/onCopy
  // /onSearchToggle hooks so this method drops the search/copy/paste branches
  // and the view becomes pure (no _searchOpen knowledge, no Clipboard import).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (widget.readOnly) return KeyEventResult.ignored;
    if (widget.onRestart != null) {
      // Host can override the "any key restarts" semantic; if the host wants
      // it, it sets onRestart and gates the call. The view itself doesn't
      // know the engine status — by contract, TerminalScreen builds us only
      // while the engine is running, and the restart UI is overlaid on top.
    }
    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      widget.onSearchToggle?.call();
      return KeyEventResult.handled;
    }
    if (hw.isControlPressed && !hw.isShiftPressed && !hw.isAltPressed) {
      if (event.logicalKey == LogicalKeyboardKey.equal ||
          event.logicalKey == LogicalKeyboardKey.numpadAdd) {
        _setZoom(_fontSize + 1.0);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.minus ||
          event.logicalKey == LogicalKeyboardKey.numpadSubtract) {
        _setZoom(_fontSize - 1.0);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.digit0 ||
          event.logicalKey == LogicalKeyboardKey.numpad0) {
        _setZoom(widget.textStyle.size);
        return KeyEventResult.handled;
      }
    }
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyV) {
      if (widget.onPaste != null) {
        widget.onPaste!();
      } else {
        _paste();
      }
      return KeyEventResult.handled;
    }
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyC) {
      if (widget.onCopy != null) {
        widget.onCopy!();
      } else {
        final text = _controller.readSelectionText();
        if (text != null && text.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: text));
        }
      }
      return KeyEventResult.handled;
    }
    if (_ime.isAttached &&
        _ime.isComposing &&
        event.character != null &&
        event.character!.isNotEmpty &&
        !hw.isControlPressed &&
        !hw.isAltPressed &&
        !hw.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final bytes = encodeKey(
      event.logicalKey,
      event.character,
      shift: hw.isShiftPressed,
      alt: hw.isAltPressed,
      ctrl: hw.isControlPressed,
      meta: hw.isMetaPressed,
      modeFlags: _grid.modeFlags,
    );
    if (bytes == null) return KeyEventResult.ignored;
    _onTerminalInputStart();
    _engine.write(bytes);
    return KeyEventResult.handled;
  }

  /// Mirror alacritty event.rs:on_terminal_input_start.
  void _onTerminalInputStart() {
    final scrolledBack = _grid.displayOffset != 0;
    if (scrolledBack) {
      _engine.scrollToBottom();
    }
    if (_controller.selectionActive) {
      _controller.clearSelection();
      if (!scrolledBack) _refreshSelection();
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _onTerminalInputStart();
    _engine.write(pasteBytes(text, modeFlags: _grid.modeFlags));
  }

  void _reportFocus() {
    if (!focusReport(_grid.modeFlags)) {
      _lastFocused = _focus.hasFocus;
      return;
    }
    if (_focus.hasFocus == _lastFocused) return;
    _lastFocused = _focus.hasFocus;
    _engine.write(Uint8List.fromList(
        _focus.hasFocus ? [0x1b, 0x5b, 0x49] : [0x1b, 0x5b, 0x4f]));
  }

  void _handleImeFocusChange() {
    if (_focus.hasFocus) {
      _ime.attach();
    } else {
      _ime.detach();
      _lastReportedCaretRect = null;
    }
  }

  void _onPreeditChanged(String? p) {
    if (!mounted) return;
    if (p == _preedit) return;
    setState(() => _preedit = p);
  }

  void _writeCommittedText(String t) {
    if (t.isEmpty) return;
    _engine.write(Uint8List.fromList(utf8.encode(t)));
  }

  void _reportCaretRectToIme() {
    if (!_ime.isAttached) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;
    final localRect = Rect.fromLTWH(
      _grid.cursorCol * _metrics.width,
      _grid.cursorRow * _metrics.height,
      _metrics.width,
      _metrics.height,
    );
    final globalRect =
        renderBox.localToGlobal(localRect.topLeft) & localRect.size;
    if (globalRect == _lastReportedCaretRect) return;
    _lastReportedCaretRect = globalRect;
    _ime.setCaretRect(globalRect);
  }

  (int, int, bool) _cellAt(Offset local) {
    final col = (local.dx / _metrics.width).floor().clamp(0, _cols - 1);
    final row = (local.dy / _metrics.height).floor().clamp(0, _rows - 1);
    final rightHalf = (local.dx / _metrics.width) - col > 0.5;
    return (row, col, rightHalf);
  }

  void _updateHoverCursor(Offset local) {
    final (r, c, _) = _cellAt(local);
    final hyper = _grid.rows > r &&
        _grid.columns > c &&
        isHyperlink(_grid.flagsAt(r, c));
    final next = hyper ? SystemMouseCursors.click : widget.mouseCursor;
    if (next != _hoverCursor) setState(() => _hoverCursor = next);
  }

  void _refreshSelection() => _engine.refreshView();

  void _reportMouse(Offset local, int button, MouseAction action) {
    final col = (local.dx / _metrics.width).floor().clamp(0, _cols - 1) + 1;
    final row = (local.dy / _metrics.height).floor().clamp(0, _rows - 1) + 1;
    final hw = HardwareKeyboard.instance;
    final bytes = encodeMouse(button, action, col, row,
        shift: hw.isShiftPressed,
        alt: hw.isAltPressed,
        ctrl: hw.isControlPressed,
        modeFlags: _grid.modeFlags);
    if (bytes != null) _engine.write(bytes);
  }

  int _btn(int buttons) => (buttons & kSecondaryButton) != 0
      ? 2
      : (buttons & kMiddleMouseButton) != 0
          ? 1
          : 0;

  void _touchScrollBy(double dy) {
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
    } else if (_grid.modeFlags & kModeAltScreen != 0) {
      final arrow = up ? [0x1b, 0x4f, 0x41] : [0x1b, 0x4f, 0x42];
      for (var i = 0; i < n; i++) {
        _engine.write(Uint8List.fromList(arrow));
      }
    } else {
      _engine.scrollLines(up ? n : -n);
    }
  }

  void _stopFling() {
    _flingTimer?.cancel();
    _flingTimer = null;
  }

  void _ensureSizing(int cols, int rows) {
    if (cols != _cols || rows != _rows) {
      _cols = cols;
      _rows = rows;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = (constraints.maxWidth / _metrics.width).floor().clamp(1, 1000);
        final rows = (constraints.maxHeight / _metrics.height).floor().clamp(1, 1000);
        _ensureSizing(cols, rows);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _reportCaretRectToIme());
        Widget tree = Focus(
          focusNode: _focus,
          autofocus: widget.autofocus,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerSignal: _onPointerSignal,
            onPointerPanZoomStart: (_) {
              _stopFling();
              _touchScrollAccum = 0;
            },
            onPointerPanZoomUpdate: (e) => _touchScrollBy(e.localPanDelta.dy),
            child: GestureDetector(
              supportedDevices: const {PointerDeviceKind.touch},
              behavior: HitTestBehavior.translucent,
              onTapDown: (_) => _stopFling(),
              onTap: _onTouchTap,
              onVerticalDragStart: (_) {
                _stopFling();
                _touchScrollAccum = 0;
              },
              onVerticalDragUpdate: (e) => _touchScrollBy(e.delta.dy),
              onVerticalDragEnd: _onVerticalDragEnd,
              onLongPressStart: _onLongPressStart,
              onLongPressMoveUpdate: _onLongPressMoveUpdate,
              onLongPressEnd: _onLongPressEnd,
              child: Stack(
                children: [
                  MouseRegion(
                    cursor: _hoverCursor,
                    onHover: (e) => _updateHoverCursor(e.localPosition),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: TerminalPainter(
                        grid: _grid,
                        glyphs: _glyphs,
                        cellWidth: _metrics.width,
                        cellHeight: _metrics.height,
                        blinkOn: _blinkOn,
                        selectionColor:
                            0x55000000 | (widget.theme.selection & 0xFFFFFF),
                        searchColors: SearchColors(
                          matchBg: widget.theme.searchMatch.bg,
                          matchFg: widget.theme.searchMatch.fg,
                          focusedBg: widget.theme.searchFocused.bg,
                          focusedFg: widget.theme.searchFocused.fg,
                        ),
                        hintColors: HintColors(
                          bg: widget.theme.hintStart.bg,
                          fg: widget.theme.hintStart.fg,
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: FadeTransition(
                      opacity: _bellCtrl,
                      child: ColoredBox(
                          color: Color(0xFF000000 | widget.theme.bellOverlay)),
                    ),
                  ),
                  if (_preedit != null && _preedit!.isNotEmpty)
                    PreeditOverlay(
                      text: _preedit!,
                      cursorRect: Rect.fromLTWH(
                        _grid.cursorCol * _metrics.width,
                        _grid.cursorRow * _metrics.height,
                        _metrics.width,
                        _metrics.height,
                      ),
                      bg: widget.preeditBg,
                      fg: widget.preeditFg,
                      underline: widget.preeditUnderline,
                      textStyle: _style,
                    ),
                ],
              ),
            ),
          ),
        );
        if (widget.padding != null) {
          tree = Padding(padding: widget.padding!, child: tree);
        }
        return tree;
      },
    );
  }

  // ---- pointer handlers (mouse) ------------------------------------------

  void _onPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    _focus.requestFocus();
    final hw = HardwareKeyboard.instance;
    // Ctrl + left-click on a hyperlink cell → host launches URI.
    if (hw.isControlPressed && e.buttons & kPrimaryButton != 0) {
      final (r, c, _) = _cellAt(e.localPosition);
      final uri = _engine.hyperlinkAt(r, c);
      if (uri != null) {
        if (widget.onLinkActivate != null) {
          widget.onLinkActivate!(uri);
        }
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
      _controller.selectionStart(r, c, rh, _clickCount - 1);
      _selecting = true;
      _refreshSelection();
      return;
    }
    if (!anyMouse(_grid.modeFlags) &&
        e.buttons & kMiddleMouseButton != 0 &&
        _controller.primary.isNotEmpty) {
      _onTerminalInputStart();
      _engine.write(
          pasteBytes(_controller.primary, modeFlags: _grid.modeFlags));
      return;
    }
    if (e.buttons & kSecondaryButton != 0 && !hw.isShiftPressed) {
      final (r, c, _) = _cellAt(e.localPosition);
      if (widget.onSecondaryTapDown != null) {
        widget.onSecondaryTapDown!(
          TapDownDetails(
            globalPosition: e.position,
            localPosition: e.localPosition,
            kind: e.kind,
          ),
          CellOffset(r, c),
        );
      }
      if (widget.onSecondaryTapUp != null) {
        widget.onSecondaryTapUp!(
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
    _pressedButton = _btn(e.buttons);
    _reportMouse(e.localPosition, _pressedButton, MouseAction.down);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
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

  void _onPointerUp(PointerUpEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if (_selecting) {
      _selecting = false;
      _controller.capturePrimary();
      return;
    }
    _reportMouse(e.localPosition, _pressedButton, MouseAction.up);
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final up = e.scrollDelta.dy < 0;
    if (anyMouse(_grid.modeFlags)) {
      _reportMouse(
          e.localPosition, 0, up ? MouseAction.scrollUp : MouseAction.scrollDown);
      return;
    }
    if (_grid.modeFlags & kModeAltScreen != 0) {
      final arrow = up ? [0x1b, 0x4f, 0x41] : [0x1b, 0x4f, 0x42];
      for (var i = 0; i < 3; i++) {
        _engine.write(Uint8List.fromList(arrow));
      }
      return;
    }
    _controller.scrollLines(
        up ? widget.scrollMultiplier : -widget.scrollMultiplier);
  }

  // ---- gesture handlers (touch) ------------------------------------------

  void _onTouchTap() {
    _focus.requestFocus();
    if (_controller.selectionActive) {
      _controller.clearSelection();
      _refreshSelection();
    }
  }

  void _onVerticalDragEnd(DragEndDetails e) {
    var v = e.primaryVelocity ?? 0;
    if (v.abs() < 200) return;
    _flingTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      v *= 0.92;
      if (v.abs() < 40) {
        _stopFling();
        return;
      }
      _touchScrollBy(v * 0.016);
    });
  }

  void _onLongPressStart(LongPressStartDetails e) {
    _stopFling();
    _focus.requestFocus();
    final (r, c, rh) = _cellAt(e.localPosition);
    _controller.selectionStart(r, c, rh, 0);
    _selecting = true;
    _refreshSelection();
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails e) {
    final (r, c, rh) = _cellAt(e.localPosition);
    _controller.selectionUpdate(r, c, rh);
    _refreshSelection();
  }

  void _onLongPressEnd(LongPressEndDetails e) {
    _selecting = false;
    _controller.capturePrimary();
  }
}
