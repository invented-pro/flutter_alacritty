# Plan 2C-1 — Wide-Char / CJK Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render double-width (CJK) text correctly — wide glyphs drawn across two cells, spacer cells skipped, a CJK monospace font in the fallback chain — so Chinese text aligns on the grid without overlap.

**Architecture:** Carry a per-cell `flags` lane from the Rust engine into the Dart `MirrorGrid`; the painter switches to two-pass rendering (all backgrounds, then all glyphs) and uses the flags to draw `WIDE_CHAR` glyphs at `2×cellWidth` and skip `WIDE_CHAR_SPACER` cells. The glyph cache becomes wide-aware, and `Noto Sans Mono CJK SC` joins the font fallback.

**Tech Stack:** Rust (`alacritty_terminal`), Flutter 3.41 / Dart 3.11. Confirmed installed CJK font: `Noto Sans Mono CJK SC` (fallback `WenQuanYi Zen Hei Mono`).

**Builds on:** branch `feature/c1-wide-char-cjk` (off `main` with Plan 2A merged). Spec: `docs/superpowers/specs/2026-05-27-plan2c1-wide-char-cjk-design.md`.

**Non-goals:** text attributes (bold/italic/underline/inverse/dim/strikeout/hidden), cursor shapes/blink, line-spacing (later C slices); combining marks / complex emoji (only `cell.c` is read).

---

## File Structure

- `rust/src/engine.rs` — MODIFY: add `FLAG_WIDE_SPACER`; `map_flags` emits it.
- `lib/render/cell_flags.dart` — CREATE: Dart mirror of the flag bits.
- `lib/render/mirror_grid.dart` — MODIFY: `LineCells.flags`; `MirrorGrid` flags lane + `flagsAt`.
- `lib/engine/engine_binding.dart` — MODIFY: `_lineCells` fills `flags`.
- `lib/render/glyph_cache.dart` — MODIFY: wide-aware key + layout width.
- `lib/render/terminal_painter.dart` — MODIFY: two-pass paint; wide glyph; skip spacer; wide cursor; CJK fallback in `kTerminalTextStyle`.
- Tests: `rust/src/engine.rs` (`#[cfg(test)]`), `test/mirror_grid_test.dart`, `test/glyph_cache_test.dart`, `test/terminal_painter_test.dart`.

---

## Task 1: Rust — FLAG_WIDE_SPACER + map_flags

**Files:** Modify `rust/src/engine.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `rust/src/engine.rs`:
```rust
#[test]
fn wide_char_sets_wide_and_spacer_flags() {
    let mut e = engine(20, 5);
    e.advance("中".as_bytes().to_vec());
    let u = e.full_snapshot();
    let row0 = line(&u, 0);
    assert_eq!(char::from_u32(row0.cells[0].codepoint).unwrap(), '中');
    assert_ne!(row0.cells[0].flags & FLAG_WIDE, 0, "lead cell must be WIDE_CHAR");
    assert_ne!(
        row0.cells[1].flags & FLAG_WIDE_SPACER,
        0,
        "the cell after a wide char must be WIDE_CHAR_SPACER"
    );
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test engine::tests::wide_char 2>&1 | tail -15`
Expected: FAIL — `FLAG_WIDE_SPACER` not found.

- [ ] **Step 3: Add the flag constant**

In `rust/src/engine.rs`, after `pub const FLAG_WIDE: u16 = 1 << 4;` add:
```rust
pub const FLAG_WIDE_SPACER: u16 = 1 << 5;
```

- [ ] **Step 4: Emit it in `map_flags`**

In `map_flags`, after the `WIDE_CHAR` block, add:
```rust
    if f.contains(Flags::WIDE_CHAR_SPACER) {
        out |= FLAG_WIDE_SPACER;
    }
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd rust && cargo test engine 2>&1 | tail -15`
Expected: all engine tests pass including `wide_char_sets_wide_and_spacer_flags`.

- [ ] **Step 6: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git add rust/src/engine.rs
git commit -m "feat(rust): emit FLAG_WIDE_SPACER for wide-char trailing cells"
```

---

## Task 2: Dart — cell_flags.dart + MirrorGrid flags lane

**Files:** Create `lib/render/cell_flags.dart`; Modify `lib/render/mirror_grid.dart`; Modify `test/mirror_grid_test.dart`

- [ ] **Step 1: Create the flag-bit mirror**

Create `lib/render/cell_flags.dart`:
```dart
// Mirror of the cell flag bits in rust/src/engine.rs — keep in sync.
const int kFlagBold = 1 << 0;
const int kFlagItalic = 1 << 1;
const int kFlagUnderline = 1 << 2;
const int kFlagInverse = 1 << 3;
const int kFlagWide = 1 << 4;
const int kFlagWideSpacer = 1 << 5;
```

- [ ] **Step 2: Write the failing test**

Replace the `row` helper and add a flags test in `test/mirror_grid_test.dart`. The helper now sets flags (default 0); a new test threads a flag through:
```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

LineCells row(int line, String text, {List<int>? flags}) => LineCells(
      line: line,
      codepoints: Int32List.fromList(text.codeUnits),
      fg: Int32List.fromList(List.filled(text.length, 0xD8D8D8)),
      bg: Int32List.fromList(List.filled(text.length, 0x181818)),
      flags: Uint16List.fromList(flags ?? List.filled(text.length, 0)),
    );

void main() {
  test('full update populates all rows', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 2, columns: 3,
      lines: [row(0, 'abc'), row(1, '   ')],
      cursorRow: 0, cursorCol: 1, cursorVisible: true,
    ));
    expect(g.rows, 2);
    expect(g.columns, 3);
    expect(g.codepointAt(0, 2), 'c'.codeUnitAt(0));
  });

  test('partial update mutates only named lines', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(full: true, rows: 2, columns: 3,
        lines: [row(0, 'abc'), row(1, 'xyz')],
        cursorRow: 0, cursorCol: 0, cursorVisible: true));
    g.apply(GridUpdate(full: false, rows: 0, columns: 0,
        lines: [row(1, 'QQQ')], cursorRow: 1, cursorCol: 2, cursorVisible: true));
    expect(g.codepointAt(0, 0), 'a'.codeUnitAt(0));
    expect(g.codepointAt(1, 0), 'Q'.codeUnitAt(0));
    expect(g.cursorRow, 1);
  });

  test('stores per-cell flags', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 1, columns: 2,
      lines: [row(0, '中X', flags: [kFlagWide, kFlagWideSpacer])],
      cursorRow: 0, cursorCol: 0, cursorVisible: true,
    ));
    expect(g.flagsAt(0, 0) & kFlagWide, kFlagWide);
    expect(g.flagsAt(0, 1) & kFlagWideSpacer, kFlagWideSpacer);
  });
}
```
> Note `'中'.codeUnits` is a single UTF-16 unit (中 = U+4E2D, BMP), so `row(0, '中X')` yields 2 cells — matches the 2-column grid.

- [ ] **Step 3: Run to verify it fails**

Run: `flutter test test/mirror_grid_test.dart`
Expected: FAIL — `LineCells` has no `flags` parameter; `flagsAt` undefined.

- [ ] **Step 4: Add the flags lane to MirrorGrid**

In `lib/render/mirror_grid.dart`:

Add `flags` to `LineCells`:
```dart
class LineCells {
  LineCells({
    required this.line,
    required this.codepoints,
    required this.fg,
    required this.bg,
    required this.flags,
  });
  final int line;
  final Int32List codepoints;
  final Int32List fg;
  final Int32List bg;
  final Uint16List flags;
}
```

In `MirrorGrid`, add the storage + accessor and extend `_ensureSize`/`apply`:
```dart
  List<Uint16List> _flags = [];

  int flagsAt(int row, int col) => _flags[row][col];
```
In `_ensureSize`, alongside the other `List.generate` lines:
```dart
    _flags = List.generate(rows, (_) => Uint16List(columns));
```
In `apply`, inside the `for (final l in u.lines)` loop, after the bg `setAll`:
```dart
      _flags[l.line].setAll(0, l.flags);
```

- [ ] **Step 5: Run to verify it passes**

Run: `flutter test test/mirror_grid_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/render/cell_flags.dart lib/render/mirror_grid.dart test/mirror_grid_test.dart
git commit -m "feat(render): per-cell flags lane in MirrorGrid"
```

---

## Task 3: Dart — engine_binding fills flags

**Files:** Modify `lib/engine/engine_binding.dart`

- [ ] **Step 1: Fill flags in `_lineCells`**

In `lib/engine/engine_binding.dart`, replace `_lineCells` with:
```dart
  LineCells _lineCells(LineUpdate l) {
    final n = l.cells.length;
    final codepoints = Int32List(n);
    final fg = Int32List(n);
    final bg = Int32List(n);
    final flags = Uint16List(n);
    for (var i = 0; i < n; i++) {
      final c = l.cells[i];
      codepoints[i] = c.codepoint;
      fg[i] = c.fg;
      bg[i] = c.bg;
      flags[i] = c.flags;
    }
    return LineCells(line: l.line, codepoints: codepoints, fg: fg, bg: bg, flags: flags);
  }
```
(`CellData.flags` is the FRB-bridged `u16` → Dart `int`.)

- [ ] **Step 2: Verify it analyzes**

Run: `flutter analyze lib/engine`
Expected: No issues found. (No isolated unit test — `_lineCells` consumes FRB types and is exercised by `engine_bindings_test` + Task 7 manual acceptance.)

- [ ] **Step 3: Commit**

```bash
git add lib/engine/engine_binding.dart
git commit -m "feat(engine): carry cell flags through to the mirror grid"
```

---

## Task 4: Dart — wide-aware GlyphCache

**Files:** Modify `lib/render/glyph_cache.dart`; Modify `test/glyph_cache_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/glyph_cache_test.dart`:
```dart
  test('wide and narrow keys are distinct', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    final narrow = cache.tryGet(0x4E2D, 0xFFFFFF, wide: false);
    final wide = cache.tryGet(0x4E2D, 0xFFFFFF, wide: true);
    expect(narrow, isNotNull);
    expect(wide, isNotNull);
    expect(identical(narrow, wide), isFalse);
    // Same args return the cached instance.
    expect(identical(wide, cache.tryGet(0x4E2D, 0xFFFFFF, wide: true)), isTrue);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/glyph_cache_test.dart`
Expected: FAIL — `tryGet` has no `wide` named parameter.

- [ ] **Step 3: Make `tryGet`/`_build` wide-aware**

In `lib/render/glyph_cache.dart`, replace `tryGet` and `_build`:
```dart
  ui.Paragraph? tryGet(int codepoint, int fg, {bool wide = false}) {
    final key = (codepoint << 25) ^ ((wide ? 1 : 0) << 24) ^ (fg & 0xFFFFFF);
    final existing = _cache.remove(key); // remove+reinsert = LRU touch
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }
    if (_buildsThisFrame >= maxBuildsPerFrame) return null;
    _buildsThisFrame++;
    final p = _build(codepoint, fg, wide);
    _cache[key] = p;
    if (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first); // evict eldest
    }
    return p;
  }

  ui.Paragraph _build(int codepoint, int fg, bool wide) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
    ))
      ..pushStyle(ui.TextStyle(
        color: ui.Color(0xFF000000 | (fg & 0xFFFFFF)),
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: fontSize,
      ))
      ..addText(String.fromCharCode(codepoint));
    final p = builder.build()
      ..layout(ui.ParagraphConstraints(width: wide ? cellWidth * 2 : cellWidth));
    return p;
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/glyph_cache_test.dart`
Expected: PASS (4 tests; the existing `tryGet(cp, fg)` calls still compile via the `wide` default).

- [ ] **Step 5: Commit**

```bash
git add lib/render/glyph_cache.dart test/glyph_cache_test.dart
git commit -m "feat(render): wide-aware glyph cache (2x layout width)"
```

---

## Task 5: Dart — two-pass painter (wide draw, skip spacer, wide cursor)

**Files:** Modify `lib/render/terminal_painter.dart`; Modify `test/terminal_painter_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/terminal_painter_test.dart` (a recording GlyphCache subclass asserts the painter draws the wide glyph and skips the spacer column):
```dart
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/terminal_painter_test.dart`
Expected: FAIL — painter still draws every non-blank cell (the spacer 'X' is drawn), and `tryGet` is called without `wide`.

- [ ] **Step 3: Rewrite `paint()` to two passes + wide handling**

In `lib/render/terminal_painter.dart`, add the import and replace the `paint` method body:
```dart
import 'cell_flags.dart';
```
```dart
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/terminal_painter_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/render/terminal_painter.dart test/terminal_painter_test.dart
git commit -m "feat(render): two-pass paint with wide-char glyphs + spacer skip"
```

---

## Task 6: Dart — CJK font in the fallback chain

**Files:** Modify `lib/render/terminal_painter.dart`

- [ ] **Step 1: Add the CJK fallback to `kTerminalTextStyle`**

In `lib/render/terminal_painter.dart`, replace the style block:
```dart
/// System monospace from `fc-match monospace`; CJK via Noto/WenQuanYi mono.
const kTerminalFontFamily = 'DejaVu Sans Mono';

const kTerminalTextStyle = TextStyle(
  fontFamily: kTerminalFontFamily,
  fontFamilyFallback: ['Noto Sans Mono CJK SC', 'WenQuanYi Zen Hei Mono', 'monospace'],
  fontSize: 14,
  height: 1.2,
);
```
> `TerminalScreen` already passes `_style.fontFamilyFallback` into `GlyphCache`, so this propagates to both metrics and glyph layout. The fonts are confirmed installed (`fc-list`); if a future environment lacks them, install `fonts-noto-cjk` / `fonts-wqy-zenhei`.

- [ ] **Step 2: Verify analysis + full suite**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all Dart tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/render/terminal_painter.dart
git commit -m "feat(render): CJK monospace fonts in the fallback chain"
```

---

## Task 7: Manual acceptance gate + findings

**Files:** Create `docs/superpowers/plans/2026-05-27-plan2c1-findings.md`

- [ ] **Step 1: Build a fresh native lib + run on Linux**

Run:
```bash
cd rust && cargo build && cd ..
flutter run -d linux
```

- [ ] **Step 2: Walk the acceptance checklist** (record pass/fail)
- [ ] `echo 中文测试` renders aligned, no overlap.
- [ ] `ls` of a directory with CJK filenames aligns into columns.
- [ ] The earlier `hello` mistype message renders cleanly (the screenshot case).
- [ ] A line mixing CJK + Latin stays grid-aligned.
- [ ] The cursor on a CJK char covers two cells (move the cursor onto Chinese text).
- [ ] A basic wide emoji renders if present (ZWJ/combining sequences knowingly not handled).

- [ ] **Step 3: Record findings**

Create `docs/superpowers/plans/2026-05-27-plan2c1-findings.md` capturing: checklist results; the resolved open question (does the `WIDE_CHAR_SPACER` cell's `cell.c` hold a space or a stray char — observe a snapshot of `中`); whether `2×cellWidth` aligns CJK acceptably vs the CJK font's natural advance; any glyph-cache or font adjustments; carry-over notes for C-2 (attributes).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-05-27-plan2c1-findings.md
git commit -m "docs: Plan 2C-1 acceptance findings"
```

---

## Self-Review (completed by author)

- **Spec coverage:** `FLAG_WIDE_SPACER` + map_flags (Task 1); per-cell flags lane in mirror (Task 2) + `cell_flags.dart` (Task 2); binding fills flags (Task 3); wide-aware glyph cache (Task 4); two-pass paint + wide draw + spacer skip + wide cursor (Task 5); CJK font fallback (Task 6); acceptance + open-question resolution (Task 7). All §1 in-scope items mapped; non-goals untouched.
- **Placeholder scan:** none — every code step has complete code; the only environment-dependent detail (CJK font availability) is resolved (fonts confirmed installed; install command noted).
- **Type consistency:** `FLAG_WIDE` / `FLAG_WIDE_SPACER` (Rust) ↔ `kFlagWide` / `kFlagWideSpacer` (Dart, bits match: `1<<4`, `1<<5`). `LineCells(... flags: Uint16List)` constructor consistent across Task 2 (def + test), Task 3 (`_lineCells`), and Task 5 (test). `GlyphCache.tryGet(cp, fg, {wide})` consistent between Task 4 (def + test) and Task 5 (painter + recording subclass). `MirrorGrid.flagsAt(row, col)` consistent between Task 2 (def) and Task 5 (painter). Glyph-cache key `(cp<<25)^(wide<<24)^(fg&0xFFFFFF)` leaves bit 24 free for the wide flag above the 24-bit color.
```
