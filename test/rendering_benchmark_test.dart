@Tags(['benchmark'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_atlas.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

import 'support/benchmark_thresholds.dart';

/// Headless rendering benchmark for the grid painter. Reports, per representative
/// 80×24 screen:
///   * draw-call counts per frame (drawRect = backgrounds after P2 merge/skip;
///     drawParagraph = per-glyph submissions, the count P4's atlas would collapse;
///     drawLine = decorations),
///   * UI-thread paint() wall time over N warm frames.
///
/// Tagged `benchmark` — excluded from PR CI (`--exclude-tags benchmark`).
/// Run locally or in the nightly benchmark job:
///   flutter test --tags benchmark test/rendering_benchmark_test.dart
///
/// These are UI-thread (Dart paint) numbers and draw-call counts only — they do
/// NOT measure raster/GPU thread cost. For that, profile the real app
/// (`flutter run --profile` + DevTools timeline).
class _CountingCanvas implements Canvas {
  int rects = 0;
  int paragraphs = 0;
  int lines = 0;
  int atlasCalls = 0;
  int atlasSprites = 0;

  @override
  void drawRect(ui.Rect rect, ui.Paint paint) => rects++;
  @override
  void drawParagraph(ui.Paragraph paragraph, ui.Offset offset) => paragraphs++;
  @override
  void drawLine(ui.Offset p1, ui.Offset p2, ui.Paint paint) => lines++;
  @override
  void drawRawAtlas(ui.Image atlas, Float32List rstTransforms, Float32List rects_,
      Int32List? colors, ui.BlendMode? blendMode, ui.Rect? cullRect, ui.Paint paint) {
    atlasCalls++;
    atlasSprites += rstTransforms.length ~/ 4;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BenchResult {
  const _BenchResult({
    required this.usPerFrame,
    required this.rects,
    required this.paragraphs,
    required this.atlasCalls,
    required this.atlasSprites,
    required this.lines,
  });

  final double usPerFrame;
  final int rects;
  final int paragraphs;
  final int atlasCalls;
  final int atlasSprites;
  final int lines;
}

const int _cols = 80;
const int _rows = 24;
const int _defaultFg = 0xD8D8D8;
const int _defaultBg = 0x181818;

GlyphCache _warmCache() => GlyphCache(
      fontFamily: 'monospace',
      fontSize: 14,
      cellWidth: 8,
      maxEntries: 1 << 20,
      maxBuildsPerFrame: 1 << 20,
    );

MirrorGrid _grid(
  int Function(int row, int col) cp, {
  int Function(int row, int col)? bg,
  int Function(int row, int col)? fg,
  int Function(int row, int col)? flags,
}) {
  final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
  final lines = <LineCells>[];
  for (var r = 0; r < _rows; r++) {
    final cps = Uint32List(_cols);
    final fgs = Uint32List(_cols);
    final bgs = Uint32List(_cols);
    final fls = Uint16List(_cols);
    for (var c = 0; c < _cols; c++) {
      cps[c] = cp(r, c);
      fgs[c] = fg?.call(r, c) ?? _defaultFg;
      bgs[c] = bg?.call(r, c) ?? _defaultBg;
      fls[c] = flags?.call(r, c) ?? 0;
    }
    lines.add(LineCells(line: r, codepoints: cps, fg: fgs, bg: bgs, flags: fls));
  }
  grid.apply(GridUpdate(
    full: true,
    rows: _rows,
    columns: _cols,
    lines: lines,
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: false,
    defaultFg: _defaultFg,
    defaultBg: _defaultBg,
  ));
  return grid;
}

TerminalPainter _painter(MirrorGrid grid, GlyphCache glyphs, {GlyphAtlas? atlas}) =>
    TerminalPainter(
      grid: grid,
      glyphs: glyphs,
      cellWidth: 8,
      cellHeight: 16,
      selectionColor: 0x553A6EA5,
      searchColors: const SearchColors(
        matchBg: 0xAC4242, matchFg: 0x181818,
        focusedBg: 0xF4BF75, focusedFg: 0x181818,
      ),
      hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818),
      atlas: atlas,
    );

_BenchResult _bench(String name, MirrorGrid grid, {bool useAtlas = false}) {
  final glyphs = _warmCache();
  final atlas = useAtlas
      ? GlyphAtlas(
          fontFamily: 'monospace', fontSize: 14, cellWidth: 8, cellHeight: 16,
          devicePixelRatio: 1.0)
      : null;
  final painter = _painter(grid, glyphs, atlas: atlas);
  const size = ui.Size(_cols * 8.0, _rows * 16.0);

  for (var i = 0; i < 4; i++) {
    final rec = ui.PictureRecorder();
    painter.paint(Canvas(rec), size);
    rec.endRecording().dispose();
  }

  final counter = _CountingCanvas();
  painter.paint(counter as Canvas, size);

  const n = 300;
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final rec = ui.PictureRecorder();
    painter.paint(Canvas(rec), size);
    rec.endRecording().dispose();
  }
  sw.stop();
  final usPerFrame = sw.elapsedMicroseconds / n;

  // ignore: avoid_print
  print('[$name${useAtlas ? ' +ATLAS' : ''}] ${_cols}x$_rows  '
      'drawRect=${counter.rects}  drawParagraph=${counter.paragraphs}  '
      'drawRawAtlas=${counter.atlasCalls}(${counter.atlasSprites} sprites)  '
      'drawLine=${counter.lines}  '
      'paint=${usPerFrame.toStringAsFixed(1)}us/frame');

  return _BenchResult(
    usPerFrame: usPerFrame,
    rects: counter.rects,
    paragraphs: counter.paragraphs,
    atlasCalls: counter.atlasCalls,
    atlasSprites: counter.atlasSprites,
    lines: counter.lines,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scenario A — idle shell prompt (mostly default bg, one short line)', () {
    const prompt = r'user@host:~/project$ ';
    final grid = _grid(
      (r, c) => r == 0 && c < prompt.length ? prompt.codeUnitAt(c) : 32,
    );
    final r = _bench('A idle-prompt', grid);
    expect(r.usPerFrame, lessThan(kPaintIdlePromptMaxUs));
    // One full-viewport default-bg clear (self-sufficient layer).
    expect(r.rects, 1);
    expect(r.paragraphs, 20);
  });

  test('scenario B — full-screen colored cells (htop-like)', () {
    const palette = [0x264653, 0x2A9D8F, 0xE9C46A, 0xF4A261, 0xE76F51];
    final grid = _grid(
      (r, c) => 65 + ((r + c) % 26),
      bg: (r, c) => palette[((c ~/ 6) + r) % palette.length],
      fg: (r, c) => 0x101010,
    );
    final r = _bench('B colored-bands', grid);
    expect(r.usPerFrame, lessThan(kPaintColoredBandsMaxUs));
  });

  test('scenario C — dense text, default bg (drawParagraph-bound)', () {
    final grid = _grid((r, c) => 33 + ((r * 80 + c) % 94));
    final plain = _bench('C dense-text', grid);
    expect(plain.usPerFrame, lessThan(kPaintDenseTextMaxUs));
    expect(plain.rects, kFullViewportClearRects);

    final atlased = _bench('C dense-text', grid, useAtlas: true);
    expect(atlased.usPerFrame, lessThan(kPaintDenseTextAtlasMaxUs));
    expect(atlased.paragraphs, kDenseTextAtlasParagraphs);
    expect(atlased.atlasCalls, kDenseTextAtlasCalls);
    expect(atlased.atlasSprites, kDenseTextGlyphCount);
  });

  test('scenario D — worst case: dense text + per-cell alternating bg', () {
    final grid = _grid(
      (r, c) => 33 + ((r * 80 + c) % 94),
      bg: (r, c) => (c % 2 == 0) ? 0x402020 : 0x204020,
    );
    final plain = _bench('D worst-case', grid);
    expect(plain.usPerFrame, lessThan(kPaintWorstCaseMaxUs));

    final atlased = _bench('D worst-case', grid, useAtlas: true);
    expect(atlased.usPerFrame, lessThan(kPaintWorstCaseAtlasMaxUs));
    expect(atlased.paragraphs, kDenseTextAtlasParagraphs);
    expect(atlased.atlasCalls, kDenseTextAtlasCalls);
  });
}
