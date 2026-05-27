# Plan 2D — Scrollback / Selection / Copy-Paste Implementation Plan (staged: D1/D2/D3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scroll back through history (wheel/keys), select text with the mouse, copy (`Ctrl+Shift+C`), and middle-click-paste the selection.

**Architecture:** Selection and scroll live in the Rust engine (Alacritty `Selection` + `scroll_display`), so text extraction is correct across history. Rendering becomes `display_offset`-aware via Alacritty's `point_to_viewport`; selected cells carry a `FLAG_SELECTED` bit the painter highlights. Three mergeable phases: D1 scrollback, D2 selection+copy, D3 middle-click paste.

**Tech Stack:** Rust (`alacritty_terminal`), Flutter 3.41 / Dart 3.11.

**Builds on:** branch `feature/d-scrollback-selection` (off `main` @ f44ecb6). Spec: `docs/superpowers/specs/2026-05-27-plan2d-scrollback-selection-design.md`.

**Verified APIs:** `grid::Scroll{Delta(i32),Bottom}`, `grid.display_offset()->usize`, `term::point_to_viewport(off, Point)->Option<Point<usize>>`, `term::viewport_to_point(off, Point<usize>)->Point`, `Selection::new(SelectionType,Point,Side)`/`update(Point,Side)`/`to_range(&term)`, `term.selection: Option<Selection>`, `term.selection_to_string()`, `SelectionType{Simple,Semantic,Lines}`, `index::Side{Left,Right}`.

**Non-goals:** X11 PRIMARY system clipboard, block/rectangular selection, scrollbar widget, search.

---

## File Structure

```
rust/src/engine.rs              MODIFY (D1 offset-aware render + scroll; D2 selection + FLAG_SELECTED)
rust/src/api/terminal.rs        regen (D1, D2)
lib/render/mirror_grid.dart     MODIFY (D1 displayOffset)
lib/render/cell_flags.dart      MODIFY (D2 kFlagSelected)
lib/render/terminal_painter.dart MODIFY (D2 selection highlight)
lib/engine/engine_binding.dart  MODIFY (D1 displayOffset map + scroll; D2 selection passthroughs)
lib/engine/terminal_engine_client.dart MODIFY (D1 scroll helpers)
lib/ui/terminal_screen.dart     MODIFY (D1 wheel; D2 pointer selection + copy; D3 middle-click paste)
```

---
---

# PHASE D1 — scrollback

## Task D1.1: Rust — offset-aware render + scroll

**Files:** Modify `rust/src/engine.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `rust/src/engine.rs`:
```rust
#[test]
fn scroll_shows_history_then_returns_to_bottom() {
    let mut e = engine(10, 3); // 3 visible rows
    for i in 0..10 {
        e.advance(format!("line{}\r\n", i).into_bytes());
    }
    // At bottom: latest lines visible, offset 0.
    assert_eq!(e.full_snapshot().display_offset, 0);

    e.scroll_lines(2); // scroll up 2 lines into history
    let u = e.full_snapshot();
    assert_eq!(u.display_offset, 2);
    // Row 0 now shows an older line than it did at the bottom.
    let row0: String = u.lines.iter().find(|l| l.line == 0).unwrap()
        .cells.iter().map(|c| char::from_u32(c.codepoint).unwrap()).collect();
    assert!(row0.trim_end().starts_with("line"));
    // Cursor is hidden while scrolled back.
    assert!(!u.cursor_visible);

    e.scroll_to_bottom();
    assert_eq!(e.full_snapshot().display_offset, 0);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test engine::tests::scroll 2>&1 | tail -15`
Expected: FAIL — `RenderUpdate` has no `display_offset`; `scroll_lines`/`scroll_to_bottom` undefined.

- [ ] **Step 3: Add imports, the field, and a shared cell mapper**

In `rust/src/engine.rs`:
Extend imports:
```rust
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::term::{point_to_viewport, cell::Cell};
```
(Keep existing `use` lines; add `Scroll`, `Point`, `point_to_viewport`, `cell::Cell` if not already imported.)

Add to `struct RenderUpdate` (after `mode_flags`):
```rust
    pub display_offset: u32,
```
Add a free helper near `map_flags`:
```rust
fn cell_data(cell: &Cell) -> CellData {
    CellData {
        codepoint: cell.c as u32,
        fg: resolve_color(cell.fg, true),
        bg: resolve_color(cell.bg, false),
        flags: map_flags(cell.flags),
    }
}
```

- [ ] **Step 4: Make `full_snapshot` offset-aware + hide cursor when scrolled**

Replace `full_snapshot` with:
```rust
pub fn full_snapshot(&self) -> RenderUpdate {
    let cols = self.term.columns();
    let rows = self.term.screen_lines();
    let display_offset = self.term.grid().display_offset();
    let blank = CellData { codepoint: ' ' as u32, fg: DEFAULT_FG, bg: DEFAULT_BG, flags: 0 };
    let mut lines: Vec<LineUpdate> = (0..rows)
        .map(|r| LineUpdate { line: r as u32, cells: vec![blank.clone(); cols] })
        .collect();
    for indexed in self.term.grid().display_iter() {
        if let Some(vp) = point_to_viewport(display_offset, indexed.point) {
            if vp.line < rows && vp.column.0 < cols {
                lines[vp.line].cells[vp.column.0] = cell_data(indexed.cell);
            }
        }
    }
    let (cursor_line, cursor_col, cursor_visible, cursor_shape, cursor_blinking) =
        self.cursor_fields();
    RenderUpdate {
        lines,
        full: true,
        cursor_line,
        cursor_col,
        cursor_visible: cursor_visible && display_offset == 0, // hidden when scrolled
        cursor_shape,
        cursor_blinking,
        mode_flags: self.term.mode().bits(),
        display_offset: display_offset as u32,
    }
}
```

- [ ] **Step 5: `take_damage` returns full when scrolled; set display_offset on the partial path**

At the top of `take_damage`, before reading damage:
```rust
    if self.term.grid().display_offset() > 0 {
        return self.full_snapshot();
    }
```
In the `Some(rows)` branch's constructed `RenderUpdate { … }`, add:
```rust
                    display_offset: 0,
```
(The `None`/full branch returns `full_snapshot()`, which sets it.)

- [ ] **Step 6: Add the scroll methods**

Add inside `impl TerminalEngine`:
```rust
pub fn scroll_lines(&mut self, delta: i32) {
    self.term.scroll_display(Scroll::Delta(delta));
}

pub fn scroll_to_bottom(&mut self) {
    self.term.scroll_display(Scroll::Bottom);
}
```

- [ ] **Step 7: Refactor `line_cells` to reuse `cell_data` (DRY)**

Replace the per-cell construction inside `line_cells` so it calls the shared mapper:
```rust
    fn line_cells(&self, row: usize) -> Vec<CellData> {
        let grid = self.term.grid();
        let cols = grid.columns();
        let g_line = &grid[Line(row as i32)];
        (0..cols).map(|col| cell_data(&g_line[Column(col)])).collect()
    }
```

- [ ] **Step 8: Run to verify it passes**

Run: `cd rust && cargo test engine 2>&1 | tail -15`
Expected: all engine tests pass including `scroll_shows_history_then_returns_to_bottom`.

- [ ] **Step 9: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git add rust/src/engine.rs
git commit -m "feat(rust): display_offset-aware render + scroll_lines/scroll_to_bottom"
```

---

## Task D1.2: FRB + Dart scroll wiring

**Files:** codegen; Modify `lib/render/mirror_grid.dart`, `lib/engine/engine_binding.dart`, `lib/engine/terminal_engine_client.dart`; Modify `test/mirror_grid_test.dart`

- [ ] **Step 1: Regenerate FRB**

Run:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen generate
```
Expected: `RenderUpdate` gains `displayOffset` (int); `engineScrollLines`/`engineScrollToBottom` appear once exposed (Step 3). No errors.

- [ ] **Step 2: Expose the scroll functions in the FRB api**

In `rust/src/api/terminal.rs`, add (near the other `engine_*` wrappers):
```rust
pub async fn engine_scroll_lines(engine: &mut TerminalEngine, delta: i32) {
    engine.scroll_lines(delta);
}
pub async fn engine_scroll_to_bottom(engine: &mut TerminalEngine) {
    engine.scroll_to_bottom();
}
```
Then rerun `flutter_rust_bridge_codegen generate`.

- [ ] **Step 3: Write the failing test (MirrorGrid carries displayOffset)**

Add to `test/mirror_grid_test.dart`:
```dart
  test('carries display offset', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 1, columns: 1, lines: [row(0, ' ')],
      cursorRow: 0, cursorCol: 0, cursorVisible: true, displayOffset: 4,
    ));
    expect(g.displayOffset, 4);
  });
```

- [ ] **Step 4: Run to verify it fails**

Run: `flutter test test/mirror_grid_test.dart`
Expected: FAIL — `GridUpdate` has no `displayOffset`.

- [ ] **Step 5: Add displayOffset to GridUpdate + MirrorGrid + binding; scroll helpers on the client**

In `lib/render/mirror_grid.dart`, add to `GridUpdate` (constructor + field, after `modeFlags`):
```dart
    this.displayOffset = 0,
```
```dart
  final int displayOffset;
```
In `MirrorGrid`: add storage + getter and set it in `apply` (after `_modeFlags = u.modeFlags;`):
```dart
  int _displayOffset = 0;
  int get displayOffset => _displayOffset;
```
```dart
    _displayOffset = u.displayOffset;
```
In `lib/engine/engine_binding.dart` `_toGridUpdate`, after `modeFlags: u.modeFlags,`:
```dart
        displayOffset: u.displayOffset,
```
Add scroll methods to the `EngineBinding` interface:
```dart
  Future<void> scrollLines(int delta);
  Future<void> scrollToBottom();
```
Implement in `FrbEngineBinding`:
```dart
  @override
  Future<void> scrollLines(int delta) => engineScrollLines(engine: _engine, delta: delta);
  @override
  Future<void> scrollToBottom() => engineScrollToBottom(engine: _engine);
```
Add no-ops to the test `_FakeBinding` in `test/engine_client_test.dart`:
```dart
  @override
  Future<void> scrollLines(int delta) async {}
  @override
  Future<void> scrollToBottom() async {}
```
Add convenience methods to `TerminalEngineClient` (so the screen drives scrolling and re-renders):
```dart
  Future<void> scrollLines(int delta) async {
    await _binding.scrollLines(delta);
    _grid.apply(await _binding.takeDamage()); // scrolled -> full snapshot
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<void> scrollToBottom() async {
    await _binding.scrollToBottom();
  }
```

- [ ] **Step 6: Run to verify it passes**

Run: `flutter test test/mirror_grid_test.dart test/engine_client_test.dart && flutter analyze lib`
Expected: PASS; analyze clean.

- [ ] **Step 7: Commit**

```bash
git add rust/src/api/terminal.rs rust/src/frb_generated.rs lib/src/rust lib/render/mirror_grid.dart lib/engine/engine_binding.dart lib/engine/terminal_engine_client.dart test/mirror_grid_test.dart test/engine_client_test.dart
git commit -m "feat(engine): FRB scroll + carry display offset to the mirror grid"
```

---

## Task D1.3: Wheel + scroll-to-bottom wiring in TerminalScreen

**Files:** Modify `lib/ui/terminal_screen.dart`

- [ ] **Step 1: Scroll on wheel; alt-screen sends arrows**

In `lib/ui/terminal_screen.dart`, replace the `onPointerSignal` handler with a scroll-aware one:
```dart
              onPointerSignal: (e) {
                if (e is! PointerScrollEvent) return;
                final up = e.scrollDelta.dy < 0;
                // App captured the mouse → forward as wheel mouse events.
                if (anyMouse(_grid.modeFlags)) {
                  _reportMouse(e.localPosition, 0,
                      up ? MouseAction.scrollUp : MouseAction.scrollDown);
                  return;
                }
                // Alt-screen (pagers/vim): the wheel sends arrow keys (3 per notch).
                if (_grid.modeFlags & kModeAltScreen != 0) {
                  final arrow = up ? [0x1b, 0x4f, 0x41] : [0x1b, 0x4f, 0x42]; // SS3 A/B
                  for (var i = 0; i < 3; i++) {
                    _pty?.write(Uint8List.fromList(arrow));
                  }
                  return;
                }
                // Normal screen → scroll the history view.
                _client?.scrollLines(up ? 3 : -3);
              },
```

- [ ] **Step 2: A key that sends bytes returns to the bottom first**

In `_onKey`, right before `_pty?.write(bytes);`, add:
```dart
    _client?.scrollToBottom();
```
(Typing snaps back to live output. `scrollToBottom` only changes `display_offset`; the next drain or this write's echo re-renders at the bottom.)

- [ ] **Step 3: Resize snaps to bottom**

In `_ensureStarted`, inside the resize branch (after `_pty!.resize(rows, cols);`):
```dart
        _client!.scrollToBottom();
```

- [ ] **Step 4: Verify analysis + tests**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 5: Manual check + commit**

`flutter run -d linux`: run `ls -la /usr/bin | head -100`, then scroll the wheel up — older output appears; press a key — it snaps to the bottom. In `less`/vim the wheel scrolls the pager. Then:
```bash
git add lib/ui/terminal_screen.dart
git commit -m "feat(ui): wheel scrollback, alt-screen wheel arrows, snap-to-bottom on key"
```

---
---

# PHASE D2 — selection + copy

## Task D2.1: Rust — selection + FLAG_SELECTED

**Files:** Modify `rust/src/engine.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module:
```rust
#[test]
fn selection_text_and_selected_flag() {
    let mut e = engine(20, 3);
    e.advance(b"hello world".to_vec());
    e.selection_start(0, 0, false, 0); // simple, row 0 col 0, left side
    e.selection_update(0, 4, true);    // through col 4, right side -> "hello"
    let txt = e.selection_text().unwrap();
    assert!(txt.starts_with("hello"), "got {:?}", txt);

    let u = e.full_snapshot();
    let row0 = u.lines.iter().find(|l| l.line == 0).unwrap();
    assert_ne!(row0.cells[0].flags & FLAG_SELECTED, 0);
    assert_ne!(row0.cells[4].flags & FLAG_SELECTED, 0);
    assert_eq!(row0.cells[10].flags & FLAG_SELECTED, 0); // 'd' not selected

    e.selection_clear();
    assert!(e.selection_text().is_none());
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test engine::tests::selection 2>&1 | tail -15`
Expected: FAIL — `FLAG_SELECTED` / `selection_*` undefined.

- [ ] **Step 3: Add imports, the flag, and a range test helper**

In `rust/src/engine.rs`, extend imports:
```rust
use alacritty_terminal::index::Side;
use alacritty_terminal::selection::{Selection, SelectionRange, SelectionType};
use alacritty_terminal::term::viewport_to_point;
```
Add the flag (after `FLAG_STRIKEOUT`):
```rust
pub const FLAG_SELECTED: u16 = 1 << 8;
```
Add a free helper:
```rust
fn point_in_range(p: Point, r: &SelectionRange) -> bool {
    let after_start = p.line > r.start.line
        || (p.line == r.start.line && p.column >= r.start.column);
    let before_end = p.line < r.end.line
        || (p.line == r.end.line && p.column <= r.end.column);
    after_start && before_end
}

fn sel_type(kind: u8) -> SelectionType {
    match kind {
        1 => SelectionType::Semantic,
        2 => SelectionType::Lines,
        _ => SelectionType::Simple,
    }
}
```

- [ ] **Step 4: Add the selection methods**

Inside `impl TerminalEngine`:
```rust
fn viewport_point(&self, display_row: i32, col: u16) -> Point {
    let d = self.term.grid().display_offset();
    viewport_to_point(d, Point::new(display_row.max(0) as usize, Column(col as usize)))
}

pub fn selection_start(&mut self, display_row: i32, col: u16, right_half: bool, kind: u8) {
    let p = self.viewport_point(display_row, col);
    let side = if right_half { Side::Right } else { Side::Left };
    self.term.selection = Some(Selection::new(sel_type(kind), p, side));
}

pub fn selection_update(&mut self, display_row: i32, col: u16, right_half: bool) {
    let p = self.viewport_point(display_row, col);
    let side = if right_half { Side::Right } else { Side::Left };
    if let Some(sel) = self.term.selection.as_mut() {
        sel.update(p, side);
    }
}

pub fn selection_clear(&mut self) {
    self.term.selection = None;
}

pub fn selection_text(&self) -> Option<String> {
    self.term.selection_to_string()
}
```

- [ ] **Step 5: Mark selected cells in `full_snapshot`**

In `full_snapshot`, compute the range once and OR the flag in the display loop. Replace the `for indexed …` loop body:
```rust
    let sel = self
        .term
        .selection
        .as_ref()
        .and_then(|s| s.to_range(&self.term));
    for indexed in self.term.grid().display_iter() {
        if let Some(vp) = point_to_viewport(display_offset, indexed.point) {
            if vp.line < rows && vp.column.0 < cols {
                let mut cd = cell_data(indexed.cell);
                if let Some(r) = &sel {
                    if point_in_range(indexed.point, r) {
                        cd.flags |= FLAG_SELECTED;
                    }
                }
                lines[vp.line].cells[vp.column.0] = cd;
            }
        }
    }
```
> Selection changes go through `full_snapshot` — when the screen updates the selection it requests a fresh snapshot (Task D2.3), so partial damage need not track selection.

- [ ] **Step 6: Run to verify it passes**

Run: `cd rust && cargo test engine 2>&1 | tail -15`
Expected: all engine tests pass including `selection_text_and_selected_flag`.

- [ ] **Step 7: Commit**

```bash
git add rust/src/engine.rs
git commit -m "feat(rust): alacritty selection + FLAG_SELECTED in snapshot"
```

---

## Task D2.2: FRB + cell_flags + binding + painter highlight

**Files:** codegen; Modify `lib/render/cell_flags.dart`, `lib/engine/engine_binding.dart`, `lib/render/terminal_painter.dart`; Test `test/terminal_painter_test.dart`

- [ ] **Step 1: Expose selection in the FRB api + regen**

In `rust/src/api/terminal.rs`, add:
```rust
#[frb(sync)]
pub fn engine_selection_start(
    engine: &mut TerminalEngine,
    display_row: i32,
    col: u16,
    right_half: bool,
    kind: u8,
) {
    engine.selection_start(display_row, col, right_half, kind);
}
#[frb(sync)]
pub fn engine_selection_update(engine: &mut TerminalEngine, display_row: i32, col: u16, right_half: bool) {
    engine.selection_update(display_row, col, right_half);
}
#[frb(sync)]
pub fn engine_selection_clear(engine: &mut TerminalEngine) {
    engine.selection_clear();
}
#[frb(sync)]
pub fn engine_selection_text(engine: &TerminalEngine) -> Option<String> {
    engine.selection_text()
}
```
Run `flutter_rust_bridge_codegen generate`.

- [ ] **Step 2: Add the Dart flag bit**

In `lib/render/cell_flags.dart`, after `kFlagStrikeout`:
```dart
const int kFlagSelected = 1 << 8;
```

- [ ] **Step 3: Add selection passthroughs to the binding**

In `lib/engine/engine_binding.dart`, add to the `EngineBinding` interface:
```dart
  void selectionStart(int displayRow, int col, bool rightHalf, int kind);
  void selectionUpdate(int displayRow, int col, bool rightHalf);
  void selectionClear();
  String? selectionText();
```
Implement in `FrbEngineBinding`:
```dart
  @override
  void selectionStart(int displayRow, int col, bool rightHalf, int kind) =>
      engineSelectionStart(engine: _engine, displayRow: displayRow, col: col, rightHalf: rightHalf, kind: kind);
  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) =>
      engineSelectionUpdate(engine: _engine, displayRow: displayRow, col: col, rightHalf: rightHalf);
  @override
  void selectionClear() => engineSelectionClear(engine: _engine);
  @override
  String? selectionText() => engineSelectionText(engine: _engine);
```
Add no-ops to the `_FakeBinding` in `test/engine_client_test.dart`:
```dart
  @override
  void selectionStart(int displayRow, int col, bool rightHalf, int kind) {}
  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) {}
  @override
  void selectionClear() {}
  @override
  String? selectionText() => null;
```

- [ ] **Step 4: Write the failing painter test**

Add to `test/terminal_painter_test.dart`:
```dart
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
```
(Import `package:flutter_alacritty/render/cell_flags.dart`.)

- [ ] **Step 5: Run to verify it fails**

Run: `flutter test test/terminal_painter_test.dart`
Expected: FAIL — `isSelected` undefined.

- [ ] **Step 6: Add `isSelected` + highlight selected cells in Pass 1**

In `lib/render/cell_flags.dart` add a helper:
```dart
bool isSelected(int flags) => flags & kFlagSelected != 0;
```
In `lib/render/terminal_painter.dart` Pass 1 (backgrounds), after drawing the bg rect, overlay a selection tint when selected:
```dart
        if (isSelected(grid.flagsAt(row, col))) {
          canvas.drawRect(
            Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight),
            Paint()..color = const Color(0x553A6EA5), // translucent selection accent
          );
        }
```
(`isSelected`/`kFlagSelected` come from the already-imported `cell_flags.dart`.)

- [ ] **Step 7: Run to verify it passes**

Run: `flutter test && flutter analyze lib test`
Expected: PASS; analyze clean.

- [ ] **Step 8: Commit**

```bash
git add rust/src/api/terminal.rs rust/src/frb_generated.rs lib/src/rust lib/render/cell_flags.dart lib/render/terminal_painter.dart lib/engine/engine_binding.dart test/engine_client_test.dart test/terminal_painter_test.dart
git commit -m "feat(render): selection FRB passthroughs + selected-cell highlight"
```

---

## Task D2.3: Pointer selection + copy in TerminalScreen

**Files:** Modify `lib/ui/terminal_screen.dart`

- [ ] **Step 1: Add selection state + a helper to map a pointer to a cell**

In `lib/ui/terminal_screen.dart`, add fields:
```dart
  int _clickCount = 0;
  DateTime _lastClick = DateTime.fromMillisecondsSinceEpoch(0);
  bool _selecting = false;
```
Add a helper that returns `(displayRow, col, rightHalf)` for a local offset:
```dart
  (int, int, bool) _cellAt(Offset local) {
    final col = (local.dx / _metrics.width).floor().clamp(0, _cols - 1);
    final row = (local.dy / _metrics.height).floor().clamp(0, _rows - 1);
    final rightHalf = (local.dx / _metrics.width) - col > 0.5;
    return (row, col, rightHalf);
  }

  Future<void> _refreshSelection() async {
    if (_client == null) return;
    _grid.apply(await _client!.binding.takeDamage()); // selection changed -> re-render
    SchedulerBinding.instance.scheduleFrame();
  }
```
> Expose the binding on the client: add `EngineBinding get binding => _binding;` to `TerminalEngineClient`.

- [ ] **Step 2: Start/extend/finish selection on pointer events**

In the `Listener`, extend the handlers. Selection runs when the app is **not** grabbing the mouse, or when **Shift** is held (override). In `onPointerDown`:
```dart
              onPointerDown: (e) {
                _focus.requestFocus();
                final localSelect =
                    !anyMouse(_grid.modeFlags) || HardwareKeyboard.instance.isShiftPressed;
                if (localSelect && e.buttons & kPrimaryButton != 0) {
                  final now = DateTime.now();
                  _clickCount = (now.difference(_lastClick).inMilliseconds < 300)
                      ? (_clickCount % 3) + 1
                      : 1;
                  _lastClick = now;
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _client!.binding.selectionStart(r, c, rh, _clickCount - 1); // 0 simple,1 word,2 line
                  _selecting = true;
                  _refreshSelection();
                  return;
                }
                _pressedButton = _btn(e.buttons);
                _reportMouse(e.localPosition, _pressedButton, MouseAction.down);
              },
```
In `onPointerMove`, handle an active selection first:
```dart
              onPointerMove: (e) {
                if (_selecting) {
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _client!.binding.selectionUpdate(r, c, rh);
                  _refreshSelection();
                  return;
                }
                if (e.buttons == 0) {
                  if ((_grid.modeFlags & kModeMouseMotion) == 0) return;
                  _reportMouse(e.localPosition, 3, MouseAction.move);
                } else {
                  _reportMouse(e.localPosition, _btn(e.buttons), MouseAction.move);
                }
              },
```
In `onPointerUp`, finalize:
```dart
              onPointerUp: (e) {
                if (_selecting) {
                  _selecting = false;
                  _primary = _client!.binding.selectionText() ?? ''; // D3 in-app primary
                  return;
                }
                _reportMouse(e.localPosition, _pressedButton, MouseAction.up);
              },
```
Add the field `String _primary = '';` (used by D3).

- [ ] **Step 3: Ctrl+Shift+C copies; any byte-producing key clears the selection**

In `_onKey`, add a copy intercept next to the paste one:
```dart
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyC) {
      final text = _client?.binding.selectionText();
      if (text != null && text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
      }
      return KeyEventResult.handled;
    }
```
And, right before `_pty?.write(bytes);` (where `scrollToBottom` was added in D1.3), also clear the selection:
```dart
    _client?.binding.selectionClear();
    _refreshSelection();
```

- [ ] **Step 4: Verify analysis + tests**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 5: Manual check + commit**

`flutter run -d linux`: drag selects a highlighted region; double-click selects a word, triple a line; `Ctrl+Shift+C` then paste elsewhere matches; typing clears the selection. Then:
```bash
git add lib/ui/terminal_screen.dart lib/engine/terminal_engine_client.dart
git commit -m "feat(ui): mouse selection (word/line) + Ctrl+Shift+C copy"
```

---
---

# PHASE D3 — middle-click paste

## Task D3.1: Middle-click pastes the in-app primary

**Files:** Modify `lib/ui/terminal_screen.dart`

- [ ] **Step 1: Paste the primary on a middle-click**

In `onPointerDown`, after the selection branch and before the mouse-report fallback, handle a middle click when the app is not grabbing the mouse:
```dart
                if (!anyMouse(_grid.modeFlags) &&
                    e.buttons & kMiddleMouseButton != 0 &&
                    _primary.isNotEmpty) {
                  _pty?.write(pasteBytes(_primary, modeFlags: _grid.modeFlags));
                  return;
                }
```
(`_primary` is set on selection finalize in D2.3; `pasteBytes` is B3's encoder, already imported.)

- [ ] **Step 2: Verify analysis + tests**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 3: Manual check + commit**

`flutter run -d linux`: select some text, then middle-click elsewhere — the selection is pasted (bracketed if the app enabled it). Then:
```bash
git add lib/ui/terminal_screen.dart
git commit -m "feat(ui): middle-click pastes the in-app primary selection"
```

---
---

## Task FINAL: Acceptance gate + findings

**Files:** Create `docs/superpowers/plans/2026-05-27-plan2d-findings.md`

- [ ] **Step 1: Build + run**

```bash
cd rust && cargo build && cd ..
flutter run -d linux
```

- [ ] **Step 2: Acceptance checklist**
- [ ] D1: wheel scrolls back through long output; a keypress snaps to bottom; `less`/vim wheel scrolls the pager; cursor hidden while scrolled.
- [ ] D2: drag-select highlights; double-click = word, triple = line; `Ctrl+Shift+C` copies (paste elsewhere matches, incl. a selection spanning scrollback); typing clears it.
- [ ] D3: select then middle-click pastes the selection (multi-line is bracketed under apps that enabled it).

- [ ] **Step 3: Record findings + commit**

Create `docs/superpowers/plans/2026-05-27-plan2d-findings.md` capturing checklist results, selection-highlight color tuning, any `display_iter`/range edge cases (wide chars in selection, selection across resize), and carry-over for E (robustness) / future search. Then:
```bash
git add docs/superpowers/plans/2026-05-27-plan2d-findings.md
git commit -m "docs: Plan 2D acceptance findings"
```

---

## Self-Review (completed by author)

- **Spec coverage:** D1 offset-aware render + scroll (D1.1) + FRB/Dart wiring (D1.2) + wheel/keys/alt-screen (D1.3); D2 Rust selection + FLAG_SELECTED (D2.1) + FRB/flags/painter (D2.2) + pointer/click-count/copy/clear (D2.3); D3 middle-click primary paste (D3.1); acceptance (FINAL). All §3–§5 of the spec mapped.
- **Placeholder scan:** none — complete code/commands throughout; APIs pre-verified against alacritty source (Scroll, point_to_viewport/viewport_to_point, Selection, SelectionType, Side, selection_to_string).
- **Type consistency:** `RenderUpdate.display_offset:u32` (Rust) → `displayOffset` (FRB/GridUpdate/MirrorGrid), consistent D1.1→D1.2. `engine_scroll_lines/to_bottom` ↔ binding `scrollLines/scrollToBottom` ↔ client `scrollLines/scrollToBottom` ↔ screen calls. `engine_selection_start/update/clear/text(display_row,col,right_half,kind)` ↔ binding `selectionStart/Update/Clear/Text(displayRow,col,rightHalf,kind)` ↔ screen calls, consistent D2.1→D2.2→D2.3. `FLAG_SELECTED=1<<8` (Rust) ↔ `kFlagSelected=1<<8` (Dart), next free bit after `kFlagStrikeout=1<<7`. `kind`: 0 simple / 1 semantic / 2 lines, consistent between `sel_type` (Rust) and the click-count mapping (`_clickCount-1`, D2.3). `binding` getter on the client used by D2.3/D3.1. `_primary` set in D2.3, read in D3.1.
```
