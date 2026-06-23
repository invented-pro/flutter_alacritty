/// Pure scrollbar math for [TerminalHistoryScrollbar].
///
/// Mirrors GtkAdjustment / VTE semantics (see `gtk_adjustment` + VTE scroll):
/// - `upper` = `history_size + viewport_rows` (total lines in the buffer)
/// - `page_size` = `viewport_rows`
/// - `value` ∈ [0, history_size] (= `display_offset` + `scroll_fraction`)
/// - thumb size = `page_size / upper`
class TerminalScrollbarGeometry {
  const TerminalScrollbarGeometry({
    required this.historySize,
    required this.viewportRows,
    required this.scrollOffsetLines,
    required this.trackHeight,
    this.minThumbFraction = 0.08,
  });

  /// Within this many lines of an edge, snap to [scrollToTop]/[scrollToBottom].
  static const double edgeSnapLines = 0.5;

  final int historySize;
  final int viewportRows;
  final double scrollOffsetLines;
  final double trackHeight;
  final double minThumbFraction;

  bool get visible => historySize > 0 && trackHeight > 0;

  /// 1.0 = live bottom (thumb at bottom), 0.0 = top of history.
  double get positionFraction {
    if (historySize <= 0) return 1.0;
    final pos = (scrollOffsetLines / historySize).clamp(0.0, 1.0);
    return 1.0 - pos;
  }

  double get thumbFraction {
    if (historySize <= 0) return 1.0;
    final viewport = viewportRows.clamp(1, historySize + viewportRows);
    return (viewport / (historySize + viewport)).clamp(minThumbFraction, 1.0);
  }

  double get thumbHeight => trackHeight * thumbFraction;

  double get thumbTop {
    final usable = trackHeight - thumbHeight;
    if (usable <= 0) return 0;
    return positionFraction * usable;
  }

  /// Map a track-local Y (thumb center follows the pointer) to [positionFraction].
  static double fractionFromTrackDy({
    required double localDy,
    required double trackHeight,
    required double thumbHeight,
  }) {
    final usable = trackHeight - thumbHeight;
    if (usable <= 0) return 1.0;
    final center = localDy.clamp(thumbHeight / 2, trackHeight - thumbHeight / 2);
    return (1.0 - ((center - thumbHeight / 2) / usable)).clamp(0.0, 1.0);
  }

  /// Scroll offset in lines (`display_offset` + `scroll_fraction`) for [fraction].
  double scrollOffsetForFraction(double fraction) =>
      (1.0 - fraction.clamp(0.0, 1.0)) * historySize;

  /// Whether [offsetLines] is close enough to an edge to use Top/Bottom hops.
  bool isNearBottom(double offsetLines) => offsetLines <= edgeSnapLines;

  bool isNearTop(double offsetLines) =>
      historySize > 0 && offsetLines >= historySize - edgeSnapLines;
}
