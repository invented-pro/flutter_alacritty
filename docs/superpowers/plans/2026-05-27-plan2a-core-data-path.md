# Plan 2A — Core Data Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the engine↔Dart data path production-grade — parse off the UI isolate with per-frame coalescing, transfer only damaged lines, wire the terminal→host event back-channel, and render via a glyph cache — so heavy output stays smooth and terminal queries get answered.

**Architecture:** Rust gains a testable `EventProxy` (replacing `NoopListener`), a `take_damage()` built on `term.damage()`/`reset_damage()`, and `RenderUpdate`/`LineUpdate` types. FRB exposes async `engine_advance`/`engine_take_damage`, `engine_new(sink)`, `engine_full_snapshot`, and an `EngineEvent` stream. Dart gains a mutable `MirrorGrid`, a `GlyphCache`, and a `TerminalEngineClient` that coalesces PTY bytes per frame (with a re-entrancy flag for backpressure) and routes events.

**Tech Stack:** Rust (`alacritty_terminal` git-pinned, `flutter_rust_bridge` 2.12), Flutter 3.41 / Dart 3.11, `flutter_pty`.

**Builds on:** the tracer bullet, branch `feature/tracer-bullet`. Spec: `docs/superpowers/specs/2026-05-27-plan2a-core-data-path-design.md`.

**Out of scope (other sub-projects):** text attributes/inverse/cursor-styles/wide-chars (C), mode-aware input/mouse (B), scrollback/selection/copy-paste (D), shell-exit restart UX (E). **Deliberate A-level simplification:** `EventProxy` stays stateless — it handles `PtyWrite`/`Title`/`ResetTitle`/`Bell`/`ClipboardStore` and answers `ClipboardLoad` with empty; `ColorRequest`/`TextAreaSizeRequest` are no-ops (rare OSC queries; revisited when state-coupling is justified). The DSR/DA correctness path is `PtyWrite` and is fully handled.

---

## File Structure

**Rust:**
- `rust/src/engine.rs` — MODIFY: add `RenderUpdate`/`LineUpdate`; `line_cells()` helper; refactor `snapshot()`→`full_snapshot() -> RenderUpdate`; add `take_damage()`; `TerminalEngine::new` takes an event sink; `term: Term<EventProxy>`.
- `rust/src/event_proxy.rs` — CREATE: `EngineEvent`, `EventProxy` (`Arc<dyn Fn(EngineEvent)>`), `Event`→`EngineEvent` mapping.
- `rust/src/api/terminal.rs` — MODIFY: async `engine_advance`/`engine_take_damage`; `engine_new(sink)`; `engine_full_snapshot`; re-export new types.
- `rust/src/lib.rs` — MODIFY: `mod event_proxy;`.

**Dart:**
- `lib/render/mirror_grid.dart` — REWRITE: mutable per-line storage + `GridUpdate`/`LineCells` native types + `apply()`.
- `lib/render/glyph_cache.dart` — CREATE: cached `ui.Paragraph` per `(codepoint, fg)`, LRU-capped.
- `lib/render/cell_metrics.dart` — CREATE: sub-pixel cell-width measurement (cols fix); moved out of painter.
- `lib/render/terminal_painter.dart` — MODIFY: draw from `GlyphCache` + mutable grid; keep `kTerminalTextStyle`.
- `lib/engine/engine_binding.dart` — CREATE: `EngineBinding` interface + `FrbEngineBinding`.
- `lib/engine/terminal_engine_client.dart` — CREATE: coalescing/backpressure + event routing.
- `lib/ui/terminal_screen.dart` — MODIFY: host the client, title `ValueNotifier`, bell flash.

**Tests:**
- `rust/src/engine.rs`, `rust/src/event_proxy.rs` — `#[cfg(test)]`.
- `test/mirror_grid_test.dart`, `test/glyph_cache_test.dart`, `test/engine_client_test.dart`, `test/engine_bindings_test.dart` (update).

---

## Task 1: Rust — RenderUpdate/LineUpdate + refactor snapshot

**Files:**
- Modify: `rust/src/engine.rs`

- [ ] **Step 1: Replace the existing engine tests' snapshot helper + add the line-based assertions (failing)**

In `rust/src/engine.rs`, replace the whole `#[cfg(test)] mod tests { ... }` block with:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn engine(cols: u16, rows: u16) -> TerminalEngine {
        TerminalEngine::new(cols, rows, |_| {})
    }

    fn line<'a>(u: &'a RenderUpdate, row: u32) -> &'a LineUpdate {
        u.lines.iter().find(|l| l.line == row).expect("line present")
    }
    fn ch(u: &RenderUpdate, row: u32, col: usize) -> char {
        char::from_u32(line(u, row).cells[col].codepoint).unwrap()
    }

    #[test]
    fn writes_plain_text_into_the_grid() {
        let mut e = engine(20, 5);
        e.advance(b"hi".to_vec());
        let u = e.full_snapshot();
        assert_eq!(u.columns(), 20);
        assert_eq!(u.lines.len(), 5);
        assert_eq!(ch(&u, 0, 0), 'h');
        assert_eq!(ch(&u, 0, 1), 'i');
        assert!(u.full);
    }

    #[test]
    fn applies_sgr_foreground_color() {
        let mut e = engine(20, 5);
        e.advance(b"\x1b[31mR".to_vec());
        let u = e.full_snapshot();
        let c = &line(&u, 0).cells[0];
        assert_eq!(char::from_u32(c.codepoint).unwrap(), 'R');
        assert_eq!(c.fg & 0x00FF_FFFF, 0x00CC_0000);
    }

    #[test]
    fn newline_moves_to_next_row() {
        let mut e = engine(20, 5);
        e.advance(b"a\r\nb".to_vec());
        let u = e.full_snapshot();
        assert_eq!(ch(&u, 0, 0), 'a');
        assert_eq!(ch(&u, 1, 0), 'b');
    }

    #[test]
    fn resize_changes_reported_dimensions() {
        let mut e = engine(20, 5);
        e.resize(40, 10);
        let u = e.full_snapshot();
        assert_eq!(u.columns(), 40);
        assert_eq!(u.lines.len(), 10);
        assert_eq!(line(&u, 0).cells.len(), 40);
    }
}
```
(`TerminalEngine::new` now takes a sink closure — implemented in Task 2; this task uses `|_| {}`. To keep Task 1 self-contained, temporarily keep the old `new(cols, rows)` working by giving it a default in Step 3, then Task 2 adds the sink param. **Simpler: implement the sink param now** — see Step 3.)

- [ ] **Step 2: Run to verify failure**

Run: `cd rust && cargo test engine 2>&1 | tail -20`
Expected: FAIL — `RenderUpdate`/`LineUpdate`/`full_snapshot`/`columns` not found; `new` arity mismatch.

- [ ] **Step 3: Add the types, the `line_cells` helper, and `full_snapshot`**

In `rust/src/engine.rs`, **remove** the `RenderSnapshot` struct and the `snapshot()` method, and add:
```rust
#[derive(Clone, Debug)]
pub struct LineUpdate {
    pub line: u32,
    pub cells: Vec<CellData>,
}

#[derive(Clone, Debug)]
pub struct RenderUpdate {
    pub lines: Vec<LineUpdate>,
    pub full: bool,
    pub cursor_line: u32,
    pub cursor_col: u32,
    pub cursor_visible: bool,
}

impl RenderUpdate {
    /// Column count inferred from the first line (test/diagnostic helper).
    pub fn columns(&self) -> usize {
        self.lines.first().map(|l| l.cells.len()).unwrap_or(0)
    }
}
```
Add these methods inside `impl TerminalEngine` (replacing the old `snapshot`):
```rust
/// Cells of a single viewport row (display_offset is 0 in Plan 2A — no scrollback).
fn line_cells(&self, row: usize) -> Vec<CellData> {
    use alacritty_terminal::index::{Column, Line};
    let grid = self.term.grid();
    let cols = grid.columns();
    let mut cells = Vec::with_capacity(cols);
    let g_line = &grid[Line(row as i32)];
    for col in 0..cols {
        let cell = &g_line[Column(col)];
        cells.push(CellData {
            codepoint: cell.c as u32,
            fg: resolve_color(cell.fg, true),
            bg: resolve_color(cell.bg, false),
            flags: map_flags(cell.flags),
        });
    }
    cells
}

fn cursor_fields(&self) -> (u32, u32, bool) {
    let cursor = self.term.grid().cursor.point;
    (
        cursor.line.0.max(0) as u32,
        cursor.column.0 as u32,
        self.term.mode().contains(TermMode::SHOW_CURSOR),
    )
}

pub fn full_snapshot(&self) -> RenderUpdate {
    let rows = self.term.screen_lines();
    let lines = (0..rows)
        .map(|row| LineUpdate { line: row as u32, cells: self.line_cells(row) })
        .collect();
    let (cursor_line, cursor_col, cursor_visible) = self.cursor_fields();
    RenderUpdate { lines, full: true, cursor_line, cursor_col, cursor_visible }
}
```
Remove the now-unused `Point` import if the compiler warns (snapshot's `display_iter` loop is gone). Keep `Dimensions` import (used by `columns()`/`screen_lines()`).

- [ ] **Step 4: Run to verify pass**

Run: `cd rust && cargo test engine 2>&1 | tail -20`
Expected: `test result: ok. 4 passed`. (`new` takes the sink closure now; if Task 2 not yet done, temporarily add the sink param per Task 2 Step 3, or this task and Task 2 may be committed together.)

- [ ] **Step 5: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty/.worktrees/tracer-bullet
git add rust/src/engine.rs
git commit -m "refactor(rust): RenderUpdate/LineUpdate + full_snapshot"
```

---

## Task 2: Rust — EventProxy + EngineEvent (replace NoopListener)

**Files:**
- Create: `rust/src/event_proxy.rs`
- Modify: `rust/src/engine.rs`, `rust/src/lib.rs`

- [ ] **Step 1: Write the failing tests**

Create `rust/src/event_proxy.rs`:
```rust
use std::sync::Arc;

use alacritty_terminal::event::{Event, EventListener};

/// Serializable terminal→host events (mirrored to Dart by FRB).
#[derive(Clone, Debug, PartialEq)]
pub enum EngineEvent {
    PtyWrite(Vec<u8>),
    Title(String),
    ResetTitle,
    Bell,
    ClipboardStore(String),
}

/// Bridges alacritty's `EventListener` to a host sink closure. Stateless and
/// testable: production wires the closure to an FRB StreamSink; tests collect
/// into a Vec.
#[derive(Clone)]
pub struct EventProxy {
    sink: Arc<dyn Fn(EngineEvent) + Send + Sync>,
}

impl EventProxy {
    pub fn new(f: impl Fn(EngineEvent) + Send + Sync + 'static) -> Self {
        Self { sink: Arc::new(f) }
    }
    fn emit(&self, e: EngineEvent) {
        (self.sink)(e);
    }
}

impl EventListener for EventProxy {
    fn send_event(&self, event: Event) {
        match event {
            Event::PtyWrite(s) => self.emit(EngineEvent::PtyWrite(s.into_bytes())),
            Event::Title(s) => self.emit(EngineEvent::Title(s)),
            Event::ResetTitle => self.emit(EngineEvent::ResetTitle),
            Event::Bell => self.emit(EngineEvent::Bell),
            Event::ClipboardStore(_, s) => self.emit(EngineEvent::ClipboardStore(s)),
            // App reads clipboard (OSC52 paste): answer empty for Plan 2A.
            Event::ClipboardLoad(_, format) => {
                self.emit(EngineEvent::PtyWrite(format("").into_bytes()))
            }
            // ColorRequest / TextAreaSizeRequest need engine state → deferred.
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn collector() -> (EventProxy, Arc<Mutex<Vec<EngineEvent>>>) {
        let store = Arc::new(Mutex::new(Vec::new()));
        let s = store.clone();
        (EventProxy::new(move |e| s.lock().unwrap().push(e)), store)
    }

    #[test]
    fn maps_pty_write() {
        let (proxy, store) = collector();
        proxy.send_event(Event::PtyWrite("\x1b[1;3R".to_string()));
        assert_eq!(
            store.lock().unwrap()[0],
            EngineEvent::PtyWrite(b"\x1b[1;3R".to_vec())
        );
    }

    #[test]
    fn maps_title() {
        let (proxy, store) = collector();
        proxy.send_event(Event::Title("hello".to_string()));
        assert_eq!(store.lock().unwrap()[0], EngineEvent::Title("hello".into()));
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd rust && cargo test event_proxy 2>&1 | tail -20`
Expected: FAIL — module not declared (`event_proxy` unknown).

- [ ] **Step 3: Wire the module and the engine**

In `rust/src/lib.rs` add: `mod event_proxy;`

In `rust/src/engine.rs`:
- Remove the `NoopListener` struct and its `impl EventListener`.
- Change the field: `term: Term<crate::event_proxy::EventProxy>,`
- Change `new` to take a sink closure:
```rust
pub fn new(
    columns: u16,
    rows: u16,
    sink: impl Fn(crate::event_proxy::EngineEvent) + Send + Sync + 'static,
) -> TerminalEngine {
    let size = alacritty_terminal::term::test::TermSize::new(columns as usize, rows as usize);
    let proxy = crate::event_proxy::EventProxy::new(sink);
    let term = Term::new(Config::default(), &size, proxy);
    TerminalEngine { term, parser: Processor::new() }
}
```
- Remove the now-unused `use alacritty_terminal::event::{Event, EventListener};` line from `engine.rs` (it moved to `event_proxy.rs`).

- [ ] **Step 4: Run to verify pass**

Run: `cd rust && cargo test 2>&1 | tail -20`
Expected: `event_proxy` 2 tests pass and `engine` 4 tests still pass (6 total).

- [ ] **Step 5: Commit**

```bash
git add rust/src/event_proxy.rs rust/src/engine.rs rust/src/lib.rs
git commit -m "feat(rust): testable EventProxy + EngineEvent back-channel"
```

---

## Task 3: Rust — take_damage()

**Files:**
- Modify: `rust/src/engine.rs`

- [ ] **Step 1: Write the failing tests**

Add to the `tests` module in `rust/src/engine.rs`:
```rust
#[test]
fn damage_reports_only_changed_lines_then_resets() {
    let mut e = engine(20, 5);
    e.advance(b"hi".to_vec());
    let u = e.take_damage();
    assert!(!u.full);
    assert!(u.lines.iter().any(|l| l.line == 0));
    assert_eq!(char::from_u32(u.lines.iter().find(|l| l.line == 0).unwrap().cells[0].codepoint).unwrap(), 'h');
    // Second read after reset: nothing changed → no damaged lines.
    let u2 = e.take_damage();
    assert!(!u2.full);
    assert!(u2.lines.is_empty());
}

#[test]
fn resize_forces_full_damage() {
    let mut e = engine(20, 5);
    e.take_damage(); // drain initial
    e.resize(30, 6);
    let u = e.take_damage();
    assert!(u.full);
    assert_eq!(u.lines.len(), 6);
}

#[test]
fn dsr_emits_pty_write() {
    use std::sync::{Arc, Mutex};
    use crate::event_proxy::EngineEvent;
    let store = Arc::new(Mutex::new(Vec::new()));
    let s = store.clone();
    let mut e = TerminalEngine::new(20, 5, move |ev| s.lock().unwrap().push(ev));
    e.advance(b"\x1b[6n".to_vec()); // DSR: report cursor position
    let events = store.lock().unwrap();
    assert!(
        events.iter().any(|ev| matches!(ev, EngineEvent::PtyWrite(b) if b.starts_with(b"\x1b["))),
        "expected a PtyWrite cursor report, got {:?}", *events
    );
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd rust && cargo test engine 2>&1 | tail -25`
Expected: FAIL — `no method named take_damage`.

- [ ] **Step 3: Implement `take_damage`**

Add to `impl TerminalEngine` and add the import `use alacritty_terminal::term::TermDamage;` at the top (alongside the existing `term::{Config, Term, TermMode}` — extend it to `term::{Config, Term, TermDamage, TermMode}`):
```rust
pub fn take_damage(&mut self) -> RenderUpdate {
    // Collect damaged viewport rows, then drop the borrow before reading cells.
    let damaged: Option<Vec<usize>> = match self.term.damage() {
        TermDamage::Full => None,
        TermDamage::Partial(it) => Some(it.map(|b| b.line).collect()),
    };
    self.term.reset_damage();

    let (cursor_line, cursor_col, cursor_visible) = self.cursor_fields();
    match damaged {
        None => {
            let mut u = self.full_snapshot();
            u.cursor_line = cursor_line;
            u.cursor_col = cursor_col;
            u.cursor_visible = cursor_visible;
            u
        }
        Some(mut rows) => {
            rows.sort_unstable();
            rows.dedup();
            let lines = rows
                .into_iter()
                .map(|row| LineUpdate { line: row as u32, cells: self.line_cells(row) })
                .collect();
            RenderUpdate { lines, full: false, cursor_line, cursor_col, cursor_visible }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd rust && cargo test 2>&1 | tail -20`
Expected: all engine + event_proxy tests pass (9 total).

- [ ] **Step 5: Commit**

```bash
git add rust/src/engine.rs
git commit -m "feat(rust): take_damage() incremental render updates"
```

---

## Task 4: FRB — async API + EngineEvent stream + codegen

**Files:**
- Modify: `rust/src/api/terminal.rs`
- Test: `test/engine_bindings_test.dart`
- Generated: `lib/src/rust/**`, `rust/src/frb_generated.rs`

- [ ] **Step 1: Rewrite the FRB surface**

Replace the contents of `rust/src/api/terminal.rs` with:
```rust
pub use crate::engine::{CellData, LineUpdate, RenderUpdate, TerminalEngine};
pub use crate::event_proxy::EngineEvent;

use flutter_rust_bridge::frb;
use flutter_rust_bridge::StreamSink;

#[frb(sync)]
pub fn engine_new(columns: u16, rows: u16, sink: StreamSink<EngineEvent>) -> TerminalEngine {
    TerminalEngine::new(columns, rows, move |event| {
        let _ = sink.add(event);
    })
}

pub async fn engine_advance(engine: &mut TerminalEngine, bytes: Vec<u8>) {
    engine.advance(bytes);
}

pub async fn engine_take_damage(engine: &mut TerminalEngine) -> RenderUpdate {
    engine.take_damage()
}

#[frb(sync)]
pub fn engine_full_snapshot(engine: &TerminalEngine) -> RenderUpdate {
    engine.full_snapshot()
}

#[frb(sync)]
pub fn engine_resize(engine: &mut TerminalEngine, columns: u16, rows: u16) {
    engine.resize(columns, rows);
}
```

- [ ] **Step 2: Run codegen**

Run:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty/.worktrees/tracer-bullet
flutter_rust_bridge_codegen generate
```
Expected: regenerates `lib/src/rust/api/terminal.dart` (with `engineNew`, async `engineAdvance`/`engineTakeDamage`, `engineFullSnapshot`, `engineResize`) and `lib/src/rust/event_proxy.dart` (with `EngineEvent` sealed class + variants) and `RenderUpdate`/`LineUpdate`. No errors.

- [ ] **Step 3: Update the FFI binding test to the new API**

Replace the `test(...)` body in `test/engine_bindings_test.dart` (keep the `_findOrBuildLib`/`setUpAll` from the tracer-bullet fix) with:
```dart
  test('engine new/advance/take_damage round-trips + emits events', () async {
    final events = <EngineEvent>[];
    final sub = <Object?>[];
    final engine = engineNew(
      columns: 20,
      rows: 5,
      sink: () {
        // engineNew returns the engine; the events stream is the sink param.
      }(),
    );
    // NOTE: see Step 4 for the correct sink/stream wiring; this test asserts
    // the data round-trip:
    await engineAdvance(engine: engine, bytes: 'hi'.codeUnits);
    final u = await engineTakeDamage(engine: engine);
    final line0 = u.lines.firstWhere((l) => l.line == 0);
    expect(String.fromCharCode(line0.cells[0].codepoint), 'h');
    expect(String.fromCharCode(line0.cells[1].codepoint), 'i');
    expect(events, isEmpty); // referenced to avoid unused warning
    sub.clear();
  });
```
> The `sink` parameter shape FRB generates for a `StreamSink` arg is a `Stream` return on the Dart side via a paired API; confirm the exact generated signature after Step 2 and adjust the test to obtain the stream (commonly `engineNew(columns:, rows:)` returns the engine and the stream is delivered through the same call's generated `Stream` — inspect `lib/src/rust/api/terminal.dart`). The assertion on `take_damage` cells is the stable part.

- [ ] **Step 4: Confirm the generated sink/stream signature and finalize the test**

Run: `sed -n '1,60p' lib/src/rust/api/terminal.dart`
Expected: shows the generated `engineNew` signature. If it returns `(TerminalEngine, Stream<EngineEvent>)` or takes no sink and instead exposes a separate stream, update the test to capture events:
```dart
    final (engine, events) = engineNew(columns: 20, rows: 5); // adapt to actual signature
    final collected = <EngineEvent>[];
    events.listen(collected.add);
    await engineAdvance(engine: engine, bytes: '\x1b[6n'.codeUnits); // DSR
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(collected.whereType<EngineEvent_PtyWrite>(), isNotEmpty);
```

- [ ] **Step 5: Build the lib and run the binding test**

Run:
```bash
cd rust && cargo build && cd ..
flutter test test/engine_bindings_test.dart
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add rust/src/api/terminal.rs rust/src/frb_generated.rs lib/src/rust test/engine_bindings_test.dart
git commit -m "feat(frb): async advance/take_damage + EngineEvent stream"
```

---

## Task 5: Dart — mutable MirrorGrid

**Files:**
- Rewrite: `lib/render/mirror_grid.dart`
- Test: `test/mirror_grid_test.dart`

- [ ] **Step 1: Write the failing test**

Replace `test/mirror_grid_test.dart` with:
```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

LineCells row(int line, String text) => LineCells(
      line: line,
      codepoints: Int32List.fromList(text.codeUnits),
      fg: Int32List.fromList(List.filled(text.length, 0xD8D8D8)),
      bg: Int32List.fromList(List.filled(text.length, 0x181818)),
    );

void main() {
  test('full update populates all rows', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true,
      rows: 2,
      columns: 3,
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
    g.apply(GridUpdate(full: false, rows: 2, columns: 3,
        lines: [row(1, 'QQQ')], cursorRow: 1, cursorCol: 2, cursorVisible: true));
    expect(g.codepointAt(0, 0), 'a'.codeUnitAt(0)); // unchanged
    expect(g.codepointAt(1, 0), 'Q'.codeUnitAt(0)); // mutated
    expect(g.cursorRow, 1);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/mirror_grid_test.dart`
Expected: FAIL — `LineCells`/`GridUpdate`/`apply` not found.

- [ ] **Step 3: Rewrite MirrorGrid**

Replace `lib/render/mirror_grid.dart` with:
```dart
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

/// One line's cells (native types — decoupled from FRB so MirrorGrid is
/// unit-testable without the native lib).
class LineCells {
  LineCells({
    required this.line,
    required this.codepoints,
    required this.fg,
    required this.bg,
  });
  final int line;
  final Int32List codepoints;
  final Int32List fg;
  final Int32List bg;
}

/// A render update: either a full replace or a set of changed lines.
class GridUpdate {
  GridUpdate({
    required this.full,
    required this.rows,
    required this.columns,
    required this.lines,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorVisible,
  });
  final bool full;
  final int rows;
  final int columns;
  final List<LineCells> lines;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
}

/// Mutable terminal grid. Applies incremental line deltas in place and notifies
/// the painter to repaint.
class MirrorGrid extends ChangeNotifier {
  int _rows = 0;
  int _columns = 0;
  List<Int32List> _codepoints = [];
  List<Int32List> _fg = [];
  List<Int32List> _bg = [];
  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _cursorVisible = false;

  int get rows => _rows;
  int get columns => _columns;
  int get cursorRow => _cursorRow;
  int get cursorCol => _cursorCol;
  bool get cursorVisible => _cursorVisible;

  int codepointAt(int row, int col) => _codepoints[row][col];
  int fgAt(int row, int col) => _fg[row][col];
  int bgAt(int row, int col) => _bg[row][col];

  void _ensureSize(int rows, int columns) {
    if (rows == _rows && columns == _columns) return;
    _rows = rows;
    _columns = columns;
    _codepoints = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 32));
    _fg = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 0xD8D8D8));
    _bg = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 0x181818));
  }

  void apply(GridUpdate u) {
    if (u.full || u.rows != _rows || u.columns != _columns) {
      _ensureSize(u.rows, u.columns);
    }
    for (final l in u.lines) {
      if (l.line < 0 || l.line >= _rows) continue;
      _codepoints[l.line].setAll(0, l.codepoints);
      _fg[l.line].setAll(0, l.fg);
      _bg[l.line].setAll(0, l.bg);
    }
    _cursorRow = u.cursorRow;
    _cursorCol = u.cursorCol;
    _cursorVisible = u.cursorVisible;
    notifyListeners();
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `flutter test test/mirror_grid_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/render/mirror_grid.dart test/mirror_grid_test.dart
git commit -m "feat(render): mutable MirrorGrid with incremental apply()"
```

---

## Task 6: Dart — GlyphCache

**Files:**
- Create: `lib/render/glyph_cache.dart`
- Test: `test/glyph_cache_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/glyph_cache_test.dart`:
```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('same key returns the identical cached paragraph', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 4);
    final a = cache.get('A'.codeUnitAt(0), 0xFFFFFF);
    final b = cache.get('A'.codeUnitAt(0), 0xFFFFFF);
    expect(identical(a, b), isTrue);
  });

  test('evicts beyond capacity', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 2);
    cache.get(0x41, 0xFFFFFF);
    cache.get(0x42, 0xFFFFFF);
    cache.get(0x43, 0xFFFFFF); // evicts 0x41
    expect(cache.length, 2);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/glyph_cache_test.dart`
Expected: FAIL — `glyph_cache.dart`/`GlyphCache` not found.

- [ ] **Step 3: Implement GlyphCache**

Create `lib/render/glyph_cache.dart`:
```dart
import 'dart:collection';
import 'dart:ui' as ui;

/// Caches pre-laid-out single-glyph paragraphs keyed by (codepoint, fg) so the
/// painter never re-runs text layout on the hot path. LRU-capped.
class GlyphCache {
  GlyphCache({
    required this.fontFamily,
    required this.fontSize,
    required this.cellWidth,
    this.maxEntries = 4096,
  });

  final String fontFamily;
  final double fontSize;
  final double cellWidth;
  final int maxEntries;

  final LinkedHashMap<int, ui.Paragraph> _cache = LinkedHashMap();

  int get length => _cache.length;

  ui.Paragraph get(int codepoint, int fg) {
    final key = (codepoint << 24) ^ (fg & 0xFFFFFF);
    final existing = _cache.remove(key); // remove+reinsert = LRU touch
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }
    final p = _build(codepoint, fg);
    _cache[key] = p;
    if (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first); // evict eldest
    }
    return p;
  }

  ui.Paragraph _build(int codepoint, int fg) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
    ))
      ..pushStyle(ui.TextStyle(
        color: ui.Color(0xFF000000 | (fg & 0xFFFFFF)),
        fontFamily: fontFamily,
        fontSize: fontSize,
      ))
      ..addText(String.fromCharCode(codepoint));
    final p = builder.build()..layout(ui.ParagraphConstraints(width: cellWidth));
    return p;
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `flutter test test/glyph_cache_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/render/glyph_cache.dart test/glyph_cache_test.dart
git commit -m "feat(render): LRU glyph cache of pre-laid-out paragraphs"
```

---

## Task 7: Dart — CellMetrics (sub-pixel) + painter via GlyphCache

**Files:**
- Create: `lib/render/cell_metrics.dart`
- Modify: `lib/render/terminal_painter.dart`

- [ ] **Step 1: Create sub-pixel CellMetrics**

Create `lib/render/cell_metrics.dart`:
```dart
import 'package:flutter/widgets.dart';

/// Monospace cell metrics. Width is measured over many glyphs and divided, so
/// sub-pixel advance is captured (fixes integer-rounding column drift).
class CellMetrics {
  CellMetrics(this.width, this.height);
  final double width;
  final double height;

  static CellMetrics measure(TextStyle style, {int sample = 20}) {
    final tp = TextPainter(
      text: TextSpan(text: 'W' * sample, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return CellMetrics(tp.width / sample, tp.height);
  }
}
```

- [ ] **Step 2: Rewrite the painter to use the cache + mutable grid**

Replace `lib/render/terminal_painter.dart` with:
```dart
import 'package:flutter/material.dart';

import 'glyph_cache.dart';
import 'mirror_grid.dart';

const kTerminalTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 14,
  height: 1.2,
);

class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.glyphs,
    required this.cellWidth,
    required this.cellHeight,
  }) : super(repaint: grid);

  final MirrorGrid grid;
  final GlyphCache glyphs;
  final double cellWidth;
  final double cellHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final rows = grid.rows, cols = grid.columns;
    if (rows == 0 || cols == 0) return;
    final bgPaint = Paint();

    for (var row = 0; row < rows; row++) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        final x = col * cellWidth;
        bgPaint.color = Color(0xFF000000 | grid.bgAt(row, col));
        canvas.drawRect(Rect.fromLTWH(x, y, cellWidth, cellHeight), bgPaint);

        final cp = grid.codepointAt(row, col);
        if (cp != 32 && cp != 0) {
          canvas.drawParagraph(glyphs.get(cp, grid.fgAt(row, col)), Offset(x, y));
        }
      }
    }

    if (grid.cursorVisible) {
      canvas.drawRect(
        Rect.fromLTWH(grid.cursorCol * cellWidth, grid.cursorRow * cellHeight, cellWidth, cellHeight),
        Paint()..color = const Color(0x88FFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.grid != grid || old.cellWidth != cellWidth || old.cellHeight != cellHeight;
}
```
> `CellMetrics` is now in `cell_metrics.dart`; the painter no longer defines it.

- [ ] **Step 3: Verify analysis**

Run: `flutter analyze lib/render`
Expected: No issues (it will report errors in `terminal_screen.dart` still importing the old `CellMetrics` from the painter — fixed in Task 9; analyze just `lib/render` here).

- [ ] **Step 4: Commit**

```bash
git add lib/render/cell_metrics.dart lib/render/terminal_painter.dart
git commit -m "feat(render): sub-pixel CellMetrics + glyph-cached painter"
```

---

## Task 8: Dart — EngineBinding + TerminalEngineClient (coalescing)

**Files:**
- Create: `lib/engine/engine_binding.dart`
- Create: `lib/engine/terminal_engine_client.dart`
- Test: `test/engine_client_test.dart`

- [ ] **Step 1: Define the EngineBinding seam**

Create `lib/engine/engine_binding.dart`:
```dart
import 'dart:typed_data';

import '../render/mirror_grid.dart';

/// Abstracts the FRB engine calls so the client is testable without the native
/// lib. Returns native [GridUpdate]s (translation from FRB types lives in the
/// FRB-backed implementation).
abstract class EngineBinding {
  Future<void> advance(Uint8List bytes);
  Future<GridUpdate> takeDamage();
  void resize(int columns, int rows);
  void dispose();
}
```

- [ ] **Step 2: Write the failing coalescing test**

Create `test/engine_client_test.dart`:
```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

class _FakeBinding implements EngineBinding {
  int advanceCalls = 0;
  final List<int> totalBytes = [];
  @override
  Future<void> advance(Uint8List bytes) async {
    advanceCalls++;
    totalBytes.addAll(bytes);
  }
  @override
  Future<GridUpdate> takeDamage() async => GridUpdate(
      full: false, rows: 1, columns: 1, lines: const [],
      cursorRow: 0, cursorCol: 0, cursorVisible: true);
  @override
  void resize(int columns, int rows) {}
  @override
  void dispose() {}
}

void main() {
  test('bursts within one frame coalesce into a single advance', () async {
    final binding = _FakeBinding();
    final grid = MirrorGrid();
    late void Function() pendingDrain;
    var scheduled = false;
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) { scheduled = true; pendingDrain = cb; },
    );

    client.feed(Uint8List.fromList([1, 2]));
    client.feed(Uint8List.fromList([3]));
    client.feed(Uint8List.fromList([4, 5]));
    expect(scheduled, isTrue);

    pendingDrain(); // simulate the post-frame callback
    await Future<void>.delayed(Duration.zero);

    expect(binding.advanceCalls, 1);
    expect(binding.totalBytes, [1, 2, 3, 4, 5]);
  });
}
```

- [ ] **Step 3: Run to verify failure**

Run: `flutter test test/engine_client_test.dart`
Expected: FAIL — `terminal_engine_client.dart`/`TerminalEngineClient` not found.

- [ ] **Step 4: Implement the client**

Create `lib/engine/terminal_engine_client.dart`:
```dart
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';

import '../render/mirror_grid.dart';
import 'engine_binding.dart';

/// Coalesces PTY output per frame and feeds it to the engine off the UI thread,
/// then applies the returned damage to the grid. A single advance is ever in
/// flight (`_advancing`), giving natural backpressure under heavy output.
class TerminalEngineClient {
  TerminalEngineClient({
    required EngineBinding binding,
    required MirrorGrid grid,
    void Function(void Function())? schedule,
  })  : _binding = binding,
        _grid = grid,
        _schedule = schedule ??
            ((cb) => SchedulerBinding.instance.addPostFrameCallback((_) => cb()));

  final EngineBinding _binding;
  final MirrorGrid _grid;
  final void Function(void Function()) _schedule;

  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool _drainScheduled = false;
  bool _advancing = false;

  void feed(Uint8List bytes) {
    _buf.add(bytes);
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_drainScheduled || _advancing) return;
    _drainScheduled = true;
    _schedule(_drain);
  }

  Future<void> _drain() async {
    _drainScheduled = false;
    if (_buf.isEmpty) return;
    _advancing = true;
    final batch = _buf.takeBytes();
    try {
      await _binding.advance(batch);
      final update = await _binding.takeDamage();
      _grid.apply(update);
    } finally {
      _advancing = false;
    }
    if (_buf.isNotEmpty) _scheduleDrain();
  }

  void resize(int columns, int rows) => _binding.resize(columns, rows);

  void dispose() => _binding.dispose();
}
```

- [ ] **Step 5: Run to verify pass**

Run: `flutter test test/engine_client_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/engine/engine_binding.dart lib/engine/terminal_engine_client.dart test/engine_client_test.dart
git commit -m "feat(engine): per-frame coalescing client with backpressure"
```

---

## Task 9: Dart — FrbEngineBinding + wire TerminalScreen (title/bell, cols fix)

**Files:**
- Modify: `lib/engine/engine_binding.dart` (add `FrbEngineBinding`)
- Rewrite: `lib/ui/terminal_screen.dart`

- [ ] **Step 1: Implement the FRB-backed binding + event routing**

Append to `lib/engine/engine_binding.dart`:
```dart
import 'dart:async';

import '../src/rust/api/terminal.dart';
import '../src/rust/event_proxy.dart';

/// FRB-backed binding. Owns the engine handle, translates FRB [RenderUpdate]
/// into native [GridUpdate], and exposes the terminal→host event stream.
class FrbEngineBinding implements EngineBinding {
  FrbEngineBinding({required int columns, required int rows})
      : _engine = engineNew(columns: columns, rows: rows) {
    // Adapt to the generated sink/stream signature (see Task 4 Step 4).
  }

  final TerminalEngine _engine;
  StreamSubscription<EngineEvent>? _eventSub;

  /// Wire terminal→host events. `onPtyWrite` must forward to the PTY.
  void listenEvents({
    required void Function(Uint8List) onPtyWrite,
    required void Function(String) onTitle,
    required void Function() onBell,
    required void Function(String) onClipboard,
  }) {
    // _eventSub = <engine event stream from Task 4>.listen((e) { ... dispatch ... });
  }

  @override
  Future<void> advance(Uint8List bytes) => engineAdvance(engine: _engine, bytes: bytes);

  @override
  Future<GridUpdate> takeDamage() async =>
      _toGridUpdate(await engineTakeDamage(engine: _engine));

  GridUpdate fullSnapshot() => _toGridUpdate(engineFullSnapshot(engine: _engine));

  @override
  void resize(int columns, int rows) =>
      engineResize(engine: _engine, columns: columns, rows: rows);

  @override
  void dispose() {
    _eventSub?.cancel();
  }

  GridUpdate _toGridUpdate(RenderUpdate u) => GridUpdate(
        full: u.full,
        rows: u.lines.isNotEmpty ? _maxLine(u) + 1 : 0,
        columns: u.lines.isNotEmpty ? u.lines.first.cells.length : 0,
        cursorRow: u.cursorLine,
        cursorCol: u.cursorCol,
        cursorVisible: u.cursorVisible,
        lines: u.lines
            .map((l) => LineCells(
                  line: l.line,
                  codepoints: Int32List.fromList(l.cells.map((c) => c.codepoint).toList()),
                  fg: Int32List.fromList(l.cells.map((c) => c.fg).toList()),
                  bg: Int32List.fromList(l.cells.map((c) => c.bg).toList()),
                ))
            .toList(),
      );

  int _maxLine(RenderUpdate u) => u.lines.map((l) => l.line).reduce((a, b) => a > b ? a : b);
}
```
> Add `import 'dart:typed_data';` at the top of the file. The `rows`/`columns` derivation for the `full` path uses the engine's reported lines; for incremental updates the `MirrorGrid` keeps its existing size (the `apply` only resizes on `full`). Finalize the `engineNew` sink wiring and `listenEvents` stream per the actual generated signature from Task 4 Step 4.

- [ ] **Step 2: Rewrite TerminalScreen to host the client**

Replace `lib/ui/terminal_screen.dart` with:
```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine_binding.dart';
import '../engine/terminal_engine_client.dart';
import '../input/key_input.dart';
import '../pty/flutter_pty_backend.dart';
import '../pty/pty_backend.dart';
import '../render/cell_metrics.dart';
import '../render/glyph_cache.dart';
import '../render/mirror_grid.dart';
import '../render/terminal_painter.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const _style = kTerminalTextStyle;
  late final CellMetrics _metrics = CellMetrics.measure(_style);
  late final GlyphCache _glyphs = GlyphCache(
    fontFamily: _style.fontFamily!,
    fontSize: _style.fontSize!,
    cellWidth: _metrics.width,
  );

  final MirrorGrid _grid = MirrorGrid();
  final FocusNode _focus = FocusNode();
  final ValueNotifier<String> _title = ValueNotifier('flutter_alacritty');

  FrbEngineBinding? _binding;
  TerminalEngineClient? _client;
  PtyBackend? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  int _cols = 0, _rows = 0;

  void _ensureStarted(int cols, int rows) {
    if (_client != null) {
      if (cols != _cols || rows != _rows) {
        _cols = cols;
        _rows = rows;
        _client!.resize(cols, rows);
        _pty!.resize(rows, cols);
      }
      return;
    }
    _cols = cols;
    _rows = rows;

    final pty = FlutterPtyBackend(rows: rows, columns: cols);
    final binding = FrbEngineBinding(columns: cols, rows: rows);
    binding.listenEvents(
      onPtyWrite: (bytes) => pty.write(bytes),
      onTitle: (t) => _title.value = t,
      onBell: _flashBell,
      onClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
    );

    _pty = pty;
    _binding = binding;
    _client = TerminalEngineClient(binding: binding, grid: _grid);
    _grid.apply(binding.fullSnapshot()); // first frame
    _outputSub = pty.output.listen(_client!.feed);
  }

  void _flashBell() {/* sub-project C may add a real flash; A: hook present */}

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final bytes = encodeKey(event.logicalKey, event.character, ctrl: ctrl);
    if (bytes == null) return KeyEventResult.ignored;
    _pty?.write(bytes);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _pty?.kill();
    _client?.dispose();
    _grid.dispose();
    _title.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cols = (constraints.maxWidth / _metrics.width).floor().clamp(1, 1000);
          final rows = (constraints.maxHeight / _metrics.height).floor().clamp(1, 1000);
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted(cols, rows));
          return Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: GestureDetector(
              onTap: _focus.requestFocus,
              child: CustomPaint(
                size: Size.infinite,
                painter: TerminalPainter(
                  grid: _grid,
                  glyphs: _glyphs,
                  cellWidth: _metrics.width,
                  cellHeight: _metrics.height,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 3: Verify analysis + full test suite**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all Dart tests pass (mirror_grid, glyph_cache, engine_client, key_input, engine_bindings, widget placeholder).

- [ ] **Step 4: Commit**

```bash
git add lib/engine/engine_binding.dart lib/ui/terminal_screen.dart
git commit -m "feat: route events + wire coalescing client into TerminalScreen"
```

---

## Task 10: Manual acceptance gate + findings

**Files:**
- Create: `docs/superpowers/plans/2026-05-27-plan2a-findings.md`

- [ ] **Step 1: Build and run on Linux**

Run:
```bash
flutter run -d linux
```

- [ ] **Step 2: Walk the acceptance checklist** (record pass/fail)
- [ ] `cat` a large file / `yes | head -n 100000` — UI stays responsive, no freeze, Ctrl-C still interrupts.
- [ ] `vim` scroll + `htop` — smooth, no jank.
- [ ] Query path: `printf '\e[6n'; read -r -d R x; echo "$x" | cat -v` returns a `[row;colR` cursor report (PtyWrite back-channel works); or `vim` opens cleanly (issues DA).
- [ ] `printf '\e]0;hi\a'` — window title becomes "hi".
- [ ] `printf '\a'` — bell hook fires (logged/flash).
- [ ] OSC52 copy lands in the system clipboard.
- [ ] Full-width ruler `printf '%*s\n' "$(tput cols)" '' | tr ' ' '-'` aligns to the right edge (cols correct). Record whether the earlier right-edge artifact is gone.

- [ ] **Step 3: Record findings + Plan-2B inputs**

Create `docs/superpowers/plans/2026-05-27-plan2a-findings.md` capturing: checklist results; observed heavy-output smoothness (subjective/jank); whether `engine_advance`+`engine_take_damage` two-hop cost is noticeable; cols-artifact outcome; any FRB sink/stream signature adjustments made vs this plan; any `alacritty_terminal` API deltas; carry-over notes for sub-projects B/C.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-05-27-plan2a-findings.md
git commit -m "docs: Plan 2A acceptance findings + carry-over notes"
```

---

## Self-Review (completed by author)

- **Spec coverage:** async advance off UI thread + coalescing/backpressure (Task 8); damage incremental via `term.damage()`/`reset_damage()` (Task 3); event back-channel `PtyWrite`/`Title`/`ResetTitle`/`Bell`/`ClipboardStore` (Tasks 2, 4, 9); glyph cache (Task 6) + mutable MirrorGrid (Task 5) + painter (Task 7); cols sub-pixel fix (Task 7) + ruler verification (Task 10); error-handling `catch_unwind` — **gap noted**: not yet a dedicated task → see "Added" below; acceptance (Task 10). Deliberate deferrals (ColorRequest/TextAreaSizeRequest no-op; ClipboardLoad empty) are documented in the header.
- **Added for coverage:** the spec's FFI-panic `catch_unwind` (§6) is folded into Task 4 — wrap the bodies of `engine_advance`/`engine_take_damage` in `std::panic::catch_unwind` (the engine is `RefUnwindSafe` via `AssertUnwindSafe`) returning normally on panic; add a Rust unit test feeding a deliberately malformed long sequence and asserting no panic escapes. Implementer: add this as Task 4 Step 0 (before the API rewrite) or a follow-up commit.
- **Placeholder scan:** the only deferred-to-runtime detail is the FRB-generated sink/stream signature (Task 4 Step 4 / Task 9 Step 1), which genuinely must be read from codegen output; every other step has complete code.
- **Type consistency:** `RenderUpdate{lines,full,cursor_line,cursor_col,cursor_visible}`, `LineUpdate{line,cells}`, `CellData{codepoint,fg,bg,flags}` consistent Rust↔FRB↔Dart. Dart `GridUpdate`/`LineCells` fields match between MirrorGrid (Task 5), client/test (Task 8), and `_toGridUpdate` (Task 9). `engineNew/engineAdvance/engineTakeDamage/engineFullSnapshot/engineResize` names consistent (Tasks 4, 9). `GlyphCache.get(codepoint, fg)` matches between Task 6 and Task 7.
```
