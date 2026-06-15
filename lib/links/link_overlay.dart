/// A confirmed link column range on one viewport row (half-open `[start, end)`).
class LinkCellRange {
  const LinkCellRange({required this.start, required this.end});
  final int start;
  final int end;
  bool contains(int col) => col >= start && col < end;
}

/// Immutable per-frame map of viewport-row -> enabled link ranges. Built by
/// `TerminalView` from enabled provider spans and read by `TerminalPainter` so
/// host-provided links underline like OSC 8 hyperlinks without touching grid flags.
class LinkOverlay {
  const LinkOverlay(this._rows);
  final Map<int, List<LinkCellRange>> _rows;

  static const LinkOverlay empty = LinkOverlay(<int, List<LinkCellRange>>{});

  bool isLinkCell(int row, int col) {
    final ranges = _rows[row];
    if (ranges == null) return false;
    for (final r in ranges) {
      if (r.contains(col)) return true;
    }
    return false;
  }
}
