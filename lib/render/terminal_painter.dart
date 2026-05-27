import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'cell_flags.dart';
import 'glyph_cache.dart';
import 'mirror_grid.dart';

/// System monospace from `fc-match monospace`; falls back to generic monospace.
const kTerminalFontFamily = 'DejaVu Sans Mono';

const kTerminalTextStyle = TextStyle(
  fontFamily: kTerminalFontFamily,
  fontFamilyFallback: ['monospace'],
  fontSize: 14,
  height: 1.2,
);

class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.glyphs,
    required this.cellWidth,
    required this.cellHeight,
  })  : _paintGeneration = grid.generation,
        super(repaint: grid);

  final MirrorGrid grid;
  final GlyphCache glyphs;
  final double cellWidth;
  final double cellHeight;
  final int _paintGeneration;

  @override
  void paint(Canvas canvas, Size size) {
    final rows = grid.rows, cols = grid.columns;
    if (rows == 0 || cols == 0) return;
    glyphs.beginFrame();

    // Pass 1: backgrounds (so a wide glyph isn't overwritten by the spacer's bg).
    final bgPaint = Paint();
    for (var row = 0; row < rows; row++) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        bgPaint.color = Color(0xFF000000 | grid.bgAt(row, col));
        canvas.drawRect(Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight), bgPaint);
      }
    }

    // Pass 2: glyphs.
    var needsWarmupFrame = false;
    for (var row = 0; row < rows; row++) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        final flags = grid.flagsAt(row, col);
        if (flags & kFlagWideSpacer != 0) continue; // covered by the wide glyph at col-1
        final cp = grid.codepointAt(row, col);
        if (cp == 32 || cp == 0) continue;
        final paragraph =
            glyphs.tryGet(cp, grid.fgAt(row, col), wide: flags & kFlagWide != 0);
        if (paragraph != null) {
          canvas.drawParagraph(paragraph, Offset(col * cellWidth, y));
        } else {
          needsWarmupFrame = true;
        }
      }
    }
    if (needsWarmupFrame) SchedulerBinding.instance.scheduleFrame();

    // Cursor — spans two cells when sitting on a wide char.
    if (grid.cursorVisible) {
      final onWide = grid.cursorRow < rows &&
          grid.cursorCol < cols &&
          grid.flagsAt(grid.cursorRow, grid.cursorCol) & kFlagWide != 0;
      final cw = onWide ? cellWidth * 2 : cellWidth;
      canvas.drawRect(
        Rect.fromLTWH(grid.cursorCol * cellWidth, grid.cursorRow * cellHeight, cw, cellHeight),
        Paint()..color = const Color(0x88FFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.grid != grid ||
      old._paintGeneration != _paintGeneration ||
      old.cellWidth != cellWidth ||
      old.cellHeight != cellHeight;
}
