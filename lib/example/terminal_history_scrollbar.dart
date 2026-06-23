import 'package:flutter/material.dart';

import '../controller/terminal_controller.dart';
import '../engine/terminal_engine.dart';
import '../input/term_mode.dart';

/// Vertical scrollbar for [ExampleTerminalApp] only (not part of the library API).
///
/// Maps thumb position on a **viewport-sized** track to the engine's
/// `display_offset` (0 = live bottom). Unlike a `SingleChildScrollView` sized
/// to `history × cellHeight` (millions of pixels, which trips Flutter's scroll
/// limits), this keeps the track at the terminal height and maps proportionally.
class TerminalHistoryScrollbar extends StatefulWidget {
  const TerminalHistoryScrollbar({
    required this.engine,
    required this.controller,
    required this.historyLines,
    required this.viewportRows,
    required this.cellHeight,
    super.key,
  });

  final TerminalEngine engine;
  final TerminalController controller;
  final int historyLines;
  final int viewportRows;
  final double cellHeight;

  @override
  State<TerminalHistoryScrollbar> createState() =>
      _TerminalHistoryScrollbarState();
}

class _TerminalHistoryScrollbarState extends State<TerminalHistoryScrollbar> {
  bool _dragging = false;
  double _lastScrollPos = 0;
  int _lastModeFlags = 0;

  @override
  void initState() {
    super.initState();
    final grid = widget.engine.grid;
    _lastScrollPos = grid.displayOffset + grid.scrollFraction;
    _lastModeFlags = grid.modeFlags;
    widget.engine.repaint.addListener(_onGridChanged);
  }

  @override
  void didUpdateWidget(covariant TerminalHistoryScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      oldWidget.engine.repaint.removeListener(_onGridChanged);
      widget.engine.repaint.addListener(_onGridChanged);
      final grid = widget.engine.grid;
      _lastScrollPos = grid.displayOffset + grid.scrollFraction;
      _lastModeFlags = grid.modeFlags;
    }
  }

  @override
  void dispose() {
    widget.engine.repaint.removeListener(_onGridChanged);
    super.dispose();
  }

  void _onGridChanged() {
    if (!mounted || _dragging) return;
    final grid = widget.engine.grid;
    final scrollPos = grid.displayOffset + grid.scrollFraction;
    final modeFlags = grid.modeFlags;
    if (scrollPos == _lastScrollPos && modeFlags == _lastModeFlags) return;
    _lastScrollPos = scrollPos;
    _lastModeFlags = modeFlags;
    setState(() {});
  }

  int get _historyCap => widget.historyLines.clamp(0, 1 << 20);

  /// Lines the viewport can move through when scrollback is full.
  int get _trackLines {
    final viewport = widget.viewportRows.clamp(1, 10000);
    return (_historyCap - viewport).clamp(0, _historyCap);
  }

  double _positionFraction() {
    final track = _trackLines;
    if (track <= 0) return 1.0;
    final grid = widget.engine.grid;
    final pos = (grid.displayOffset + grid.scrollFraction) / track;
    // 1.0 = live bottom (thumb at bottom), 0.0 = top of history.
    return (1.0 - pos).clamp(0.0, 1.0);
  }

  void _scrollToFraction(double fraction) {
    final track = _trackLines;
    if (track <= 0) return;
    final grid = widget.engine.grid;
    final targetLines = ((1.0 - fraction.clamp(0.0, 1.0)) * track).toDouble();
    final current = grid.displayOffset + grid.scrollFraction;
    final delta = targetLines - current;
    if (delta.abs() < 0.001) return;
    if (delta.abs() >= 1.0) {
      widget.controller.scrollLines(delta.round());
    } else {
      widget.engine.scrollByPixels(delta * widget.cellHeight);
    }
  }

  void _onTrackPointer(double localDy, double trackHeight) {
    if (trackHeight <= 0) return;
    final fraction = (1.0 - (localDy / trackHeight)).clamp(0.0, 1.0);
    _scrollToFraction(fraction);
  }

  ({double top, double height}) _thumbGeometry(double trackHeight) {
    final track = _trackLines;
    if (track <= 0) {
      return (top: 0, height: trackHeight);
    }
    final viewport = widget.viewportRows.clamp(1, track + 1);
    final thumbFrac =
        (viewport / (track + viewport)).clamp(0.08, 1.0);
    final thumbH = trackHeight * thumbFrac;
    final usable = trackHeight - thumbH;
    final top = _positionFraction() * usable;
    return (top: top, height: thumbH);
  }

  @override
  Widget build(BuildContext context) {
    final grid = widget.engine.grid;
    if (grid.modeFlags & kModeAltScreen != 0) {
      return const SizedBox(width: 0);
    }

    final trackLines = _trackLines;
    if (trackLines <= 0) {
      return const SizedBox(width: 0);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        if (trackHeight <= 0) return const SizedBox(width: 0);

        final thumb = _thumbGeometry(trackHeight);
        final theme = ScrollbarTheme.of(context);
        final thickness = theme.thickness?.resolve({}) ?? 8.0;
        final radius = theme.radius ?? const Radius.circular(4);
        final trackColor = theme.trackColor?.resolve({}) ??
            const Color(0x33FFFFFF);
        final thumbColor = theme.thumbColor?.resolve({}) ??
            const Color(0x99FFFFFF);

        return SizedBox(
          width: 12,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => _dragging = true,
            onVerticalDragEnd: (_) => _dragging = false,
            onVerticalDragCancel: () => _dragging = false,
            onVerticalDragUpdate: (d) =>
                _onTrackPointer(d.localPosition.dy, trackHeight),
            onTapDown: (d) =>
                _onTrackPointer(d.localPosition.dy, trackHeight),
            child: CustomPaint(
              painter: _ScrollbarPainter(
                thumbTop: thumb.top,
                thumbHeight: thumb.height,
                trackWidth: thickness,
                radius: radius,
                trackColor: trackColor,
                thumbColor: thumbColor,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}

class _ScrollbarPainter extends CustomPainter {
  _ScrollbarPainter({
    required this.thumbTop,
    required this.thumbHeight,
    required this.trackWidth,
    required this.radius,
    required this.trackColor,
    required this.thumbColor,
  });

  final double thumbTop;
  final double thumbHeight;
  final double trackWidth;
  final Radius radius;
  final Color trackColor;
  final Color thumbColor;

  @override
  void paint(Canvas canvas, Size size) {
    final trackR = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width - trackWidth - 2,
        0,
        trackWidth,
        size.height,
      ),
      radius,
    );
    canvas.drawRRect(trackR, Paint()..color = trackColor);

    final thumbR = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width - trackWidth - 2,
        thumbTop,
        trackWidth,
        thumbHeight.clamp(0, size.height),
      ),
      radius,
    );
    canvas.drawRRect(thumbR, Paint()..color = thumbColor);
  }

  @override
  bool shouldRepaint(covariant _ScrollbarPainter old) =>
      old.thumbTop != thumbTop ||
      old.thumbHeight != thumbHeight ||
      old.trackWidth != trackWidth ||
      old.thumbColor != thumbColor ||
      old.trackColor != trackColor;
}
