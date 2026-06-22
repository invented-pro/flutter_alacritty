import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';

import '../render/cell_metrics.dart';

/// The grid that fits a terminal viewport at its current font metrics.
///
/// Always represents a usable terminal: [cols] ≥ [minCols], [rows] ≥ [minRows].
/// Constructed by [ViewportGeometryResolver] only when the viewport is large
/// enough; callsites receive `null` when the container is in a transitional
/// layout and should not push a degenerate grid to the PTY.
@immutable
class TerminalGrid {
  final int cols;
  final int rows;

  const TerminalGrid(this.cols, this.rows)
      : assert(cols > 0),
        assert(rows > 0);

  /// Smallest grid a human can use. Below this the viewport is in a layout
  /// transition (sidebar animation, worktree switch, zero-width tab frame).
  /// Pushing a smaller grid to the PTY would force every TUI to reflow to
  /// infinitesimal dimensions and then back — the visible "jump."
  ///
  /// Counterpart of orca's MIN_PANE_FIT_COLS (8) and MIN_PANE_FIT_ROWS (4).
  static const int minCols = 8;
  static const int minRows = 4;

  /// Pixel floor for the available paint area, mirroring orca's
  /// MIN_PANE_FIT_WIDTH_PX (48) / MIN_PANE_FIT_HEIGHT_PX (24). With tiny fonts a
  /// container can satisfy the 8×4 *cell* floor while still being a near-zero
  /// transition frame; this catches that case too (double guard, pixels + cells).
  static const double minWidthPx = 48;
  static const double minHeightPx = 24;

  /// Whether `(cols, rows)` is at least the usable floor.
  static bool isUsable(int cols, int rows) =>
      cols >= minCols && rows >= minRows;

  @override
  bool operator ==(Object other) =>
      other is TerminalGrid && other.cols == cols && other.rows == rows;

  @override
  int get hashCode => Object.hash(cols, rows);

  /// Sentinel value guaranteed to never match any real grid. Used by
  /// [TerminalResizeController] to force the first PTY commit.
  static const TerminalGrid sentinel = TerminalGrid(65535, 65535);

  @override
  String toString() => 'TerminalGrid($cols×$rows)';
}

/// Parameters for resolving a terminal grid from a viewport size.
///
/// Captures everything the resolver needs: the available paint area (already
/// with host padding subtracted), the measured cell dimensions at the current
/// font, and any space reserved for chrome (scrollbar gutter, etc.).
class ViewportQuery {
  /// Available paint area. Hosts subtract their own padding (e.g. 36px
  /// horizontal, 8px vertical) before passing it here.
  final Size available;

  /// Measured cell dimensions at the current font size + DPR.
  /// Sub-pixel precision; must match what the painter uses.
  final CellMetrics cell;

  /// Space reserved for chrome that lives inside the paint area but should
  /// not be occupied by cells — e.g. a scrollbar gutter. The resolver
  /// subtracts this from [available] before computing the cell grid.
  final EdgeInsets reserve;

  const ViewportQuery({
    required this.available,
    required this.cell,
    this.reserve = EdgeInsets.zero,
  });
}

/// Pure-function resolver: maps a [ViewportQuery] to a [TerminalGrid].
///
/// No state, no timers, no callbacks — safe to call every frame from a
/// [LayoutBuilder]. The resolver's job is measurement; policy decisions
/// about *when* to commit the result to the PTY belong to
/// [ResizeCommitPolicy].
class ViewportGeometryResolver {
  const ViewportGeometryResolver();

  /// Returns the grid that fits [query], or `null` when the viewport is
  /// too small to host a usable terminal.
  ///
  /// `null` means "don't change the grid" — the viewport is in a layout
  /// transition and pushing a degenerate size to the PTY would cause the
  /// visible jump this architecture eliminates.
  TerminalGrid? resolve(ViewportQuery query) {
    final availW =
        (query.available.width - query.reserve.horizontal)
            .clamp(0.0, double.infinity);
    final availH =
        (query.available.height - query.reserve.vertical)
            .clamp(0.0, double.infinity);

    if (availW <= 0 || availH <= 0) return null;

    // Pixel floor (orca's canMeasurePaneForFit): reject transition frames whose
    // container is too small to host a usable terminal, before cell math.
    if (availW < TerminalGrid.minWidthPx || availH < TerminalGrid.minHeightPx) {
      return null;
    }

    final cols = (availW / query.cell.width).floor();
    final rows = (availH / query.cell.height).floor();

    if (!TerminalGrid.isUsable(cols, rows)) return null;

    return TerminalGrid(cols, rows);
  }
}
