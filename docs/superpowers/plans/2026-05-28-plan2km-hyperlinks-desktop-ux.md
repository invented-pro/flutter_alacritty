# flutter_alacritty Plan 2K·2M — Hyperlinks & Desktop UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make typical desktop workflow feel natural — click hyperlinks (OSC 8 and auto-detected URLs), zoom font with `Ctrl+=`/`Ctrl+-`/`Ctrl+0`, drag-drop files to insert paths, right-click for a gnome-terminal-style context menu, and see a visual bell.

**Architecture:** Five independent phases on one branch, each its own commit. Phase 1 (hyperlinks) reuses 2G's `RegexIter` for URL auto-detect and 2F's additive config schema for hint colors; an interned URI table on the engine keeps the FFI payload small. Phases 2-5 are Dart-only desktop UX additions layered onto the existing `Listener`+`GestureDetector` split — no protocol change.

**Tech Stack:** Rust (`alacritty_terminal` Hyperlink + RegexSearch), flutter_rust_bridge 2.12, Flutter/Dart, `url_launcher: ^6.3.0`, `desktop_drop: ^0.4.4`.

**Spec:** `docs/superpowers/specs/2026-05-28-plan2km-hyperlinks-desktop-ux-design.md`
**Branch:** `feature/km-hyperlinks-desktop-ux` off `main` @ `38e46ae`.

**Verified facts:**
- Project recently restructured (`9bb41e5` + follow-ups): Rust lives at `packages/rust_lib_flutter_alacritty/rust/src/`. FRB config at `flutter_rust_bridge.yaml` (`rust_root: packages/rust_lib_flutter_alacritty/rust/`). Spec uses old paths; this plan uses the current ones.
- `alacritty_terminal::term::cell::Cell::hyperlink() -> Option<Hyperlink>`; `Hyperlink::uri()`/`id()`; OSC 8 is parsed by the vte processor we already use.
- `RegexSearch::new(&str) -> Result<RegexSearch, Box<BuildError>>` (`Clone`, owns DFAs); `RegexIter::new(start, end, Direction::Right, &Term, &mut RegexSearch)`.
- Existing `engine_full_snapshot_searched(&mut self)` is the natural place to add the hint pass (already `&mut self`, already iterates the visible region for matches).
- Existing `CellData { codepoint, fg, bg, flags }` — adding `hyperlink_id: u32` grows it by 4 bytes per cell.
- `GlyphCache._cache` is a `LinkedHashMap<int, ui.Paragraph>` (no current dispose).
- `Listener.onPointerDown` already exists with `event.kind == mouse` guard; we add Ctrl+click (hyperlink) and right-click (menu) branches.
- Baseline: 96/96 flutter tests, 24/24 cargo tests, analyze clean. After any Rust/FRB change rebuild dylib with `flutter build linux --debug` before `flutter test` (2F lesson).

---

## File Structure

```
PHASE 1 (hyperlinks) — Tasks 1-3
  packages/rust_lib_flutter_alacritty/rust/src/engine.rs
    +hyperlinks Vec<String>, hyperlink_ids HashMap, hint_regex RegexSearch
    +FLAG_HYPERLINK, +intern_hyperlink helper, +point_in_match reused for hint range
    cell_data() sets hyperlink_id from cell.hyperlink()
    full_snapshot_searched() adds hint pass (RegexIter over visible region)
    +resolve_hyperlink(id) -> Option<String>
  packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs
    +engine_resolve_hyperlink (sync, regen FRB)
  lib/src/rust/**                                     (regen)
  lib/render/cell_flags.dart                          kFlagHyperlink + isHyperlink
  lib/render/mirror_grid.dart                         +hyperlinkId Int32List lane
  lib/render/terminal_painter.dart                    hyperlink underline + hint-color override
  lib/config/terminal_config.dart                     +TerminalColors.hintStartFg/Bg, fromTomlString reads [colors.hints.start]
  lib/engine/engine_binding.dart                      resolveHyperlink passthrough
  lib/engine/terminal_engine_client.dart              resolveHyperlink passthrough
  lib/ui/terminal_screen.dart                         MouseRegion (cursor=click on hyperlink cell) + Ctrl+click handler
  pubspec.yaml                                        +url_launcher: ^6.3.0
PHASE 2 (font zoom) — Task 4
  lib/render/glyph_cache.dart                         +dispose() that clears _cache
  lib/ui/terminal_screen.dart                         _fontSize state, _rebuildMetrics(), Ctrl+=/-/0 in _onKey
PHASE 3 (drag-drop) — Task 5
  lib/ui/terminal_screen.dart                         DropTarget(onDragDone:) wrapping + _onDrop + _shellQuote
  pubspec.yaml                                        +desktop_drop: ^0.4.4
PHASE 4 (right-click menu) — Task 6
  lib/ui/terminal_screen.dart                         _showContextMenu via showMenu, conditional items
PHASE 5 (visual bell) — Task 7
  lib/config/terminal_config.dart                     +BellConfig{color,duration,animation}, defaults, fromTomlString
  lib/ui/terminal_screen.dart                         SingleTickerProviderStateMixin + _bellCtrl + FadeTransition overlay
ACCEPTANCE — Task 8
  flutter_alacritty.toml.example                      document [colors.hints.start] and [bell]
  docs/superpowers/plans/2026-05-28-plan2km-findings.md  NEW
```

---

## Task 0: Branch

- [ ] **Step 1: Create the feature branch**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git checkout main && git checkout -b feature/km-hyperlinks-desktop-ux
git rev-parse --abbrev-ref HEAD   # expect: feature/km-hyperlinks-desktop-ux
```

---

# PHASE 1 — Hyperlinks (2K)

## Task 1: Rust engine — hyperlink interning + auto-detect + resolve

**Files:**
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/engine.rs`
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs`
- Regen: `packages/rust_lib_flutter_alacritty/rust/src/frb_generated.rs`, `lib/src/rust/**`

- [ ] **Step 1: Write the failing tests** — append to the `tests` module in `packages/rust_lib_flutter_alacritty/rust/src/engine.rs`:

```rust
    #[test]
    fn osc8_hyperlink_is_carried_on_cell_data() {
        let mut e = engine(20, 3);
        // OSC 8: ESC ] 8 ; id ; uri ESC \ TEXT ESC ] 8 ; ; ESC \
        e.advance(b"\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\".to_vec());
        let u = e.full_snapshot_searched();
        let cell = &u.lines[0].cells[0];
        assert_ne!(cell.flags & FLAG_HYPERLINK, 0);
        assert_ne!(cell.hyperlink_id, 0);
        assert_eq!(e.resolve_hyperlink(cell.hyperlink_id).as_deref(),
                   Some("https://example.com"));
    }

    #[test]
    fn url_auto_detect_marks_visible_region() {
        let mut e = engine(40, 3);
        e.advance(b"see https://x.io/p next".to_vec());
        let u = e.full_snapshot_searched();
        // 'see ' = 4 chars; URL starts at col 4 ('h')
        let cell = &u.lines[0].cells[4];
        assert_ne!(cell.flags & FLAG_HYPERLINK, 0);
        assert_ne!(cell.hyperlink_id, 0);
        let uri = e.resolve_hyperlink(cell.hyperlink_id).unwrap();
        assert!(uri.starts_with("https://x.io/p"), "uri was {uri:?}");
        // ' next' = trailing spaces and word — NOT hyperlinked
        assert_eq!(u.lines[0].cells[2].flags & FLAG_HYPERLINK, 0);
    }

    #[test]
    fn resolve_hyperlink_returns_none_for_unknown_id() {
        let e = engine(10, 3);
        assert!(e.resolve_hyperlink(0).is_none());
        assert!(e.resolve_hyperlink(999).is_none());
    }

    #[test]
    fn osc8_wins_over_auto_detect_when_both_apply() {
        // A cell carrying OSC 8 with one URI shouldn't get a different id from
        // the auto-detect pass — OSC 8 is set first in cell_data, hint pass
        // must skip cells that already carry FLAG_HYPERLINK.
        let mut e = engine(40, 3);
        e.advance(
            b"\x1b]8;;https://osc8.example\x1b\\https://other.example\x1b]8;;\x1b\\".to_vec()
        );
        let u = e.full_snapshot_searched();
        let cell = &u.lines[0].cells[0];
        assert_eq!(e.resolve_hyperlink(cell.hyperlink_id).as_deref(),
                   Some("https://osc8.example"));
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
cd packages/rust_lib_flutter_alacritty/rust && cargo test hyperlink 2>&1 | tail -20
```
Expected: FAIL — `FLAG_HYPERLINK` / `hyperlink_id` / `resolve_hyperlink` not defined.

- [ ] **Step 3: Add the flag constant + imports** — in `packages/rust_lib_flutter_alacritty/rust/src/engine.rs`, near the existing flag consts:

```rust
pub const FLAG_HYPERLINK: u16 = 1 << 11;
```

and add at top:

```rust
use std::collections::HashMap;
```

(the rest of imports already cover `RegexSearch`/`RegexIter`/`Direction`.)

- [ ] **Step 4: Add `hyperlink_id` to `CellData`** — find the `CellData` struct and add the field:

```rust
#[derive(Debug, Clone)]
pub struct CellData {
    pub codepoint: u32,
    pub fg: u32,
    pub bg: u32,
    pub flags: u16,
    pub hyperlink_id: u32,
}
```

Also update any inline literal constructions of `CellData` (search for `CellData {` — there's likely a default cell or test helper):

```bash
grep -n "CellData {" packages/rust_lib_flutter_alacritty/rust/src/engine.rs
```

Add `hyperlink_id: 0,` to each.

- [ ] **Step 5: Extend `TerminalEngine` state** — change the struct and `new()`:

```rust
pub struct TerminalEngine {
    term: Term<EventProxy>,
    parser: Processor,
    events: EventQueue,
    palette: [u32; 18],
    search: Option<RegexSearch>,
    current_match: Option<Match>,
    hyperlinks: Vec<String>,           // index = id - 1; id 0 = none
    hyperlink_ids: HashMap<String, u32>,
    hint_regex: Option<RegexSearch>,   // fixed URL pattern, None if compilation failed (shouldn't)
}
```

In `TerminalEngine::new(...)`, after the existing field initializations, add:

```rust
        let hint_regex = RegexSearch::new(r"(?:https?|ftp|file)://[^\s]+").ok();
```

and include in the constructed value:

```rust
            hyperlinks: Vec::new(),
            hyperlink_ids: HashMap::new(),
            hint_regex,
```

- [ ] **Step 6: Add the intern helper + resolve** — inside `impl TerminalEngine`, near `search_clear`:

```rust
    fn intern_hyperlink(&mut self, uri: &str) -> u32 {
        if let Some(&id) = self.hyperlink_ids.get(uri) {
            return id;
        }
        // ids start at 1; 0 is reserved for "no hyperlink".
        let id = self.hyperlinks.len() as u32 + 1;
        self.hyperlinks.push(uri.to_owned());
        self.hyperlink_ids.insert(uri.to_owned(), id);
        id
    }

    pub fn resolve_hyperlink(&self, id: u32) -> Option<String> {
        if id == 0 { return None; }
        self.hyperlinks.get((id - 1) as usize).cloned()
    }
```

- [ ] **Step 7: Set `hyperlink_id` from OSC 8 in `cell_data`** — currently `cell_data` is `&self`, but we need `&mut self` to intern. Change the signature and update both callers (`line_cells` and `full_snapshot`'s `display_iter` loop). Existing:

```rust
    fn cell_data(&self, cell: &Cell) -> CellData {
```

Change to (and use `cell.hyperlink()`):

```rust
    fn cell_data(&mut self, cell: &Cell) -> CellData {
        let (hyperlink_id, hyperlink_flag) = match cell.hyperlink() {
            Some(h) => (self.intern_hyperlink(h.uri()), FLAG_HYPERLINK),
            None => (0, 0),
        };
        CellData {
            codepoint: cell.c as u32,
            fg: self.resolve_color(cell.fg, true),
            bg: self.resolve_color(cell.bg, false),
            flags: map_flags(cell.flags) | hyperlink_flag,
            hyperlink_id,
        }
    }
```

`line_cells` already takes `&self` — change to `&mut self`:

```rust
    fn line_cells(&mut self, row: usize) -> Vec<CellData> {
        let grid = self.term.grid();
        let cols = grid.columns();
        // Collect borrowed cells first to release &self.term before &mut self for cell_data.
        let cells_ref: Vec<Cell> = (0..cols).map(|c| grid[Line(row as i32)][Column(c)].clone()).collect();
        cells_ref.iter().map(|c| self.cell_data(c)).collect()
    }
```

(The temporary `Vec<Cell>` decouples the immutable `&self.term` borrow from the `&mut self` cell_data call. `Cell` is `Clone`.)

Similarly, change `full_snapshot` from `&self` to `&mut self` for the same reason. Its `display_iter` loop calls `self.cell_data(indexed.cell)`. Update the signature:

```rust
    pub fn full_snapshot(&mut self) -> RenderUpdate {
```

The `display_iter` borrow is released after the loop collects; the existing structure already collects into `lines` so refactor minimally — collect points-and-cells first:

```rust
        let collected: Vec<(usize, usize, Cell)> = {
            let grid = self.term.grid();
            let mut out = Vec::new();
            for indexed in grid.display_iter() {
                if let Some(vp) = point_to_viewport(display_offset, indexed.point) {
                    if vp.line < rows && vp.column.0 < cols {
                        out.push((vp.line, vp.column.0, indexed.cell.clone()));
                    }
                }
            }
            out
        };
        for (vline, vcol, cell_ref) in collected {
            let mut cd = self.cell_data(&cell_ref);
            if let Some(r) = &sel {
                // re-check selection membership using the absolute point
                let p = viewport_to_point(display_offset, Point::new(vline, Column(vcol)));
                if point_in_range(p, r) {
                    cd.flags |= FLAG_SELECTED;
                }
            }
            lines[vline].cells[vcol] = cd;
        }
```

(Update the surrounding `let sel = ...` block to compute `sel` BEFORE the collected block to keep the immutable borrow scope clean.)

The `blank` CellData literal needs `hyperlink_id: 0,` added.

- [ ] **Step 8: Add the hint pass in `full_snapshot_searched`** — append to the existing function, AFTER the search-match loop. We iterate visible region matches with the hint regex, intern each URI, and OR `FLAG_HYPERLINK` + id onto cells that don't already carry OSC 8 hyperlinks (precedence: OSC 8 wins):

```rust
    pub fn full_snapshot_searched(&mut self) -> RenderUpdate {
        let mut update = self.full_snapshot();
        // existing search-match pass (keep as-is) ...

        // Hint pass: URL auto-detect over the visible region. OSC 8 cells
        // already carry FLAG_HYPERLINK from cell_data — skip them so OSC 8 wins.
        if let Some(hint) = self.hint_regex.as_mut() {
            let off = self.term.grid().display_offset();
            let rows = self.term.screen_lines();
            let cols = self.term.columns();
            let top = viewport_to_point(off, Point::new(0, Column(0)));
            let bottom = viewport_to_point(off, Point::new(rows - 1, Column(cols - 1)));
            let matches: Vec<Match> =
                RegexIter::new(top, bottom, Direction::Right, &self.term, hint).collect();
            // Build URI strings from each match by walking cells; intern after the
            // immutable term borrow ends.
            let uris_for_matches: Vec<String> = matches.iter().map(|m| {
                let mut s = String::new();
                let grid = self.term.grid();
                let (start, end) = (m.start(), m.end());
                let mut line = start.line;
                while line <= end.line {
                    let col_start = if line == start.line { start.column.0 } else { 0 };
                    let col_end = if line == end.line { end.column.0 } else { grid.columns() - 1 };
                    for c in col_start..=col_end {
                        s.push(grid[line][Column(c)].c);
                    }
                    line = Line(line.0 + 1);
                }
                s
            }).collect();
            for (m, uri) in matches.iter().zip(uris_for_matches.into_iter()) {
                let id = self.intern_hyperlink(&uri);
                for line in update.lines.iter_mut() {
                    for col in 0..line.cells.len() {
                        if line.cells[col].flags & FLAG_HYPERLINK != 0 { continue; }
                        let p = viewport_to_point(
                            off, Point::new(line.line as usize, Column(col)));
                        if point_in_match(p, m) {
                            line.cells[col].flags |= FLAG_HYPERLINK;
                            line.cells[col].hyperlink_id = id;
                        }
                    }
                }
            }
        }
        update
    }
```

(`Line(line.0 + 1)` increments a `Line`; verify the `Line` type supports `.0` and arithmetic — it does in alacritty's index module: `Line(i32)`.)

- [ ] **Step 9: Add FRB surface** — in `packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs`, add after the existing search fns:

```rust
#[frb(sync)]
pub fn engine_resolve_hyperlink(engine: &TerminalEngine, id: u32) -> Option<String> {
    std::panic::catch_unwind(AssertUnwindSafe(|| engine.resolve_hyperlink(id)))
        .unwrap_or(None)
}
```

- [ ] **Step 10: Run Rust tests**

```bash
cd packages/rust_lib_flutter_alacritty/rust && cargo test 2>&1 | tail -12
```
Expected: all pass (the 4 new + existing 24). If borrow errors fire on `cell_data` / `line_cells`, double-check the `&mut self` conversion and the temporary `Vec<Cell>` collection (Cell impls Clone).

- [ ] **Step 11: Regenerate FRB + rebuild dylib**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen generate 2>&1 | tail -8
grep -n "hyperlinkId\|engineResolveHyperlink" lib/src/rust/api/terminal.dart lib/src/rust/engine.dart | head
flutter build linux --debug 2>&1 | tail -3
```
Expected: regenerated; `CellData.hyperlinkId` and `engineResolveHyperlink` appear; dylib rebuilt.

- [ ] **Step 12: Commit**

```bash
git add packages/rust_lib_flutter_alacritty/rust/src/engine.rs \
        packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs \
        packages/rust_lib_flutter_alacritty/rust/src/frb_generated.rs \
        lib/src/rust
git commit -m "feat(rust): hyperlinks — OSC 8 + URL auto-detect + interned URI table

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

## Task 2: Dart flag + grid lane + painter + hint colors

**Files:**
- Modify: `lib/render/cell_flags.dart`
- Modify: `lib/render/mirror_grid.dart`
- Modify: `lib/render/terminal_painter.dart`
- Modify: `lib/config/terminal_config.dart`
- Test: `test/terminal_config_test.dart`, `test/mirror_grid_test.dart`, `test/terminal_painter_test.dart`

- [ ] **Step 1: Write the failing Dart tests** — append to `test/terminal_config_test.dart`:

```dart
  test('hint start colors default to alacritty values', () {
    final c = TerminalConfig.defaults().colors;
    expect(c.hintStartBg, 0xF4BF75);
    expect(c.hintStartFg, 0x181818);
  });

  test('fromTomlString reads [colors.hints.start]', () {
    const toml = '''
[colors.hints.start]
background = "#abcdef"
foreground = "#012345"
''';
    final c = TerminalConfig.fromTomlString(toml).colors;
    expect(c.hintStartBg, 0xABCDEF);
    expect(c.hintStartFg, 0x012345);
  });
```

Append to `test/mirror_grid_test.dart`:

```dart
  test('hyperlinkId lane round-trips through apply', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 1, columns: 3,
      lines: [LineCells(
        line: 0,
        codepoints: Int32List.fromList([0x41, 0x42, 0x43]),
        fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8, 0xD8D8D8]),
        bg: Int32List.fromList([0x181818, 0x181818, 0x181818]),
        flags: Uint16List.fromList([0, kFlagHyperlink, kFlagHyperlink]),
        hyperlinkId: Int32List.fromList([0, 7, 7]),
      )],
      cursorRow: 0, cursorCol: 0, cursorVisible: false,
    ));
    expect(g.hyperlinkIdAt(0, 0), 0);
    expect(g.hyperlinkIdAt(0, 1), 7);
    expect(g.hyperlinkIdAt(0, 2), 7);
  });
```

Append to `test/terminal_painter_test.dart`:

```dart
  group('applySearchOverride precedence with hyperlink', () {
    const search = SearchColors(
      matchBg: 0xAC4242, matchFg: 0x181818, focusedBg: 0xF4BF75, focusedFg: 0x181818);
    const hint = HintColors(bg: 0xF4BF75, fg: 0x181818);
    const base = (fg: 0xD8D8D8, bg: 0x222222);
    test('FLAG_HYPERLINK alone uses hint colors', () {
      final r = applyMatchOrHint(kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xF4BF75);
    });
    test('FLAG_MATCH wins over FLAG_HYPERLINK', () {
      final r = applyMatchOrHint(kFlagMatch | kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xAC4242);
    });
    test('FLAG_MATCH_CURRENT wins over both', () {
      final r = applyMatchOrHint(
          kFlagMatchCurrent | kFlagMatch | kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xF4BF75); // focused matches background
    });
  });
```

- [ ] **Step 2: Run to verify failures**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter test test/terminal_config_test.dart test/mirror_grid_test.dart test/terminal_painter_test.dart 2>&1 | tail -12
```
Expected: FAIL — `hintStartBg`, `kFlagHyperlink`, `hyperlinkId`, `HintColors`, `applyMatchOrHint` undefined.

- [ ] **Step 3: Add flag** — in `lib/render/cell_flags.dart`, after `kFlagMatchCurrent`:

```dart
const int kFlagHyperlink = 1 << 11;

bool isHyperlink(int flags) => flags & kFlagHyperlink != 0;
```

- [ ] **Step 4: Add `hyperlinkId` lane to `MirrorGrid`** — in `lib/render/mirror_grid.dart`:

`LineCells` ctor + field:
```dart
class LineCells {
  LineCells({
    required this.line,
    required this.codepoints,
    required this.fg,
    required this.bg,
    required this.flags,
    Int32List? hyperlinkId,
  }) : hyperlinkId = hyperlinkId ?? Int32List(codepoints.length);

  final int line;
  final Int32List codepoints;
  final Int32List fg;
  final Int32List bg;
  final Uint16List flags;
  final Int32List hyperlinkId;
}
```

`MirrorGrid` fields + accessor + ensure-size + apply:
```dart
  List<Int32List> _hyperlinkId = [];

  int hyperlinkIdAt(int row, int col) => _hyperlinkId[row][col];
```

In `_ensureSize`, after the existing `_flags = ...`:
```dart
    _hyperlinkId = List.generate(rows, (_) => Int32List(columns)); // zero-filled
```

In `apply()`, inside the per-line loop, after the existing `_flags[l.line].setRange(...)`:
```dart
      _hyperlinkId[l.line].setRange(0, copy, l.hyperlinkId);
```

- [ ] **Step 5: Update `FrbEngineBinding._lineCells` to forward the lane** — in `lib/engine/engine_binding.dart`, in `_lineCells`:

```dart
  LineCells _lineCells(LineUpdate l) {
    final n = l.cells.length;
    final codepoints = Int32List(n);
    final fg = Int32List(n);
    final bg = Int32List(n);
    final flags = Uint16List(n);
    final hyperlinkId = Int32List(n);
    for (var i = 0; i < n; i++) {
      final c = l.cells[i];
      codepoints[i] = c.codepoint;
      fg[i] = c.fg;
      bg[i] = c.bg;
      flags[i] = c.flags;
      hyperlinkId[i] = c.hyperlinkId;
    }
    return LineCells(line: l.line, codepoints: codepoints, fg: fg, bg: bg,
        flags: flags, hyperlinkId: hyperlinkId);
  }
```

- [ ] **Step 6: Add `hintStart*` to `TerminalColors`** — in `lib/config/terminal_config.dart`, extend the `TerminalColors` class (constructor params, fields, `copyWith`, and the `defaults()` factory literal):

Add to constructor:
```dart
    required this.hintStartFg,
    required this.hintStartBg,
```

Add fields:
```dart
  final int hintStartFg;
  final int hintStartBg;
```

Extend `copyWith` with the two params (mirror existing pattern).

In `TerminalConfig.defaults()`'s `TerminalColors(...)`, add the two fields:
```dart
          hintStartFg: 0x181818,
          hintStartBg: 0xF4BF75,
```

In `fromTomlString`'s color parsing, after the existing `final searchM = section(colorsM, 'search');` line, add:
```dart
    final hintsM = section(colorsM, 'hints');
    final hintStartM = section(hintsM, 'start');
```

In the returned `TerminalColors(...)`, add:
```dart
        hintStartFg: color(hintStartM, 'foreground', d.colors.hintStartFg),
        hintStartBg: color(hintStartM, 'background', d.colors.hintStartBg),
```

- [ ] **Step 7: Add `HintColors` + `applyMatchOrHint` + painter usage** — in `lib/render/terminal_painter.dart`, near `SearchColors`:

```dart
/// Background/foreground for hint-highlighted (hyperlink) cells.
class HintColors {
  const HintColors({required this.bg, required this.fg});
  final int bg;
  final int fg;
}

/// Effective fg/bg with full precedence: focused-match > match > hyperlink > base.
({int fg, int bg}) applyMatchOrHint(
    int flags, ({int fg, int bg}) ec, SearchColors search, HintColors hint) {
  if (flags & kFlagMatchCurrent != 0) {
    return (fg: search.focusedFg, bg: search.focusedBg);
  }
  if (flags & kFlagMatch != 0) {
    return (fg: search.matchFg, bg: search.matchBg);
  }
  if (flags & kFlagHyperlink != 0) {
    return (fg: hint.fg, bg: hint.bg);
  }
  return ec;
}
```

Add `hintColors` field + ctor param to `TerminalPainter`:
```dart
    required this.hintColors,
```
```dart
  final HintColors hintColors;
```

Replace the existing `_withSearch` callsites (both Pass 1 bg and Pass 2 fg blocks) to use `applyMatchOrHint`:
```dart
        final ec = applyMatchOrHint(
          grid.flagsAt(row, col),
          effectiveColors(
            grid.flagsAt(row, col),
            grid.fgAt(row, col),
            grid.bgAt(row, col),
          ),
          searchColors,
          hintColors,
        );
```

Add the hyperlink underline in Pass 2 — when a cell has `kFlagHyperlink` but not already an `kFlagUnderline`, draw the same underline that `kFlagUnderline` draws (a stroke at `decorationYs(y, cellHeight).underline`):
```dart
        if (flags & (kFlagUnderline | kFlagStrikeout | kFlagHyperlink) != 0) {
          final x = col * cellWidth;
          final decoPaint = Paint()
            ..color = fg
            ..strokeWidth = lineWidth;
          final ys = decorationYs(y, cellHeight);
          if (flags & (kFlagUnderline | kFlagHyperlink) != 0) {
            canvas.drawLine(
              Offset(x, ys.underline),
              Offset(x + cellWidth, ys.underline),
              decoPaint,
            );
          }
          if (flags & kFlagStrikeout != 0) {
            canvas.drawLine(
              Offset(x, ys.strikeout),
              Offset(x + cellWidth, ys.strikeout),
              decoPaint,
            );
          }
        }
```

Delete the now-unused private `_withSearch` method.

- [ ] **Step 8: Pass `hintColors` from the screen** — in `lib/ui/terminal_screen.dart`, find the `TerminalPainter(...)` construction (where `searchColors` is passed) and add:

```dart
                      searchColors: SearchColors(
                        matchBg: _config.colors.searchMatchBg,
                        matchFg: _config.colors.searchMatchFg,
                        focusedBg: _config.colors.searchFocusedBg,
                        focusedFg: _config.colors.searchFocusedFg,
                      ),
                      hintColors: HintColors(
                        bg: _config.colors.hintStartBg,
                        fg: _config.colors.hintStartFg,
                      ),
```

- [ ] **Step 9: Update the engine_bindings_test to assert the new lane** — open `test/engine_bindings_test.dart` and add to the existing search round-trip test or a new test that the `CellData` from a real OSC 8 sequence carries `hyperlinkId != 0`. Skip if the test already exercises hyperlinks via the new Rust unit tests (Step 1 of Task 1).

- [ ] **Step 10: Run all suites**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -2
```
Expected: analyze clean; tests pass (new 3 added). If `_withSearch` removal breaks other callers, the painter test's `applySearchOverride` group still passes because it now calls `applyMatchOrHint`.

- [ ] **Step 11: Commit**

```bash
git add lib/render/cell_flags.dart lib/render/mirror_grid.dart \
        lib/render/terminal_painter.dart lib/config/terminal_config.dart \
        lib/engine/engine_binding.dart lib/ui/terminal_screen.dart \
        test/cell_flags_test.dart test/mirror_grid_test.dart \
        test/terminal_painter_test.dart test/terminal_config_test.dart
git commit -m "feat(render): hyperlink underline + hint colors with full match precedence

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

## Task 3: Click handler + url_launcher + MouseRegion

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/engine/engine_binding.dart`
- Modify: `lib/engine/terminal_engine_client.dart`
- Modify: `lib/ui/terminal_screen.dart`
- Test: `test/terminal_lifecycle_test.dart`

- [ ] **Step 1: Add the url_launcher dependency**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter pub add url_launcher 2>&1 | tail -3
grep "url_launcher" pubspec.yaml
```
Expected: `url_launcher: ^6.x.x` under `dependencies`.

- [ ] **Step 2: Write the failing widget test** — append to `test/terminal_lifecycle_test.dart`. The fake binding gets `resolveHyperlink` + a launcher seam:

```dart
  testWidgets('Ctrl+left-click on a hyperlink cell launches the URI', (tester) async {
    final title = ValueNotifier<String>('t');
    final binding = _FakeBinding()
      ..hyperlinkAt[(0, 0)] = 5
      ..hyperlinkUris[5] = 'https://example.com';
    String? launched;
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => binding,
      launchUrl: (u) async { launched = u; return true; },
    )));
    await tester.pump();
    // Simulate Ctrl held + click at the top-left cell.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(tester.getTopLeft(find.byType(CustomPaint).first) + const Offset(2, 2));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(launched, 'https://example.com');
    title.dispose();
  });
```

Extend `_FakeBinding` to support `hyperlinkAt`/`hyperlinkUris` (also stub the `MirrorGrid`'s `hyperlinkIdAt` view by injecting a real snapshot from the binding):

```dart
class _FakeBinding implements EngineBinding {
  // existing fields kept...
  final Map<(int, int), int> hyperlinkAt = {};
  final Map<int, String> hyperlinkUris = {};
  @override String? resolveHyperlink(int id) => hyperlinkUris[id];
  @override GridUpdate fullSnapshotSearched() {
    // Build a 1-row full snapshot with hyperlinkAt populated; for simplicity
    // emit one line of spaces with hyperlinkId set on the seeded cells.
    const cols = 80, rows = 24;
    final hyperlinks = Int32List(cols);
    final flags = Uint16List(cols);
    hyperlinkAt.forEach((rc, id) {
      if (rc.$1 == 0 && rc.$2 < cols) {
        hyperlinks[rc.$2] = id;
        flags[rc.$2] = 1 << 11; // kFlagHyperlink
      }
    });
    final line0 = LineCells(
      line: 0,
      codepoints: Int32List(cols)..fillRange(0, cols, 32),
      fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
      bg: Int32List(cols)..fillRange(0, cols, 0x181818),
      flags: flags,
      hyperlinkId: hyperlinks,
    );
    final blank = (i) => LineCells(
      line: i,
      codepoints: Int32List(cols)..fillRange(0, cols, 32),
      fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
      bg: Int32List(cols)..fillRange(0, cols, 0x181818),
      flags: Uint16List(cols),
      hyperlinkId: Int32List(cols),
    );
    return GridUpdate(
      full: true, rows: rows, columns: cols,
      lines: [line0, for (var i = 1; i < rows; i++) blank(i)],
      cursorRow: 0, cursorCol: 0, cursorVisible: false,
    );
  }
  // other methods unchanged...
}
```

- [ ] **Step 3: Run to verify failure**

```bash
flutter test test/terminal_lifecycle_test.dart --plain-name "Ctrl+left-click on a hyperlink" 2>&1 | tail -10
```
Expected: FAIL — `TerminalScreen` has no `launchUrl` parameter; `EngineBinding` has no `resolveHyperlink`.

- [ ] **Step 4: Add `resolveHyperlink` to the binding** — in `lib/engine/engine_binding.dart`, add to the abstract class:

```dart
  String? resolveHyperlink(int id);
```

In `FrbEngineBinding`:
```dart
  @override
  String? resolveHyperlink(int id) =>
      engineResolveHyperlink(engine: _engine, id: id);
```

(Add the import for `engineResolveHyperlink` if not auto-resolved.)

- [ ] **Step 5: Add passthrough on the client** — in `lib/engine/terminal_engine_client.dart`:

```dart
  String? resolveHyperlink(int id) => _binding.resolveHyperlink(id);
```

- [ ] **Step 6: Add `launchUrl` seam + Ctrl+click handler in TerminalScreen** — in `lib/ui/terminal_screen.dart`:

Add to imports:
```dart
import 'package:url_launcher/url_launcher.dart' as launcher;
```

Add a typedef + widget param:
```dart
typedef UrlLauncher = Future<bool> Function(String url);

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    required this.title,
    this.ptyFactory,
    this.engineFactory,
    this.config,
    this.launchUrl,
    super.key,
  });
  ...
  final UrlLauncher? launchUrl;
}
```

In `_TerminalScreenState`, default the launcher to the real `url_launcher`:
```dart
  late final UrlLauncher _launch = widget.launchUrl ??
      (u) async => launcher.launchUrl(Uri.parse(u));
```

In `Listener.onPointerDown` (after the `if (e.kind != PointerDeviceKind.mouse) return;` guard and the `_restart` guard), before the existing `localSelect` logic, add:

```dart
                final hw = HardwareKeyboard.instance;
                // Ctrl + left-click on a hyperlink cell → launch URI.
                if (hw.isControlPressed && e.buttons & kPrimaryButton != 0) {
                  final (r, c, _) = _cellAt(e.localPosition);
                  if (_client != null && isHyperlink(_grid.flagsAt(r, c))) {
                    final id = _grid.hyperlinkIdAt(r, c);
                    final uri = _client!.resolveHyperlink(id);
                    if (uri != null) {
                      _launch(uri);
                      return;
                    }
                  }
                }
```

Wrap the existing `CustomPaint(...)` in a `MouseRegion` that switches the cursor on a hyperlink cell. To know which cell the pointer is over without rebuilding on every move, set the cursor based on `_lastHover` updated in `onPointerHover`:

```dart
  MouseCursor _hoverCursor = MouseCursor.defer;

  void _updateHoverCursor(Offset local) {
    final (r, c, _) = _cellAt(local);
    final hyper = _grid.rows > r && _grid.columns > c &&
        isHyperlink(_grid.flagsAt(r, c));
    final next = hyper ? SystemMouseCursors.click : MouseCursor.defer;
    if (next != _hoverCursor) setState(() => _hoverCursor = next);
  }
```

Wrap CustomPaint:
```dart
                  MouseRegion(
                    cursor: _hoverCursor,
                    onHover: (e) => _updateHoverCursor(e.localPosition),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: TerminalPainter(
                        // ... existing args
                      ),
                    ),
                  ),
```

- [ ] **Step 7: Run the suite + analyze**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -2
```
Expected: analyze clean; tests pass (1 new). The `_FakeBinding` lacks `resolveHyperlink` if not updated above — confirm it has the new override.

- [ ] **Step 8: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/engine/engine_binding.dart \
        lib/engine/terminal_engine_client.dart lib/ui/terminal_screen.dart \
        test/terminal_lifecycle_test.dart
git commit -m "feat(ui): Ctrl+click hyperlinks + MouseRegion cursor + url_launcher

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

# PHASE 2 — Font zoom

## Task 4: Ctrl+/Ctrl-/Ctrl+0 zoom

**Files:**
- Modify: `lib/render/glyph_cache.dart`
- Modify: `lib/ui/terminal_screen.dart`
- Test: `test/glyph_cache_test.dart`, `test/terminal_lifecycle_test.dart`

- [ ] **Step 1: Write the failing glyph cache test** — append to `test/glyph_cache_test.dart`:

```dart
  test('dispose clears the cache', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    cache.tryGet(0x41, 0xFFFFFF);
    expect(cache.length, greaterThan(0));
    cache.dispose();
    expect(cache.length, 0);
  });
```

- [ ] **Step 2: Run to verify failure**

```bash
flutter test test/glyph_cache_test.dart 2>&1 | tail -5
```
Expected: FAIL — `dispose` not defined.

- [ ] **Step 3: Implement `dispose` on `GlyphCache`** — in `lib/render/glyph_cache.dart`, add:

```dart
  /// Clears the cached paragraphs. Call before rebuilding the cache with new
  /// font metrics (e.g. on font-zoom).
  void dispose() {
    _cache.clear();
    _buildsThisFrame = 0;
  }
```

- [ ] **Step 4: Verify cache test passes**

```bash
flutter test test/glyph_cache_test.dart 2>&1 | tail -3
```
Expected: PASS.

- [ ] **Step 5: Write the failing zoom widget test** — append to `test/terminal_lifecycle_test.dart`:

```dart
  testWidgets('Ctrl+= increases cellHeight, Ctrl+0 restores', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => _FakeBinding(),
    )));
    await tester.pump();
    double cellH() => tester
        .widget<CustomPaint>(find.byType(CustomPaint).first)
        .painter is TerminalPainter
            ? (tester.widget<CustomPaint>(find.byType(CustomPaint).first).painter
                as TerminalPainter).cellHeight
            : 0.0;
    final h0 = cellH();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(cellH(), greaterThan(h0));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(cellH(), h0);
    title.dispose();
  });
```

- [ ] **Step 6: Run to verify failure**

```bash
flutter test test/terminal_lifecycle_test.dart --plain-name "Ctrl+= increases" 2>&1 | tail -8
```
Expected: FAIL — zoom not implemented.

- [ ] **Step 7: Convert `_metrics`/`_glyphs` to rebuildable + add zoom state/handlers** — in `lib/ui/terminal_screen.dart`:

Convert the existing `late final CellMetrics _metrics`, `late final GlyphCache _glyphs`, and `late final MirrorGrid _grid` to `late` (no `final`):

```dart
  late double _fontSize = _config.font.size;
  late TextStyle _style = _config.textStyle.copyWith(fontSize: _fontSize);
  late CellMetrics _metrics = CellMetrics.measure(_style);
  late GlyphCache _glyphs = GlyphCache(
    fontFamily: _config.font.family,
    fontFamilyFallback: _config.font.fallback,
    fontSize: _fontSize,
    cellWidth: _metrics.width,
    lineHeight: _config.font.lineHeight,
  );
  late MirrorGrid _grid = MirrorGrid(
    defaultFg: _config.colors.foreground,
    defaultBg: _config.colors.background,
  );
```

Add the rebuild helper:
```dart
  void _setZoom(double next) {
    final clamped = next.clamp(6.0, 72.0);
    if (clamped == _fontSize) return;
    setState(() {
      _fontSize = clamped;
      _glyphs.dispose();
      _style = _config.textStyle.copyWith(fontSize: _fontSize);
      _metrics = CellMetrics.measure(_style);
      _glyphs = GlyphCache(
        fontFamily: _config.font.family,
        fontFamilyFallback: _config.font.fallback,
        fontSize: _fontSize,
        cellWidth: _metrics.width,
        lineHeight: _config.font.lineHeight,
      );
    });
  }
```

In `_onKey`, after the Ctrl+Shift+F branch, add the zoom intercepts:
```dart
    if (hw.isControlPressed && !hw.isShiftPressed && !hw.isAltPressed) {
      if (event.logicalKey == LogicalKeyboardKey.equal ||
          event.logicalKey == LogicalKeyboardKey.numpadAdd) {
        _setZoom(_fontSize + 1.0);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.minus ||
          event.logicalKey == LogicalKeyboardKey.numpadSubtract) {
        _setZoom(_fontSize - 1.0);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.digit0 ||
          event.logicalKey == LogicalKeyboardKey.numpad0) {
        _setZoom(_config.font.size);
        return KeyEventResult.handled;
      }
    }
```

- [ ] **Step 8: Run the suite**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -2
```
Expected: analyze clean; tests pass.

- [ ] **Step 9: Commit**

```bash
git add lib/render/glyph_cache.dart lib/ui/terminal_screen.dart \
        test/glyph_cache_test.dart test/terminal_lifecycle_test.dart
git commit -m "feat(ui): font zoom — Ctrl+=/Ctrl+-/Ctrl+0 rebuilds metrics + glyph cache

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

# PHASE 3 — Drag-and-drop

## Task 5: DropTarget with shell-quoted paths

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/ui/terminal_screen.dart`
- Test: `test/terminal_lifecycle_test.dart`

- [ ] **Step 1: Add the desktop_drop dependency**

```bash
flutter pub add desktop_drop 2>&1 | tail -3
grep "desktop_drop" pubspec.yaml
```
Expected: `desktop_drop: ^0.x.x` under dependencies.

- [ ] **Step 2: Write the failing test** — append to `test/terminal_lifecycle_test.dart` (use `desktop_drop`'s `DropDoneDetails`/`XFile`):

```dart
  testWidgets('drop writes shell-quoted, bracketed-paste-encoded paths', (tester) async {
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => _FakeBinding()..modeFlags = (1 << 4), // kModeBracketedPaste on
    )));
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    // Reach into the state via a test-only hook (see implementation step)
    (state as dynamic).simulateDrop([
      XFile('/tmp/plain'),
      XFile('/tmp/with space'),
    ]);
    await tester.pump();
    final bytes = pty.writes.expand((e) => e).toList();
    final written = String.fromCharCodes(bytes);
    expect(written.contains("\x1b[200~"), isTrue);     // bracketed-paste start
    expect(written.contains("/tmp/plain"), isTrue);
    expect(written.contains("'/tmp/with space'"), isTrue); // quoted
    expect(written.contains("\x1b[201~"), isTrue);     // bracketed-paste end
    title.dispose();
  });
```

(The test calls a `simulateDrop` exposed via `@visibleForTesting` to avoid wiring real DropTarget plumbing inside flutter_test.)

- [ ] **Step 3: Run to verify failure**

```bash
flutter test test/terminal_lifecycle_test.dart --plain-name "drop writes" 2>&1 | tail -8
```
Expected: FAIL — `simulateDrop` undefined.

- [ ] **Step 4: Implement `_shellQuote`, `_onDrop`, `simulateDrop`, and DropTarget wrap** — in `lib/ui/terminal_screen.dart`:

Add imports:
```dart
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
```

Add the quote helper (top-level or private):
```dart
String _shellQuote(String s) {
  const needs = [' ', '\t', '\'', '"', r'$', '`', r'\\', '*', '?', '|', '&', ';',
      '<', '>', '(', ')', '#', '!', '~'];
  if (!needs.any(s.contains)) return s;
  return "'${s.replaceAll("'", r"'\''")}'";
}
```

Add `_onDrop` + test hook on the state:
```dart
  Future<void> _onDrop(DropDoneDetails details) async {
    final paths = details.files.map((f) => f.path).where((p) => p.isNotEmpty);
    if (paths.isEmpty) return;
    final joined = paths.map(_shellQuote).join(' ');
    _pty?.write(pasteBytes(joined, modeFlags: _grid.modeFlags));
  }

  @visibleForTesting
  void simulateDrop(List<XFile> files) =>
      _onDrop(DropDoneDetails(files: files, localPosition: Offset.zero, globalPosition: Offset.zero));
```

Wrap the existing `Listener`'s child with `DropTarget`:
```dart
            child: DropTarget(
              onDragDone: _onDrop,
              child: Listener(
                onPointerDown: ...,
                ... existing children ...
              ),
            ),
```

- [ ] **Step 5: Run the suite**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -2
```
Expected: analyze clean; new test passes.

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/ui/terminal_screen.dart \
        test/terminal_lifecycle_test.dart
git commit -m "feat(ui): drag-drop files → shell-quoted bracketed-paste insertion

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

# PHASE 4 — Right-click context menu

## Task 6: gnome-terminal-style menu

**Files:**
- Modify: `lib/ui/terminal_screen.dart`
- Test: `test/terminal_lifecycle_test.dart`

- [ ] **Step 1: Write the failing tests** — append to `test/terminal_lifecycle_test.dart`:

```dart
  testWidgets('plain right-click opens context menu with Copy/Paste/Search', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => _FakeBinding(),
    )));
    await tester.pump();
    final center = tester.getCenter(find.byType(CustomPaint).first);
    final g = await tester.startGesture(center, buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse);
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
    expect(find.text('Search…'), findsOneWidget);
    title.dispose();
  });

  testWidgets('Shift+right-click bypasses the menu (forwards to program)', (tester) async {
    final title = ValueNotifier<String>('t');
    final binding = _FakeBinding();
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => binding,
    )));
    await tester.pump();
    final center = tester.getCenter(find.byType(CustomPaint).first);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final g = await tester.startGesture(center, buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse);
    await g.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.text('Copy'), findsNothing);
    title.dispose();
  });
```

- [ ] **Step 2: Run to verify failures**

```bash
flutter test test/terminal_lifecycle_test.dart --plain-name "context menu" 2>&1 | tail -8
```
Expected: FAIL — menu not implemented.

- [ ] **Step 3: Implement `_showContextMenu`** — in `lib/ui/terminal_screen.dart`:

Inside `_TerminalScreenState`, add:
```dart
  Future<void> _showContextMenu(Offset local, Offset global) async {
    final (r, c, _) = _cellAt(local);
    final selText = _client?.binding.selectionText() ?? '';
    String? hyperUri;
    if (_client != null && _grid.rows > r && _grid.columns > c &&
        isHyperlink(_grid.flagsAt(r, c))) {
      hyperUri = _client!.resolveHyperlink(_grid.hyperlinkIdAt(r, c));
    }
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.of(context).size;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
          global.dx, global.dy, size.width - global.dx, size.height - global.dy),
      items: [
        PopupMenuItem(
          enabled: selText.isNotEmpty,
          child: const Text('Copy'),
          onTap: () { if (selText.isNotEmpty) Clipboard.setData(ClipboardData(text: selText)); },
        ),
        PopupMenuItem(child: const Text('Paste'), onTap: _paste),
        if (hyperUri != null) ...[
          PopupMenuItem(
            child: const Text('Open Hyperlink'),
            onTap: () { _launch(hyperUri!); },
          ),
          PopupMenuItem(
            child: const Text('Copy Hyperlink Address'),
            onTap: () { Clipboard.setData(ClipboardData(text: hyperUri!)); },
          ),
        ],
        PopupMenuItem(
          child: const Text('Search…'),
          onTap: () => setState(() => _searchOpen = true),
        ),
      ],
    );
  }
```

In `Listener.onPointerDown`, after the existing mouse-kind guard but BEFORE the existing button-2-forward path, add:
```dart
                if (e.buttons & kSecondaryButton != 0 &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  _showContextMenu(e.localPosition, e.position);
                  return;
                }
```

- [ ] **Step 4: Run the suite + analyze**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -2
```
Expected: analyze clean; menu tests pass. If `pumpAndSettle` hangs, replace with a single `await tester.pump(const Duration(milliseconds: 200))` — menu opens in one frame plus animation.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/terminal_screen.dart test/terminal_lifecycle_test.dart
git commit -m "feat(ui): right-click context menu (gnome-terminal-style; Shift bypasses)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

# PHASE 5 — Visual bell

## Task 7: BellConfig + flash overlay

**Files:**
- Modify: `lib/config/terminal_config.dart`
- Modify: `lib/ui/terminal_screen.dart`
- Test: `test/terminal_config_test.dart`, `test/terminal_lifecycle_test.dart`

- [ ] **Step 1: Write the failing config test** — append to `test/terminal_config_test.dart`:

```dart
  test('bell defaults match alacritty', () {
    final b = TerminalConfig.defaults().bell;
    expect(b.color, 0xFFFFFF);
    expect(b.duration, 0);
    expect(b.animation, 'linear');
  });

  test('fromTomlString reads [bell]', () {
    const toml = '''
[bell]
color = "#ff0000"
duration = 250
animation = "EaseOutExpo"
''';
    final b = TerminalConfig.fromTomlString(toml).bell;
    expect(b.color, 0xFF0000);
    expect(b.duration, 250);
    expect(b.animation, 'EaseOutExpo');
  });
```

- [ ] **Step 2: Run to verify failure**

```bash
flutter test test/terminal_config_test.dart 2>&1 | tail -5
```
Expected: FAIL — `bell` not on `TerminalConfig`.

- [ ] **Step 3: Add `BellConfig` + wire into `TerminalConfig`** — in `lib/config/terminal_config.dart`:

```dart
class BellConfig {
  const BellConfig({
    required this.color,
    required this.duration,
    required this.animation,
  });
  final int color;
  final int duration;       // ms; 0 = disabled
  final String animation;   // accepted for forward-compat; only "linear" rendered

  BellConfig copyWith({int? color, int? duration, String? animation}) => BellConfig(
        color: color ?? this.color,
        duration: duration ?? this.duration,
        animation: animation ?? this.animation,
      );
}
```

Add `bell` to `TerminalConfig` (constructor param, field, `copyWith`):
```dart
    required this.bell,
```
```dart
  final BellConfig bell;
```

In `TerminalConfig.defaults()`, add:
```dart
        bell: BellConfig(color: 0xFFFFFF, duration: 0, animation: 'linear'),
```

In `fromTomlString`, after the existing `mouseM` block, add:
```dart
    final bellM = section(map, 'bell');
```

And in the returned `TerminalConfig(...)`:
```dart
      bell: BellConfig(
        color: color(bellM, 'color', d.bell.color),
        duration: integer(bellM, 'duration', d.bell.duration),
        animation: str(bellM, 'animation', d.bell.animation),
      ),
```

- [ ] **Step 4: Verify config tests pass**

```bash
flutter test test/terminal_config_test.dart 2>&1 | tail -3
```

- [ ] **Step 5: Add the flash overlay** — in `lib/ui/terminal_screen.dart`:

Make the State use `SingleTickerProviderStateMixin`:
```dart
class _TerminalScreenState extends State<TerminalScreen> with SingleTickerProviderStateMixin {
```

Add controller:
```dart
  late final AnimationController _bellCtrl = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _config.bell.duration > 0 ? _config.bell.duration : 1),
  );
```

In `dispose`, add:
```dart
    _bellCtrl.dispose();
```

In `_flashBell`, after the existing audio call:
```dart
    if (_config.bell.duration > 0) {
      _bellCtrl.forward(from: 1.0).then((_) => _bellCtrl.value = 0);
    }
```

Wait — `forward(from: 1.0)` then animates 1.0 → 1.0 (no change). Use `reverse` from a stopped-at-1.0 state, or animate manually. Easier:
```dart
    if (_config.bell.duration > 0) {
      _bellCtrl.value = 1.0;
      _bellCtrl.animateTo(0.0, duration: Duration(milliseconds: _config.bell.duration));
    }
```

In the `Stack` (top of the children list — drawn last = on top), add:
```dart
                  IgnorePointer(
                    child: FadeTransition(
                      opacity: _bellCtrl,
                      child: ColoredBox(color: Color(0xFF000000 | _config.bell.color)),
                    ),
                  ),
```

- [ ] **Step 6: Verify suite + add a smoke widget test (optional)** — a deterministic flash test is awkward without pumping frames; a simple existence-after-flash check suffices:

```dart
  testWidgets('_flashBell with duration > 0 starts the bell animation', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      config: TerminalConfig.defaults().copyWith(bell: const BellConfig(
        color: 0xFFFFFF, duration: 100, animation: 'linear')),
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => _FakeBinding(),
    )));
    await tester.pump();
    final state = tester.state(find.byType(TerminalScreen));
    (state as dynamic)._flashBell();
    await tester.pump(const Duration(milliseconds: 20));
    final ctrl = (state as dynamic)._bellCtrl as AnimationController;
    expect(ctrl.value, lessThan(1.0));  // animating down
    expect(ctrl.value, greaterThan(0.0));
    title.dispose();
  });
```

(`_flashBell` is private; the test uses `dynamic` access. This is a smoke check that animation is wired.)

- [ ] **Step 7: Run the suite**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -2
```
Expected: analyze clean; tests pass.

- [ ] **Step 8: Commit**

```bash
git add lib/config/terminal_config.dart lib/ui/terminal_screen.dart \
        test/terminal_config_test.dart test/terminal_lifecycle_test.dart
git commit -m "feat(ui): visual bell — fade overlay driven by [bell] config

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Sample config + acceptance gate

**Files:**
- Modify: `flutter_alacritty.toml.example`
- Create: `docs/superpowers/plans/2026-05-28-plan2km-findings.md`

- [ ] **Step 1: Document the new config keys** — append to `flutter_alacritty.toml.example`:

```toml

[colors.hints.start]
background = "#f4bf75"   # auto-detected URL / OSC 8 hyperlink highlight
foreground = "#181818"

[bell]
color = "#ffffff"   # visual-bell flash color
duration = 0        # ms; 0 = disabled (audio only)
animation = "linear"  # currently the only rendered curve (accepted for forward-compat)
```

- [ ] **Step 2: Full acceptance run**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
(cd packages/rust_lib_flutter_alacritty/rust && cargo test 2>&1 | tail -4)
flutter build linux --debug 2>&1 | tail -3
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -2
```
Expected: cargo green; build ok; analyze clean; flutter all pass.

- [ ] **Step 3: Manual smoke (Linux)** — record results in findings:
  - `ls --hyperlink=auto ~` → file names underline in gold; Ctrl+click opens `xdg-open`.
  - Echo a URL into the terminal (`echo "see https://example.com"`) → underlined; Ctrl+click opens.
  - `Ctrl+=`/`Ctrl+-`/`Ctrl+0` → visible zoom; clamps at extremes.
  - Drag a file with spaces from a file manager → path appears at prompt, single-quoted.
  - Right-click empty area → menu with Copy/Paste/Search; right-click on a hyperlink cell → menu also has Open / Copy Hyperlink Address; Shift+right-click → no menu, plain button-2 forwarded to program (test in `vim`).
  - `printf '\a'` with `bell.duration = 200` → screen flashes white; with `0` → audio only.

- [ ] **Step 4: Write findings** — `docs/superpowers/plans/2026-05-28-plan2km-findings.md`: what shipped per phase, the `FLAG_HYPERLINK` + `hyperlink_id` protocol addition, the additive `[colors.hints.start]` + `[bell]` config, manual results, deferred items (non-linear bell animations, OSC 7 cwd, OSC 9 notifications, IME preedit — list pointer to 2L/2N/2O).

- [ ] **Step 5: Commit**

```bash
git add flutter_alacritty.toml.example \
        docs/superpowers/plans/2026-05-28-plan2km-findings.md
git commit -m "docs(km): sample hint/bell config + Plan 2K·2M acceptance findings

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Acceptance Criteria

- [ ] **2K hyperlinks:** OSC 8 sequences produce `FLAG_HYPERLINK` + non-zero `hyperlink_id`; URL regex auto-detect marks visible-region matches; precedence focused-match > match > hyperlink in the painter; Ctrl+left-click resolves the URI and calls `launchUrl`; hovering shows the click cursor.
- [ ] **2M font zoom:** `Ctrl+=`/`Ctrl+-` step ±1.0 clamped [6,72]; `Ctrl+0` resets to `_config.font.size`; `_metrics` / `_glyphs` / `_grid` rebuilt; previous glyph cache disposed.
- [ ] **2M drag-drop:** dropped paths are shell-quoted (single-quoted when needed), space-joined, written through `pasteBytes` so bracketed-paste applies when set.
- [ ] **2M right-click menu:** plain right-click opens conditional menu (Copy enabled iff selection non-empty; Paste always; Open/Copy Hyperlink Address shown only when on a hyperlink cell; Search… always); Shift+right-click falls through to the existing button-2 path.
- [ ] **2M visual bell:** `[bell]` schema parsed; `duration > 0` flashes; `duration == 0` no flash.
- [ ] No regressions; `flutter analyze` clean; `cargo test` + `flutter test` green after `flutter build linux --debug`.
- [ ] Library boundary intact: new `[colors.hints.start]` and `[bell]` are additive; old configs load unchanged.

---

## Self-Review

**Spec coverage:** §3 (P1 hyperlinks) → Tasks 1-3. §4 (P2 font zoom) → Task 4. §5 (P3 drag-drop) → Task 5. §6 (P4 menu) → Task 6. §7 (P5 visual bell) → Task 7. §2 locked decisions: hyperlink interning + auto-detect → Task 1; opaque hint colors with precedence → Task 2; Ctrl+click + url_launcher → Task 3; font zoom step/clamp + glyph cache dispose → Task 4; shell quoting + bracketed paste → Task 5; gnome-terminal menu with Shift bypass → Task 6; bell schema + flash → Task 7. §9 error handling: bad URI silent → Task 3; resolveHyperlink stale id → Task 1 (None) + Task 6 (skips menu items); drop with empty path → Task 5; font clamp → Task 4. §10 testing → every task has tests; Task 8 manual + findings. §11 risks: hyperlink precedence resolved by `applyMatchOrHint` (Task 2); hint regex perf bounded to viewport (Task 1); font-zoom rebuild cost mitigated by GlyphCache.dispose (Task 4).

**Placeholder scan:** none — every code step has full code; the `forward(from: 1.0)` correction in Task 7 Step 5 is inline, not a TBD.

**Type consistency:** `FLAG_HYPERLINK` (Rust) ↔ `kFlagHyperlink` (Dart) = `1 << 11`. `hyperlink_id`/`hyperlinkId` u32/int consistent across `CellData`, `LineCells`, `MirrorGrid` lane, `_FakeBinding`, click handler. `HintColors{bg,fg}` used identically in painter (Task 2) and screen (Task 2 Step 8). `BellConfig{color,duration,animation}` defined (Task 7 Step 3), parsed (Step 3), animated (Step 5). `UrlLauncher = Future<bool> Function(String)` typedef used in `TerminalScreen.launchUrl` widget param (Task 3) and the test's `launchUrl:` (Task 3 Step 2). `_setZoom`, `_rebuildMetrics` (folded into `_setZoom`), `_showContextMenu`, `_onDrop`, `_shellQuote`, `_launch` are all defined once and used once.

**Spec path drift note:** spec uses old `rust/src/...` paths but the project moved Rust into `packages/rust_lib_flutter_alacritty/rust/src/...` (commits 9bb41e5..38e46ae). The plan uses the current paths throughout; spec text remains valid as architectural reference but pointers to file lines should follow the plan.
