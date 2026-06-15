import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/links/link_overlay.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

final _steadyBlink = ValueNotifier(true);

class _RecordingGlyphCache extends GlyphCache {
  _RecordingGlyphCache()
      : super(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
  final List<(int, bool)> calls = [];
  /// Records (codepoint, fg) for every tryGet call, enabling color assertions.
  final List<(int, int)> fgCalls = [];
  @override
  Paragraph? tryGet(int codepoint, int fg,
      {bool bold = false, bool italic = false, bool wide = false}) {
    calls.add((codepoint, wide));
    fgCalls.add((codepoint, fg));
    return super.tryGet(codepoint, fg, bold: bold, italic: italic, wide: wide);
  }
}

void main() {
  test('cursor rect matches shape', () {
    expect(cursorRect(0, 8, 16, 2.0), const Rect.fromLTWH(0, 0, 8, 16));
    final beam = cursorRect(2, 8, 16, 2.0);
    expect(beam.width, lessThan(8));
    expect(beam.left, 0);
    final underline = cursorRect(1, 8, 16, 2.0);
    expect(underline.bottom, 16);
    expect(underline.height, lessThan(16));
  });

  test('underline sits near the bottom, strikeout near the middle', () {
    final ys = decorationYs(0.0, 20.0);
    expect(ys.underline, greaterThan(15.0));
    expect(ys.underline, lessThanOrEqualTo(20.0));
    expect(ys.strikeout, closeTo(10.0, 2.0));
  });

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
            grid: grid,
            glyphs: glyphs,
            cellWidth: 8,
            cellHeight: 16,
            blinkOn: _steadyBlink,
            selectionColor: 0x553A6EA5,
            searchColors: const SearchColors(
              matchBg: 0xAC4242,
              matchFg: 0x181818,
              focusedBg: 0xF4BF75,
              focusedFg: 0x181818,
            ),
            hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818)),
      ),
    ));
    await tester.pump();

    // The wide lead char is drawn with wide:true; the spacer's stray 'X' is NOT drawn.
    expect(glyphs.calls.contains((0x4E2D, true)), isTrue); // 中
    expect(glyphs.calls.any((c) => c.$1 == 'X'.codeUnitAt(0)), isFalse);
  });

  testWidgets('selected cell gets a highlight overlay', (tester) async {
    final grid = MirrorGrid();
    grid.apply(GridUpdate(
      full: true, rows: 1, columns: 2,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('ab'.codeUnits),
          fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Int32List.fromList([0x181818, 0x181818]),
          flags: Uint16List.fromList([kFlagSelected, 0]),
        ),
      ],
      cursorRow: 0, cursorCol: 0, cursorVisible: false,
    ));
    expect(isSelected(grid.flagsAt(0, 0)), isTrue);
    expect(isSelected(grid.flagsAt(0, 1)), isFalse);
  });

  group('applyMatchOrHint precedence', () {
    const search = SearchColors(
        matchBg: 0xAC4242, matchFg: 0x181818, focusedBg: 0xF4BF75, focusedFg: 0x181818);
    const hint = HintColors(bg: 0xF4BF75, fg: 0x181818);
    const base = (fg: 0xD8D8D8, bg: 0x222222);

    test('no match/hint flag passes the base pair through', () {
      expect(applyMatchOrHint(0, base, search, hint), base);
    });
    test('FLAG_HYPERLINK alone uses hint colors', () {
      final r = applyMatchOrHint(kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xF4BF75);
      expect(r.fg, 0x181818);
    });
    test('FLAG_MATCH alone returns the matches colors', () {
      final r = applyMatchOrHint(kFlagMatch, base, search, hint);
      expect(r.bg, 0xAC4242);
      expect(r.fg, 0x181818);
    });
    test('FLAG_MATCH wins over FLAG_HYPERLINK', () {
      final r = applyMatchOrHint(kFlagMatch | kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xAC4242);
    });
    test('FLAG_MATCH_CURRENT wins over plain match', () {
      final r = applyMatchOrHint(kFlagMatch | kFlagMatchCurrent, base, search, hint);
      expect(r.bg, 0xF4BF75);
      expect(r.fg, 0x181818);
    });
    test('current-match alone (without plain match bit) still picks focused', () {
      final r = applyMatchOrHint(kFlagMatchCurrent, base, search, hint);
      expect(r.bg, 0xF4BF75);
    });
    test('FLAG_MATCH_CURRENT wins over both match and hyperlink', () {
      final r = applyMatchOrHint(
          kFlagMatchCurrent | kFlagMatch | kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xF4BF75);
    });

    test('overlay link (no grid kFlagHyperlink) produces same hint colors as a real hyperlink', () {
      // Simulate what the painter does: the overlay says row=0, col=0 is a link;
      // the grid cell has no kFlagHyperlink. The painter computes:
      const int gridFlags = 0; // no hyperlink flag in grid
      final overlay = LinkOverlay({
        0: const [LinkCellRange(start: 0, end: 1)],
      });
      final bool overlayLink = overlay.isLinkCell(0, 0);
      final int effFlags = overlayLink ? (gridFlags | kFlagHyperlink) : gridFlags;

      final r = applyMatchOrHint(effFlags, base, search, hint);
      expect(r.bg, hint.bg, reason: 'overlay cell gets hint bg');
      expect(r.fg, hint.fg, reason: 'overlay cell gets hint fg');
    });

    test('search match still wins over overlay link (precedence preserved)', () {
      const int gridFlags = kFlagMatch; // search match in grid
      final overlay = LinkOverlay({
        0: const [LinkCellRange(start: 0, end: 1)],
      });
      final bool overlayLink = overlay.isLinkCell(0, 0);
      final int effFlags = overlayLink ? (gridFlags | kFlagHyperlink) : gridFlags;

      final r = applyMatchOrHint(effFlags, base, search, hint);
      expect(r.bg, search.matchBg, reason: 'match wins over overlay link');
    });
  });

  testWidgets('TerminalPainter with LinkOverlay renders without error', (tester) async {
    final grid = MirrorGrid();
    grid.apply(GridUpdate(
      full: true, rows: 1, columns: 3,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('abc'.codeUnits),
          fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8, 0xD8D8D8]),
          bg: Int32List.fromList([0x181818, 0x181818, 0x181818]),
          // No kFlagHyperlink in grid flags for any cell.
          flags: Uint16List.fromList([0, 0, 0]),
        ),
      ],
      cursorRow: 0, cursorCol: 0, cursorVisible: false,
    ));
    final glyphs = _RecordingGlyphCache();

    // Col 1 covered by overlay — should be treated as a hyperlink by the painter.
    final overlay = LinkOverlay({
      0: const [LinkCellRange(start: 1, end: 2)],
    });

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(
        size: const Size(24, 16),
        painter: TerminalPainter(
          grid: grid,
          glyphs: glyphs,
          cellWidth: 8,
          cellHeight: 16,
          blinkOn: _steadyBlink,
          selectionColor: 0x553A6EA5,
          searchColors: const SearchColors(
            matchBg: 0xAC4242,
            matchFg: 0x181818,
            focusedBg: 0xF4BF75,
            focusedFg: 0x181818,
          ),
          hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818),
          linkOverlay: overlay,
        ),
      ),
    ));
    await tester.pump();

    // All three columns render their glyphs (no crash from the overlay path).
    expect(glyphs.calls.any((c) => c.$1 == 'a'.codeUnitAt(0)), isTrue);
    expect(glyphs.calls.any((c) => c.$1 == 'b'.codeUnitAt(0)), isTrue);
    expect(glyphs.calls.any((c) => c.$1 == 'c'.codeUnitAt(0)), isTrue);
  });

  // ---------------------------------------------------------------------------
  // Painter-level color assertions for the overlay path.
  //
  // The glyph cache's tryGet(codepoint, fg, …) receives the *effective* fg
  // color that the painter computed, including any hint-color override.  We
  // capture (codepoint, fg) in _RecordingGlyphCache.fgCalls and assert that:
  //   1. An overlay-covered cell's glyph is rendered with the hint fg color
  //      (proving the painter applied the hint-color path).
  //   2. The fg seen for the overlay cell is identical to the fg seen for an
  //      equivalent cell that carries a *real* kFlagHyperlink flag — i.e. the
  //      overlay and the native hyperlink flag produce exactly the same painter
  //      output (robust equivalence assertion).
  //
  // Limitation: canvas.drawLine (underline) is not intercepted by the glyph
  // cache, and Flutter's test Canvas does not expose a recorded call list.
  // We therefore cannot assert the underline draw directly at this layer.
  // The `decorationYs` unit test above confirms the Y coordinate math; the
  // painter code path at line ~203 gates drawLine on
  // `effFlags & (kFlagUnderline | kFlagHyperlink) != 0`, which is covered by
  // the same effFlags logic verified here.
  // ---------------------------------------------------------------------------

  testWidgets(
      'overlay cell glyph uses hint fg color — same as real kFlagHyperlink cell',
      (tester) async {
    const int hintBg = 0xF4BF75;
    const int hintFg = 0x181818; // the expected fg for both overlay and real hyperlink
    const int baseFg = 0xD8D8D8;
    const int baseBg = 0x181818;
    const searchColors = SearchColors(
      matchBg: 0xAC4242,
      matchFg: 0x181818,
      focusedBg: 0xF4BF75,
      focusedFg: 0x181818,
    );
    const hintColors = HintColors(bg: hintBg, fg: hintFg);

    // --- Part A: overlay cell (no kFlagHyperlink in grid flags) ---
    final gridA = MirrorGrid();
    gridA.apply(GridUpdate(
      full: true,
      rows: 1,
      columns: 3,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('abc'.codeUnits),
          fg: Int32List.fromList([baseFg, baseFg, baseFg]),
          bg: Int32List.fromList([baseBg, baseBg, baseBg]),
          // No kFlagHyperlink on any cell — col 1 is a link via overlay only.
          flags: Uint16List.fromList([0, 0, 0]),
        ),
      ],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
    ));
    final glyphsA = _RecordingGlyphCache();
    final overlay = LinkOverlay({
      0: const [LinkCellRange(start: 1, end: 2)], // col 1 ('b') is the overlay link
    });

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(
        size: const Size(24, 16),
        painter: TerminalPainter(
          grid: gridA,
          glyphs: glyphsA,
          cellWidth: 8,
          cellHeight: 16,
          blinkOn: _steadyBlink,
          selectionColor: 0x553A6EA5,
          searchColors: searchColors,
          hintColors: hintColors,
          linkOverlay: overlay,
        ),
      ),
    ));
    await tester.pump();

    // Col 0 ('a') and col 2 ('c') — no overlay — should use the base fg.
    final aFgCalls = glyphsA.fgCalls
        .where((c) => c.$1 == 'a'.codeUnitAt(0))
        .toList();
    expect(aFgCalls, isNotEmpty, reason: "'a' glyph must be rendered");
    expect(aFgCalls.first.$2, baseFg, reason: "non-overlay cell keeps base fg");

    // Col 1 ('b') — covered by overlay — must use the hint fg.
    final bFgCallsA = glyphsA.fgCalls
        .where((c) => c.$1 == 'b'.codeUnitAt(0))
        .toList();
    expect(bFgCallsA, isNotEmpty, reason: "'b' glyph must be rendered");
    expect(
      bFgCallsA.first.$2,
      hintFg,
      reason:
          'overlay-covered cell must receive hint fg color (0x${hintFg.toRadixString(16)})',
    );

    // --- Part B: real kFlagHyperlink cell (no overlay) ---
    final gridB = MirrorGrid();
    gridB.apply(GridUpdate(
      full: true,
      rows: 1,
      columns: 3,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('abc'.codeUnits),
          fg: Int32List.fromList([baseFg, baseFg, baseFg]),
          bg: Int32List.fromList([baseBg, baseBg, baseBg]),
          // Col 1 carries a real kFlagHyperlink.
          flags: Uint16List.fromList([0, kFlagHyperlink, 0]),
        ),
      ],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
    ));
    final glyphsB = _RecordingGlyphCache();

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(
        size: const Size(24, 16),
        painter: TerminalPainter(
          grid: gridB,
          glyphs: glyphsB,
          cellWidth: 8,
          cellHeight: 16,
          blinkOn: _steadyBlink,
          selectionColor: 0x553A6EA5,
          searchColors: searchColors,
          hintColors: hintColors,
          // No overlay — the hyperlink flag is purely from the grid.
        ),
      ),
    ));
    await tester.pump();

    final bFgCallsB = glyphsB.fgCalls
        .where((c) => c.$1 == 'b'.codeUnitAt(0))
        .toList();
    expect(bFgCallsB, isNotEmpty, reason: "'b' glyph must be rendered for real hyperlink");
    expect(
      bFgCallsB.first.$2,
      hintFg,
      reason: 'real kFlagHyperlink cell must also receive hint fg color',
    );

    // Equivalence: overlay path and native-hyperlink path must produce identical fg.
    expect(
      bFgCallsA.first.$2,
      bFgCallsB.first.$2,
      reason:
          'overlay-link fg must equal native-kFlagHyperlink fg — '
          'both painter paths must be equivalent',
    );
  });
}
