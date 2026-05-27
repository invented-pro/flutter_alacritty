import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

class _RecordingGlyphCache extends GlyphCache {
  _RecordingGlyphCache()
      : super(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
  final List<(int, bool)> calls = [];
  @override
  ui.Paragraph? tryGet(int codepoint, int fg, {bool wide = false}) {
    calls.add((codepoint, wide));
    return super.tryGet(codepoint, fg, wide: wide);
  }
}

void main() {
  testWidgets('draws wide glyph once and skips the spacer column', (tester) async {
    final grid = MirrorGrid();
    // Row "中X": col0 = wide '中', col1 = spacer carrying a stray 'X'.
    grid.apply(GridUpdate(
      full: true, rows: 1, columns: 2,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('中X'.codeUnits),
          fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Int32List.fromList([0x181818, 0x181818]),
          flags: Uint16List.fromList([kFlagWide, kFlagWideSpacer]),
        ),
      ],
      cursorRow: 0, cursorCol: 0, cursorVisible: false,
    ));
    final glyphs = _RecordingGlyphCache();

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(
        size: const Size(16, 16),
        painter: TerminalPainter(
            grid: grid, glyphs: glyphs, cellWidth: 8, cellHeight: 16),
      ),
    ));
    await tester.pump();

    // The wide lead char is drawn with wide:true; the spacer's stray 'X' is NOT drawn.
    expect(glyphs.calls.contains((0x4E2D, true)), isTrue); // 中
    expect(glyphs.calls.any((c) => c.$1 == 'X'.codeUnitAt(0)), isFalse);
  });
}
