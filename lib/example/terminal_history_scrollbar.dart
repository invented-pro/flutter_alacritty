import 'package:flutter/material.dart';

import '../controller/terminal_controller.dart';
import '../engine/terminal_engine.dart';
import '../input/term_mode.dart';
import 'terminal_scrollbar_geometry.dart';

/// Vertical scrollbar for [ExampleTerminalApp] only (not part of the library API).
///
/// Maps thumb position on a **viewport-sized** track to the engine's
/// `display_offset` (0 = live bottom). Uses live `history_size` from the engine
/// and GtkAdjustment-style absolute positioning (`scrollToOffset`) so drags are
/// not fighting coalesced wheel deltas — same model as VTE + GtkRange.
class TerminalHistoryScrollbar extends StatefulWidget {
  const TerminalHistoryScrollbar({
    required this.engine,
    required this.controller,
    super.key,
  });

  final TerminalEngine engine;
  final TerminalController controller;

  @override
  State<TerminalHistoryScrollbar> createState() =>
      _TerminalHistoryScrollbarState();
}

class _TerminalHistoryScrollbarState extends State<TerminalHistoryScrollbar> {
  bool _dragging = false;
  double _lastScrollPos = 0;
  int _lastHistorySize = 0;
  int _lastModeFlags = 0;

  @override
  void initState() {
    super.initState();
    final grid = widget.engine.grid;
    _lastScrollPos = grid.displayOffset + grid.scrollFraction;
    _lastHistorySize = grid.historySize;
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
      _lastHistorySize = grid.historySize;
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
    final historySize = grid.historySize;
    if (scrollPos == _lastScrollPos &&
        modeFlags == _lastModeFlags &&
        historySize == _lastHistorySize) {
      return;
    }
    _lastScrollPos = scrollPos;
    _lastHistorySize = historySize;
    _lastModeFlags = modeFlags;
    setState(() {});
  }

  TerminalScrollbarGeometry _geometry(double trackHeight) {
    final grid = widget.engine.grid;
    return TerminalScrollbarGeometry(
      historySize: grid.historySize,
      viewportRows: grid.rows,
      scrollOffsetLines: grid.displayOffset + grid.scrollFraction,
      trackHeight: trackHeight,
    );
  }

  /// GtkRange sets the adjustment value directly; we mirror that via
  /// [TerminalController.scrollToOffset] (cancels pending wheel coalesce).
  Future<void> _scrollToFraction(double fraction) async {
    final grid = widget.engine.grid;
    final historySize = grid.historySize;
    if (historySize <= 0) return;

    final geom = TerminalScrollbarGeometry(
      historySize: historySize,
      viewportRows: grid.rows,
      scrollOffsetLines: grid.displayOffset + grid.scrollFraction,
      trackHeight: 1,
    );
    final target = geom.scrollOffsetForFraction(fraction);

    if (geom.isNearBottom(target)) {
      await widget.controller.scrollToBottom();
    } else if (geom.isNearTop(target)) {
      await widget.controller.scrollToTop();
    } else {
      await widget.controller.scrollToOffset(target);
    }
  }

  void _onTrackPointer(double localDy, double trackHeight) {
    if (trackHeight <= 0) return;
    final geom = _geometry(trackHeight);
    if (!geom.visible) return;
    final fraction = TerminalScrollbarGeometry.fractionFromTrackDy(
      localDy: localDy,
      trackHeight: trackHeight,
      thumbHeight: geom.thumbHeight,
    );
    _scrollToFraction(fraction);
  }

  @override
  Widget build(BuildContext context) {
    final grid = widget.engine.grid;
    if (grid.modeFlags & kModeAltScreen != 0) {
      return const SizedBox(width: 0);
    }

    if (grid.historySize <= 0) {
      return const SizedBox(width: 0);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        if (trackHeight <= 0) return const SizedBox(width: 0);

        final geom = _geometry(trackHeight);
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
                thumbTop: geom.thumbTop,
                thumbHeight: geom.thumbHeight,
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
