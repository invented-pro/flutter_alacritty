# Plan 2N — Live Color Resolution + Chrome Sync + OSC Color-Query Replies — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make runtime OSC color changes (4/10/11/12 SET, 104/110/111/112 RESET) actually paint, and answer OSC color *queries* instead of dropping them.

**Architecture:** Mirror alacritty's model — the snapshot resolves every color from live `term.colors()[i].unwrap_or(config_palette[i])` instead of a static palette, and carries the few chrome colors Dart paints itself (default fg/bg, cursor) in the `RenderUpdate` header. OSC color *queries* (`ColorRequest`) carry an `Arc<dyn Fn(Rgb)->String>` formatter that can't cross FFI, so the proxy stashes them in a side queue that the engine drains *after* parsing and resolves into ordinary `PtyWrite` replies.

**Tech Stack:** Rust (`alacritty_terminal`), flutter_rust_bridge 2.12.0, Dart/Flutter.

**Spec:** `docs/superpowers/specs/2026-05-29-plan2n-live-color-sync-design.md`

**Branch:** `feature/N-live-color-sync` (already exists, off `main` @ `068db4d`).

---

## File Structure

**Commit 1 (Rust + codegen):**
- Modify `packages/rust_lib_flutter_alacritty/rust/src/event_proxy.rs` — `ColorReply` struct, `pending_replies` queue, route `Event::ColorRequest` into it.
- Modify `packages/rust_lib_flutter_alacritty/rust/src/engine.rs` — `live()` helper, reroute `ansi16`/`resolve_named`/blank-cell + chrome header fields on `RenderUpdate`, drain `pending_replies` in `advance`, `CURSOR_COLOR_UNSET` const, `unpack`/`config_default_rgb`/`query_color_rgb`.
- Modify `packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs` — add the 3 new fields to the panic-fallback `RenderUpdate` literal.
- Regenerated: `lib/src/rust/engine.dart` + `lib/src/rust/frb_generated.dart` (via codegen).

**Commit 2 (Dart):**
- Modify `lib/engine/engine_binding.dart` — map new `RenderUpdate` fields into `GridUpdate`.
- Modify `lib/render/mirror_grid.dart` — `GridUpdate` chrome fields, mutable `_defaultFg/_defaultBg`, `_cursorColor` + `cursorColor` getter on `TerminalGridView`/`MirrorGrid`.
- Modify `lib/render/terminal_painter.dart` — cursor ink honors `grid.cursorColor` unless sentinel.
- Tests: `packages/.../rust/src/engine.rs` (`#[cfg(test)]`), `test/mirror_grid_test.dart`, `test/terminal_painter_*` (or a new `test/cursor_color_test.dart`).

---

## Task 0: Baseline

**Files:** none (verification only).

- [ ] **Step 1: Confirm branch + clean tree**

Run: `cd /home/hhoa/git/hhoa/flutter_alacritty && git branch --show-current && git status --porcelain`
Expected: `feature/N-live-color-sync`; no modifications to `lib/` or `packages/` (a dirty `.metadata` is fine).

- [ ] **Step 2: Baseline Rust tests green**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test 2>&1 | tail -5`
Expected: `test result: ok.` — record the count.

- [ ] **Step 3: Baseline Dart tests green**

Run: `cd /home/hhoa/git/hhoa/flutter_alacritty && flutter test 2>&1 | tail -3`
Expected: `All tests passed!`

---

## Task 1: Rust — live color resolution + OSC color-query replies (Commit 1)

**Files:**
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/event_proxy.rs`
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/engine.rs`
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs`
- Test: same files' `#[cfg(test)]` modules.

All Rust unit tests run with `cargo test` from `packages/rust_lib_flutter_alacritty/rust` — no dylib/codegen needed until Step 14.

### Part A — chrome header fields + live cell colors

- [ ] **Step 1: Write the failing test (OSC 11 SET drives snapshot.default_bg + cells)**

Add to the `tests` module in `engine.rs` (after the existing `engine`/`line`/`ch` helpers):

```rust
#[test]
fn osc11_set_changes_default_bg_and_cells() {
    let mut e = engine(10, 3);
    // OSC 11 ; rgb:ff/00/00  (set default background to pure red), ST-terminated.
    e.advance(b"\x1b]11;rgb:ff/00/00\x1b\\".to_vec());
    let u = e.full_snapshot();
    assert_eq!(u.default_bg, 0x00FF_0000, "chrome default_bg follows OSC 11");
    // A blank cell (no explicit bg) must repack to the live default bg.
    assert_eq!(line(&u, 0).cells[0].bg, 0x00FF_0000, "blank cell uses live bg");
}

#[test]
fn osc111_reset_reverts_default_bg_to_config() {
    let mut e = engine(10, 3);
    e.advance(b"\x1b]11;rgb:ff/00/00\x1b\\".to_vec());
    e.advance(b"\x1b]111\x1b\\".to_vec()); // reset default background
    let u = e.full_snapshot();
    assert_eq!(u.default_bg, EngineConfig::default_palette()[17]);
}

#[test]
fn cursor_color_unset_sentinel_then_osc12() {
    let mut e = engine(10, 3);
    assert_eq!(e.full_snapshot().cursor_color, CURSOR_COLOR_UNSET);
    e.advance(b"\x1b]12;rgb:00/ff/00\x1b\\".to_vec()); // set cursor color green
    assert_eq!(e.full_snapshot().cursor_color, 0x0000_FF00);
}
```

- [ ] **Step 2: Run to verify it fails (compile error — fields don't exist)**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test osc11_set_changes_default_bg_and_cells 2>&1 | tail -15`
Expected: FAIL — `no field 'default_bg' on type '&RenderUpdate'` and `cannot find value 'CURSOR_COLOR_UNSET'`.

- [ ] **Step 3: Add the sentinel const + unpack + live helper**

In `engine.rs`, near the other color consts/helpers (after `DEFAULT_BG` at line 89 and the `pack` fn at line 91):

```rust
/// Sentinel `cursor_color` when no program has set OSC 12. Impossible as a
/// real packed color (`pack` always yields `0x00RRGGBB`), so Dart can
/// distinguish "unset → keep inverse-video cursor" from a real cursor color.
pub const CURSOR_COLOR_UNSET: u32 = 0xFF00_0000;

fn unpack(v: u32) -> Rgb {
    Rgb { r: (v >> 16) as u8, g: (v >> 8) as u8, b: v as u8 }
}
```

Then add these methods inside `impl TerminalEngine` (place them next to `resolve_color`, around line 470):

```rust
/// Live packed color for an alacritty color-array slot, honoring runtime
/// OSC SET. Falls back to our static config palette value when unset.
/// Mirrors alacritty `display/content.rs`: `colors[i].unwrap_or(config[i])`.
fn live(&self, idx: usize, fallback: u32) -> u32 {
    match self.term.colors()[idx] {
        Some(c) => pack(c.r, c.g, c.b),
        None => fallback,
    }
}

fn live_named(&self, n: NamedColor, fallback: u32) -> u32 {
    self.live(n as usize, fallback)
}
```

- [ ] **Step 4: Route cell color resolution through `live`**

In `engine.rs`, change `ansi16` (line 415) so ANSI 0–15 (the OSC 4 targets, also used by every named ANSI color via `resolve_named`) honor live SET:

```rust
fn ansi16(&self, i: u8) -> u32 {
    self.live(i as usize, self.palette[i as usize])
}
```

In `resolve_named` (line 437), change the three default slots to read live (leave the `ansi16`-delegating arms as-is — they now pick up live values automatically):

```rust
Foreground | BrightForeground => self.live_named(NamedColor::Foreground, self.palette[16]),
Background => self.live_named(NamedColor::Background, self.palette[17]),
// ...unchanged Black..BrightWhite arms (they call self.ansi16(..))...
Cursor => self.live_named(NamedColor::Cursor, self.palette[16]),
// ...unchanged Dim* arms...
DimForeground => self.live_named(NamedColor::Foreground, self.palette[16]),
```

In `full_snapshot` (line 524), change the blank-cell fill to live:

```rust
let blank = CellData {
    codepoint: ' ' as u32,
    fg: self.live_named(NamedColor::Foreground, self.palette[16]),
    bg: self.live_named(NamedColor::Background, self.palette[17]),
    flags: 0,
    hyperlink_id: 0,
};
```

- [ ] **Step 5: Add the 3 chrome fields to `RenderUpdate` + populate all literals**

In `engine.rs`, extend the struct (line 30):

```rust
#[derive(Clone, Debug)]
pub struct RenderUpdate {
    pub lines: Vec<LineUpdate>,
    pub full: bool,
    pub cursor_line: u32,
    pub cursor_col: u32,
    pub cursor_visible: bool,
    pub cursor_shape: u8,
    pub cursor_blinking: bool,
    pub mode_flags: u32,
    pub display_offset: u32,
    pub default_fg: u32,
    pub default_bg: u32,
    pub cursor_color: u32,
}
```

Add a small helper inside `impl TerminalEngine` to compute the trio once:

```rust
/// (default_fg, default_bg, cursor_color) for the snapshot chrome header.
/// cursor_color is CURSOR_COLOR_UNSET unless a program set OSC 12.
fn chrome_colors(&self) -> (u32, u32, u32) {
    let cursor_color = match self.term.colors()[NamedColor::Cursor as usize] {
        Some(c) => pack(c.r, c.g, c.b),
        None => CURSOR_COLOR_UNSET,
    };
    (
        self.live_named(NamedColor::Foreground, self.palette[16]),
        self.live_named(NamedColor::Background, self.palette[17]),
        cursor_color,
    )
}
```

Populate the `full_snapshot` literal (line 566):

```rust
let (default_fg, default_bg, cursor_color) = self.chrome_colors();
RenderUpdate {
    lines,
    full: true,
    cursor_line,
    cursor_col,
    cursor_visible: cursor_visible && display_offset == 0,
    cursor_shape,
    cursor_blinking,
    mode_flags: self.term.mode().bits(),
    display_offset: display_offset as u32,
    default_fg,
    default_bg,
    cursor_color,
}
```

Populate the `take_damage` `Some(rows)` literal (line 614):

```rust
let (default_fg, default_bg, cursor_color) = self.chrome_colors();
RenderUpdate {
    lines,
    full: false,
    cursor_line,
    cursor_col,
    cursor_visible,
    cursor_shape,
    cursor_blinking,
    mode_flags: self.term.mode().bits(),
    display_offset: 0,
    default_fg,
    default_bg,
    cursor_color,
}
```

(The `take_damage` `None` branch reuses `full_snapshot`, so it's already covered.)

- [ ] **Step 6: Populate the api panic-fallback literal**

In `api/terminal.rs`, the `engine_take_damage` panic fallback (line 22) must compile with the new fields:

```rust
RenderUpdate {
    lines: Vec::new(),
    full: false,
    cursor_line: 0,
    cursor_col: 0,
    cursor_visible: false,
    cursor_shape: 0,
    cursor_blinking: false,
    mode_flags: 0,
    display_offset: 0,
    default_fg: crate::engine::EngineConfig::default_palette()[16],
    default_bg: crate::engine::EngineConfig::default_palette()[17],
    cursor_color: crate::engine::CURSOR_COLOR_UNSET,
}
```

- [ ] **Step 7: Run Part-A tests to verify they pass**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test osc11_set_changes_default_bg_and_cells osc111_reset_reverts_default_bg_to_config cursor_color_unset_sentinel_then_osc12 2>&1 | tail -10`
Expected: PASS (3 tests). Also run the full suite: `cargo test 2>&1 | tail -5` → `ok` (no regressions; existing color tests still pass because all live colors are `None` → same palette fallback).

### Part B — OSC color-query replies

- [ ] **Step 8: Write the failing test (ColorRequest → PtyWrite reply)**

Add to the `tests` module in `engine.rs`:

```rust
fn pty_writes(e: &TerminalEngine) -> Vec<Vec<u8>> {
    e.take_events()
        .into_iter()
        .filter_map(|ev| match ev {
            EngineEvent::PtyWrite(b) => Some(b),
            _ => None,
        })
        .collect()
}

#[test]
fn osc11_query_emits_background_reply() {
    let mut e = engine(10, 3);
    e.advance(b"\x1b]11;?\x1b\\".to_vec()); // query default background
    let writes = pty_writes(&e);
    assert_eq!(writes.len(), 1, "exactly one reply");
    assert!(
        writes[0].starts_with(b"\x1b]11;rgb:"),
        "OSC 11 reply prefix, got {:?}",
        String::from_utf8_lossy(&writes[0])
    );
}

#[test]
fn osc11_query_reflects_live_color() {
    let mut e = engine(10, 3);
    e.advance(b"\x1b]11;rgb:ff/00/00\x1b\\".to_vec()); // set red
    let _ = e.take_events(); // drain set (no reply for SET)
    e.advance(b"\x1b]11;?\x1b\\".to_vec()); // query
    let writes = pty_writes(&e);
    let s = String::from_utf8_lossy(&writes[0]);
    assert!(s.contains("rgb:ffff/0000/0000"), "reply carries SET value, got {s}");
}

#[test]
fn osc12_query_ignored_when_cursor_unset() {
    let mut e = engine(10, 3);
    e.advance(b"\x1b]12;?\x1b\\".to_vec()); // query cursor color, never set
    assert!(pty_writes(&e).is_empty(), "unset cursor query is dropped (alacritty parity)");
}
```

- [ ] **Step 9: Run to verify it fails**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test osc11_query_emits_background_reply 2>&1 | tail -15`
Expected: FAIL — `writes.len()` is `0` (ColorRequest is currently dropped by `_ => {}`).

- [ ] **Step 10: Add `ColorReply` + `pending_replies` to the proxy**

In `event_proxy.rs`, add the imports and types (top of file):

```rust
use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::vte::ansi::Rgb;

/// A deferred OSC color-query reply. The formatter is alacritty's own reply
/// builder; we feed it the current color after parsing finishes (the proxy
/// can't read term state during `parser.advance`). Not serializable — never
/// part of `EngineEvent`.
#[derive(Clone)]
pub struct ColorReply {
    pub index: usize,
    pub formatter: Arc<dyn Fn(Rgb) -> String + Send + Sync>,
}

/// Side queue of pending color-query replies (parallel to `EventQueue`).
pub type ReplyQueue = Arc<Mutex<Vec<ColorReply>>>;
```

Extend `EventProxy` to hold both queues:

```rust
#[derive(Clone)]
pub struct EventProxy {
    queue: EventQueue,
    replies: ReplyQueue,
}

impl EventProxy {
    pub fn new(queue: EventQueue, replies: ReplyQueue) -> Self {
        Self { queue, replies }
    }
    fn emit(&self, e: EngineEvent) {
        self.queue.lock().unwrap().push(e);
    }
}
```

In `send_event`, replace the `_ => {}` arm region so `ColorRequest` is captured (keep `ClipboardLoad` answering empty; everything else still drops):

```rust
            // App reads clipboard (OSC52 paste): answer empty for now (2N-b).
            Event::ClipboardLoad(_, format) => {
                self.emit(EngineEvent::PtyWrite(format("").into_bytes()))
            }
            // OSC 4/10/11/12 query: stash for post-advance resolution (the proxy
            // has no color state mid-parse). Resolved by the engine into PtyWrite.
            Event::ColorRequest(index, formatter) => {
                self.replies.lock().unwrap().push(ColorReply { index, formatter });
            }
            // TextAreaSizeRequest / CursorBlinkingChange / MouseCursorDirty /
            // Wakeup / Exit / ChildExit — out of 2N scope (see 2N-b).
            _ => {}
```

Update the two existing proxy tests' `collector()` to pass a replies queue:

```rust
    fn collector() -> (EventProxy, EventQueue) {
        let store: EventQueue = Arc::new(Mutex::new(Vec::new()));
        let replies: ReplyQueue = Arc::new(Mutex::new(Vec::new()));
        (EventProxy::new(store.clone(), replies), store)
    }
```

- [ ] **Step 11: Hold `replies` on the engine + construct the proxy with it**

In `engine.rs`, import the new types (line 4):

```rust
use crate::event_proxy::{ColorReply, EngineEvent, EventProxy, EventQueue, ReplyQueue};
```

Add a field to `TerminalEngine` (after `events: EventQueue,` line 151):

```rust
    replies: ReplyQueue,
```

In `TerminalEngine::new`, create the reply queue and pass it to the proxy (around line 171–176):

```rust
        let events: EventQueue = Arc::new(Mutex::new(Vec::new()));
        let replies: ReplyQueue = Arc::new(Mutex::new(Vec::new()));
        let term_config = Config {
            scrolling_history: config.scrollback as usize,
            ..Default::default()
        };
        let mut term = Term::new(term_config, &size, EventProxy::new(events.clone(), replies.clone()));
```

Add `replies` to the struct initializer (after `events,` around line 183):

```rust
            events,
            replies,
```

- [ ] **Step 12: Resolve replies after parsing in `advance`**

First add the resolver methods inside `impl TerminalEngine` (next to `live`/`chrome_colors`):

```rust
/// Config-default Rgb for an OSC color index (used when term.colors[i] is
/// unset). Mirrors alacritty's `display.colors[index]` fallback table, scoped
/// to the indices our compact palette covers.
fn config_default_rgb(&self, index: usize) -> Rgb {
    let packed = match index {
        0..=15 => self.palette[index],
        16..=255 => self.xterm256(index as u8),
        i if i == NamedColor::Foreground as usize => self.palette[16],
        i if i == NamedColor::Background as usize => self.palette[17],
        _ => self.palette[16],
    };
    unpack(packed)
}

/// Current Rgb for an OSC color query. `None` => emit no reply (matches
/// alacritty: an unset cursor-color query is ignored).
fn query_color_rgb(&self, index: usize) -> Option<Rgb> {
    match self.term.colors()[index] {
        Some(c) => Some(c),
        None if index == NamedColor::Cursor as usize => None,
        None => Some(self.config_default_rgb(index)),
    }
}

/// Drain pending OSC color queries into PtyWrite replies. Called after the
/// parser has finished (term no longer mutably borrowed by `parser.advance`).
fn resolve_pending_replies(&mut self) {
    let pending = std::mem::take(&mut *self.replies.lock().unwrap());
    for r in pending {
        if let Some(rgb) = self.query_color_rgb(r.index) {
            let bytes = (r.formatter)(rgb).into_bytes();
            self.events.lock().unwrap().push(EngineEvent::PtyWrite(bytes));
        }
    }
}
```

Then call it at the end of `advance` (line 197):

```rust
pub fn advance(&mut self, bytes: Vec<u8>) {
    self.parser.advance(&mut self.term, &bytes);
    self.resolve_pending_replies();
}
```

- [ ] **Step 13: Run Part-B tests + full Rust suite**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test 2>&1 | tail -8`
Expected: PASS — the 3 new query tests, the 3 Part-A tests, and all pre-existing tests (`test result: ok`).

- [ ] **Step 14: Regenerate FRB bindings + rebuild the dylib**

The new `RenderUpdate` fields must appear in the Dart mirror, and the debug dylib must be rebuilt so Dart tests load the new struct layout.

Run:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen generate
cargo build --manifest-path packages/rust_lib_flutter_alacritty/rust/Cargo.toml
```
Expected: codegen rewrites `lib/src/rust/engine.dart` (now with `defaultFg`/`defaultBg`/`cursorColor`) and `lib/src/rust/frb_generated.dart`; cargo build succeeds.
Verify: `grep -c "cursorColor" lib/src/rust/engine.dart` → ≥ 1.

> If `flutter_rust_bridge_codegen` is not on PATH, install the pinned version: `cargo install flutter_rust_bridge_codegen --version 2.12.0`.

- [ ] **Step 15: Confirm Dart still compiles (no consumer of new fields yet)**

Run: `flutter analyze lib/src/rust 2>&1 | tail -5`
Expected: no errors (new fields are additive; nothing reads them yet).

- [ ] **Step 16: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git add packages/rust_lib_flutter_alacritty/rust/src/engine.rs \
        packages/rust_lib_flutter_alacritty/rust/src/event_proxy.rs \
        packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs \
        lib/src/rust/engine.dart lib/src/rust/frb_generated.dart
git commit -m "$(cat <<'EOF'
feat(engine): resolve colors from live term.colors + answer OSC color queries

Cell + chrome colors now resolve from term.colors()[i].unwrap_or(palette[i])
so OSC 4/10/11/12 SET and 104/110/111/112 RESET take effect (pywal, vim
colorschemes, theme-switch escapes). RenderUpdate gains default_fg/default_bg/
cursor_color (cursor_color = CURSOR_COLOR_UNSET sentinel unless OSC 12 set).

OSC color *queries* (Event::ColorRequest) were dropped by the proxy's _ => {}.
The Arc<Fn(Rgb)->String> formatter can't cross FFI, so the proxy stashes it in
a side ReplyQueue; advance() drains it after parsing and resolves each into a
PtyWrite reply (unset cursor query ignored, matching alacritty).

Plan 2N commit 1.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Dart — paint chrome from snapshot colors (Commit 2)

**Files:**
- Modify: `lib/render/mirror_grid.dart`
- Modify: `lib/engine/engine_binding.dart`
- Modify: `lib/render/terminal_painter.dart`
- Test: `test/mirror_grid_test.dart`, new `test/cursor_color_test.dart`

### Part A — plumb chrome through GridUpdate + MirrorGrid

- [ ] **Step 1: Write the failing test (MirrorGrid exposes cursorColor + live default bg)**

Add to `test/mirror_grid_test.dart` (match the existing `GridUpdate(...)` construction style used in that file):

```dart
test('apply carries chrome colors; grown cells use live default bg', () {
  final grid = MirrorGrid();
  grid.apply(GridUpdate(
    full: true,
    rows: 1,
    columns: 2,
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: true,
    defaultFg: 0x00FF00,
    defaultBg: 0xFF0000,
    cursorColor: 0x0000FF,
    lines: const [],
  ));
  // Empty/untouched cells (no line deltas) fill from the live default bg.
  expect(grid.bgAt(0, 0), 0xFF0000);
  expect(grid.cursorColor, 0x0000FF);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /home/hhoa/git/hhoa/flutter_alacritty && flutter test test/mirror_grid_test.dart 2>&1 | tail -15`
Expected: FAIL — `No named parameter 'defaultFg'` / `The getter 'cursorColor' isn't defined`.

- [ ] **Step 3: Add chrome fields to `GridUpdate`**

In `lib/render/mirror_grid.dart`, extend the `GridUpdate` constructor + fields (lines 26–51). `cursorColor` defaults to the sentinel so existing call sites/tests compile unchanged:

```dart
class GridUpdate {
  GridUpdate({
    required this.full,
    required this.rows,
    required this.columns,
    required this.lines,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorVisible,
    this.cursorShape = 0,
    this.cursorBlinking = false,
    this.modeFlags = 0,
    this.displayOffset = 0,
    this.defaultFg = 0xD8D8D8,
    this.defaultBg = 0x181818,
    this.cursorColor = 0xFF000000,
  });
  final bool full;
  final int rows;
  final int columns;
  final List<LineCells> lines;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
  final int cursorShape;
  final bool cursorBlinking;
  final int modeFlags;
  final int displayOffset;
  final int defaultFg;
  final int defaultBg;
  final int cursorColor;
}
```

- [ ] **Step 4: Add `cursorColor` to the read-only view interface**

In `lib/render/mirror_grid.dart`, add to `TerminalGridView` (after `int get displayOffset;`, line 71):

```dart
  /// Program-set cursor color (OSC 12), or 0xFF000000 ([kCursorColorUnset]) when
  /// unset — in which case painters keep their inverse-video cursor.
  int get cursorColor;
```

Add the sentinel const at top of file (after imports):

```dart
/// Sentinel `cursorColor` meaning "no OSC 12 set" (matches Rust CURSOR_COLOR_UNSET).
const int kCursorColorUnset = 0xFF000000;
```

- [ ] **Step 5: Make MirrorGrid track live defaults + cursorColor**

In `lib/render/mirror_grid.dart`: make `_defaultFg`/`_defaultBg` mutable, add `_cursorColor`, its getter, and update all three in `apply`.

Change the field declarations (lines 95–96) and add cursor color state:

```dart
  int _defaultFg;
  int _defaultBg;
  int _cursorColor = kCursorColorUnset;
```

(The constructor at line 91–93 already initializes `_defaultFg`/`_defaultBg`; mutability is the only change.)

Add the getter (after `displayOffset` getter, line 134):

```dart
  @override
  int get cursorColor => _cursorColor;
```

In `apply`, update the chrome state. Place these lines at the very top of `apply` (before the `if (u.full)` block, line 169) so newly-grown cells in `_ensureSize` pick up the live default:

```dart
  void apply(GridUpdate u) {
    _defaultFg = u.defaultFg;
    _defaultBg = u.defaultBg;
    _cursorColor = u.cursorColor;
```

- [ ] **Step 6: Map the new FRB fields in the binding**

In `lib/engine/engine_binding.dart`, add the three fields to the `GridUpdate(...)` built by `_toGridUpdate` (after `displayOffset: u.displayOffset,`, line 171):

```dart
        displayOffset: u.displayOffset,
        defaultFg: u.defaultFg,
        defaultBg: u.defaultBg,
        cursorColor: u.cursorColor,
        lines: u.lines.map(_lineCells).toList(),
```

- [ ] **Step 7: Run Part-A test + full Dart suite**

Run: `cd /home/hhoa/git/hhoa/flutter_alacritty && flutter test test/mirror_grid_test.dart 2>&1 | tail -5`
Expected: PASS. Then `flutter test 2>&1 | tail -3` → `All tests passed!` (the `cursorColor` default keeps existing `GridUpdate` constructions valid).

### Part B — cursor honors OSC 12

- [ ] **Step 8: Write the failing test (cursor ink uses cursorColor unless sentinel)**

The painter's cursor-ink decision is inline in `paint()`. Extract it to a tiny pure helper so it's unit-testable, then test the helper. Create `test/cursor_color_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

void main() {
  test('cursorInk falls back to inverse fg when unset', () {
    final ink = cursorInk(kCursorColorUnset, 0x00D8D8D8);
    expect(ink, const Color(0xFFD8D8D8));
  });

  test('cursorInk uses the OSC 12 color when set', () {
    final ink = cursorInk(0x0000FF00, 0x00D8D8D8);
    expect(ink, const Color(0xFF00FF00));
  });
}
```

- [ ] **Step 9: Run to verify it fails**

Run: `cd /home/hhoa/git/hhoa/flutter_alacritty && flutter test test/cursor_color_test.dart 2>&1 | tail -10`
Expected: FAIL — `The function 'cursorInk' isn't defined`.

- [ ] **Step 10: Add the `cursorInk` helper**

In `lib/render/terminal_painter.dart`, add a top-level function (above the `TerminalPainter` class):

```dart
/// Cursor ink color: the program-set OSC 12 color when present, else an
/// inverse-video cursor using the cell's effective fg. [cursorColor] is the
/// raw snapshot value (0x00RRGGBB) or [kCursorColorUnset].
Color cursorInk(int cursorColor, int inverseFg) {
  if (cursorColor == kCursorColorUnset) {
    return Color(0xFF000000 | inverseFg);
  }
  return Color(0xFF000000 | (cursorColor & 0xFFFFFF));
}
```

- [ ] **Step 11: Use `cursorInk` in the cursor pass**

In `lib/render/terminal_painter.dart`, replace the inline ink computation in Pass 3 (line 211):

```dart
      final inkColor = cursorInk(grid.cursorColor, ec.fg);
```

(`mirror_grid.dart` is already imported by the painter; `kCursorColorUnset` resolves from it. The block-cursor glyph redraw keeps using `ec.bg` so text remains legible on a custom cursor color — acceptable per spec §2.)

- [ ] **Step 12: Run the cursor test + full suite**

Run: `cd /home/hhoa/git/hhoa/flutter_alacritty && flutter test test/cursor_color_test.dart 2>&1 | tail -5`
Expected: PASS. Then `flutter test 2>&1 | tail -3` → `All tests passed!`

- [ ] **Step 13: analyze clean**

Run: `flutter analyze 2>&1 | tail -5`
Expected: `No issues found!` (or unchanged from baseline).

- [ ] **Step 14: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git add lib/render/mirror_grid.dart lib/engine/engine_binding.dart \
        lib/render/terminal_painter.dart \
        test/mirror_grid_test.dart test/cursor_color_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): paint chrome from snapshot colors (OSC 10/11/12 follow)

GridUpdate/MirrorGrid carry default_fg/default_bg/cursor_color from the
snapshot. Newly-grown/empty cells now fill from the live default bg (OSC 11
follows on resize), and the cursor honors a program-set OSC 12 color via the
cursorInk helper, keeping inverse-video when unset (kCursorColorUnset).

Plan 2N commit 2.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Findings

**Files:** Create `docs/superpowers/plans/2026-05-29-plan2n-findings.md`

- [ ] **Step 1: Write findings**

Summarize: what shipped per commit; the live-resolution model (`term.colors().unwrap_or(palette)`, mirrors alacritty content.rs:105); the `RenderUpdate` chrome fields + `CURSOR_COLOR_UNSET` sentinel; the `ReplyQueue` side-channel for `ColorRequest` (formatter can't cross FFI → resolved in Rust → PtyWrite); manual verification (see Step 2); and deferred items carried to **2N-b** (ClipboardLoad/OSC-52 paste + gate, TextAreaSizeRequest + cell-pixel plumbing, CursorBlinkingChange, MouseCursorDirty, cursor-color config knob = 2O-b). Note the window/padding background was *not* repointed at the live default bg (the painter fills per-cell from the snapshot; padding bg is a small cosmetic follow-up if a real consumer needs it).

- [ ] **Step 2: Manual verification in the example app**

Run the example app and confirm by eye (these can't be unit-tested — they need a real PTY + GPU):
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty && flutter run -d linux
```
In the running terminal:
- `printf '\e]11;#ff0000\a'` → background turns red (existing text cells + newly-typed lines).
- `printf '\e]111\a'` (OSC 111) → reverts to config default. NOTE: `\e]11;\a` (empty OSC 11) does NOT reset — vte sends an empty color arg to `unhandled()` (vte ansi.rs:1444-1446), calling neither set_color nor reset_color. Only OSC 110/111/112 reset.
- `printf '\e]12;#00ff00\a'` → cursor turns green; without it the cursor is inverse-video.
- A program that queries (e.g. a script doing `printf '\e]11;?\a'; read -r reply` ) gets a reply instead of hanging.

Record results + any surprises in the findings doc.

- [ ] **Step 3: Update the roadmap memory**

Append a DONE entry for 2N to `/home/hhoa/.claude/projects/-home-hhoa-git-hhoa-flutter-alacritty/memory/flutter-alacritty-post-v1-roadmap.md` (commit hashes + the 2N-b carry-over list), and drop 2N from the "next pipeline" line (promote 2O).

- [ ] **Step 4: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git add docs/superpowers/plans/2026-05-29-plan2n-findings.md
git commit -m "docs(2N): findings — live color resolution + chrome sync + OSC query replies

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** §2 live resolution → Task 1 Steps 3–4; chrome header → Step 5; cursor sentinel → Steps 5,8–11; ColorRequest deferred-resolution → Steps 8–12; Dart chrome consumption → Task 2; non-goals (clipboard/size/cursor-blink/mouse/config-knob) → explicitly left on `_ => {}` (Step 10) + findings 2N-b list.
- **Type consistency:** `CURSOR_COLOR_UNSET`/`kCursorColorUnset` = `0xFF000000` on both sides; `RenderUpdate.{default_fg,default_bg,cursor_color}` → FRB `{defaultFg,defaultBg,cursorColor}` → `GridUpdate` same → `MirrorGrid.cursorColor`. `cursorInk(int cursorColor, int inverseFg)` signature matches its call site.
- **Edge handled:** the panic-fallback `RenderUpdate` literal (api/terminal.rs) is updated (Step 6) so the crate compiles; existing `GridUpdate` constructions stay valid via defaulted fields (Step 3).
