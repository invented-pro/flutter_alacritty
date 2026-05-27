# flutter_alacritty Plan 2A — Core Data Path

**Date:** 2026-05-27
**Status:** Design approved, pending spec review
**Branch:** `feature/tracer-bullet` (builds on the merged tracer bullet, Plan 1)

This is the **first** of five productionization sub-projects decomposed from "Plan 2".
The others — **B** input completeness, **C** rendering fidelity, **D** scrollback +
selection + copy/paste, **E** robustness/lifecycle — each get their own spec → plan →
implementation cycle. This doc covers **A only**.

---

## 1. Goal & Non-Goals

**Goal.** Turn the Plan-1 tracer-bullet data path into a production-grade one: parse off
the UI isolate, transfer only damaged lines across FFI, wire the terminal→host event
back-channel, and render cheaply via a glyph cache — so heavy output and scrolling stay
smooth and terminal queries get answered.

**In scope (A):**
- `engine_advance` runs off the UI isolate; PTY reads coalesced per frame with backpressure.
- Damage-based incremental updates (`term.damage()`/`reset_damage()`), viewport-relative.
- Event back-channel (`EngineEvent` stream): `PtyWrite` (correctness), `Title`/`ResetTitle`,
  `Bell`, `ClipboardStore`.
- Glyph cache in the painter; mutable `MirrorGrid` applying line deltas in place.
- Confirm and (if real) fix the cols off-by-one / right-edge artifact.

**Non-goals (deferred to later sub-projects):**
- Text attributes bold/italic/underline/inverse/dim, cursor styles/blink, wide-char/CJK
  rendering → **C**.
- Mode-aware key encoding, mouse reporting, bracketed paste → **B**.
- Scrollback view, selection, copy/paste → **D**.
- Shell-exit restart UX → **E** (A only forwards the relevant events/plumbing).
- App-driven clipboard *read* (`ClipboardLoad`/OSC52 paste) → answered empty in A.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Pipeline | **Approach 1**: FRB-async advance + per-frame coalescing + damage + glyph-cached full repaint |
| Threading | `engine_advance`/`engine_take_damage` are FRB **async** (Rust worker thread); engine stays a single `RustAutoOpaque` (RwLock-serialized). No dedicated Dart isolate |
| Damage | `term.damage()` → changed lines only (viewport-relative line indices) → `reset_damage()` after each read; `Full` ⇒ whole-viewport replace |
| Events | Forward via FRB `StreamSink<EngineEvent>`. `PtyWrite` is the correctness path (DSR/DA). Callback-style alacritty events resolved in Rust → `PtyWrite` |
| Rendering | Mutable `MirrorGrid` (per-line storage) + per-cell glyph cache; full-canvas repaint kept cheap. Attributes/cursor-styles stay out (sub-project C) |
| Acceptance | Full hard acceptance (perf + PtyWrite-via-DSR + Title/Bell/Clipboard + cols fix) |

## 3. Architecture & data flow

```
PTY output (flutter_pty)  — many Uint8List chunks, bursty
   │
   ▼
TerminalEngineClient  (NEW — extracted from TerminalScreen)
   │ ① append bytes to a BytesBuilder
   │ ② schedule one drain per frame (SchedulerBinding); `_advancing` flag prevents re-entry
   │    → bursts collapse to one batch/frame = natural backpressure
   ▼ await
engineAdvance(bytes)            FRB async → Rust worker thread (UI isolate free)
   │   processor.advance(&mut term, bytes);  EventProxy.send_event fires during parsing
   ▼ await
engineTakeDamage() → RenderUpdate { lines:[LineUpdate{line,cells}], full, cursor }
   │   term.damage() → changed lines (viewport coords); then term.reset_damage()
   ▼
MirrorGrid.applyLineUpdates(update)   mutate only named lines in place (or full replace)
   ▼ notifyListeners
TerminalPainter.paint   full canvas, every non-blank cell drawn from a cached ui.Paragraph

Event back-channel (parallel FRB stream):
engineEvents : Stream<EngineEvent> ─► TerminalEngineClient dispatch:
   PtyWrite(bytes)      → pty.write(bytes)            [DSR/DA responses — correctness]
   Title(s)/ResetTitle  → titleNotifier              [window title]
   Bell                 → bell flash/notify
   ClipboardStore(text) → Clipboard.setData
```

**Coalescing + backpressure algorithm (client):**
```
onOutput(bytes): _buf.add(bytes); _scheduleDrain()
_scheduleDrain(): if !_drainScheduled && !_advancing { _drainScheduled = true;
                  SchedulerBinding.addPostFrameCallback(_drain) }
_drain(): _drainScheduled = false; if _buf empty return;
          _advancing = true; final batch = _buf.takeBytes();
          await engineAdvance(batch); final u = await engineTakeDamage();
          _grid.applyLineUpdates(u); _advancing = false;
          if _buf not empty: _scheduleDrain()   // drain leftover next frame
```
This guarantees: at most one advance in flight, one batch per frame, leftover re-queued.

## 4. FRB API & types

> **Superseded during plan validation:** the `StreamSink` event delivery shown below was replaced with **per-frame polling** (`engine_take_events() -> Vec<EngineEvent>`, drained alongside `engine_take_damage` each frame). `engine_new` therefore keeps its simple `(columns, rows)` signature and the engine owns an `Arc<Mutex<Vec<EngineEvent>>>` queue. Rationale: FRB `StreamSink`-as-constructor-param is awkward and the client already drains per frame. See the implementation plan for the authoritative API.

```rust
// engine_new now takes the event sink so the EventProxy is wired at construction.
#[frb(sync)]
pub fn engine_new(columns: u16, rows: u16, sink: StreamSink<EngineEvent>) -> TerminalEngine;

pub async fn engine_advance(engine: &mut TerminalEngine, bytes: Vec<u8>);          // no #[frb(sync)]
pub async fn engine_take_damage(engine: &mut TerminalEngine) -> RenderUpdate;      // damage() needs &mut self

#[frb(sync)] pub fn engine_resize(engine: &mut TerminalEngine, columns: u16, rows: u16);
#[frb(sync)] pub fn engine_full_snapshot(engine: &TerminalEngine) -> RenderUpdate; // first frame / Full
#[frb(sync)] pub fn engine_mode_flags(engine: &TerminalEngine) -> u32;             // exposed now; used by B

// Types
pub enum EngineEvent {
    PtyWrite(Vec<u8>),
    Title(String),
    ResetTitle,
    Bell,
    ClipboardStore(String),
}
pub struct LineUpdate { pub line: u32, pub cells: Vec<CellData> } // CellData reused from Plan 1
pub struct RenderUpdate {
    pub lines: Vec<LineUpdate>,
    pub full: bool,
    pub cursor_line: u32,
    pub cursor_col: u32,
    pub cursor_visible: bool,
}
```

**EventProxy (replaces NoopListener), testable:**
```rust
pub struct EventProxy { sink: Box<dyn Fn(EngineEvent) + Send + Sync> }
impl EventProxy { pub fn new(f: impl Fn(EngineEvent) + Send + Sync + 'static) -> Self {...} }
impl EventListener for EventProxy {
    fn send_event(&self, event: Event) {
        match event {
            Event::PtyWrite(s)        => (self.sink)(EngineEvent::PtyWrite(s.into_bytes())),
            Event::Title(s)           => (self.sink)(EngineEvent::Title(s)),
            Event::ResetTitle         => (self.sink)(EngineEvent::ResetTitle),
            Event::Bell               => (self.sink)(EngineEvent::Bell),
            Event::ClipboardStore(_, s) => (self.sink)(EngineEvent::ClipboardStore(s)),
            // Callback-style requests: answer in Rust with known data, emit as PtyWrite.
            Event::ColorRequest(idx, f)        => (self.sink)(EngineEvent::PtyWrite(
                                                    f(self.color(idx)).into_bytes())),
            Event::TextAreaSizeRequest(f)      => (self.sink)(EngineEvent::PtyWrite(
                                                    f(self.window_size()).into_bytes())),
            Event::ClipboardLoad(_, f)         => (self.sink)(EngineEvent::PtyWrite(
                                                    f("").into_bytes())), // A: empty; full read → later
            _ => {} // MouseCursorDirty, CursorBlinkingChange, Wakeup, Exit, ChildExit (not used headless)
        }
    }
}
```
- Production wires `EventProxy::new(move |e| sink.add(e).ok())`. Tests wire it to a
  `Mutex<Vec<EngineEvent>>` collector — no FRB needed.
- `color(idx)`/`window_size()` read from the engine's stored palette and last-known size
  (size pushed from `engine_resize`; pixel dims default to cell-derived values for A).

## 5. Rendering changes

**`MirrorGrid` → mutable.** Replace the single immutable `MirrorSnapshot` with per-line
mutable storage (each line: `Int32List` codepoints + `Int32List` fg + `Int32List` bg, length
= columns). API: `applyLineUpdates(RenderUpdate)` mutates only `update.lines` (or replaces all
lines when `update.full`), updates cursor fields, then `notifyListeners()`. Resizing rebuilds
the line buffers. `codepointAt`/cursor getters unchanged for existing tests.

**`GlyphCache`.** `Map<int, ui.Paragraph>` keyed by `(codepoint << 24) ^ (fg & 0xFFFFFF)`
hash (with collision-safe storage), capped (LRU, e.g. 4096 entries). `get(codepoint, fg)`
builds a pre-laid-out single-glyph `ui.Paragraph` once and reuses it. `TerminalPainter.paint`
draws the cached paragraph at each non-blank cell offset; background via `drawRect`. No
per-frame text layout. Attributes/inverse remain unrendered in A (sub-project C).

**cols off-by-one.** First confirm with a full-width ruler
(`printf '%*s\n' "$(tput cols)" '' | tr ' ' '-'`). Likely fix: measure cell width sub-pixel
as `layout("W" * N).width / N` (N≈20) in `CellMetrics.measure` to remove integer rounding,
then `cols = (maxWidth / cw).floor()`. Engine, PTY, and painter already share `cols`; if the
ruler shows clean edge alignment, the right-edge bars are normal deferred-wrap and no change
is made.

## 6. Error handling

- **FFI panic isolation:** wrap the parser call in `engine_advance` / damage read in
  `std::panic::catch_unwind`; on panic, surface an error (logged + optional error
  `EngineEvent`) instead of aborting. The app survives a malformed-sequence panic.
- **Disposed engine:** calls after disposal are guarded/no-op (FRB opaque drop + a flag).
- **Backpressure:** per-frame coalescing + `_advancing` flag (already in §3) + a max
  bytes-per-advance cap; remainder drains next frame to bound per-frame latency.

## 7. Testing & acceptance

**Rust unit:**
- Damage: advance "hi"; `take_damage` returns line 0 only; a second `take_damage` returns
  empty `lines` (reset works). `full` set after resize/clear.
- DSR: advance `\x1b[6n`; assert a `PtyWrite` `EngineEvent` containing a cursor-position
  report `\x1b[1;3R` (row/col per current cursor).
- Title: advance `\x1b]0;hello\x07`; assert `Title("hello")`.
- (All use the `Mutex<Vec<EngineEvent>>` test collector via `EventProxy::new`.)

**Dart unit:**
- `MirrorGrid.applyLineUpdates`: partial update mutates only named lines; `full` replaces all.
- `GlyphCache`: same key returns the same cached `Paragraph`; eviction past the cap.
- `TerminalEngineClient` coalescing: with a fake engine binding + `FakePtyBackend`, bursts of
  N chunks within a frame produce exactly one `advance` call; leftover re-queues.

**Manual acceptance (Linux):**
- [ ] `cat` a large file / `yes | head -n 100000` / vim scrolling / htop — UI stays
      responsive (no frame freeze, input still reacts).
- [ ] A query-driven program works: `vim`/`less` (issue DA), or `printf '\e[6n'; read -r x; echo "$x" | cat -v` returns a cursor report.
- [ ] `printf '\e]0;hi\a'` changes the window title.
- [ ] `printf '\a'` flashes the screen.
- [ ] An OSC52 copy lands in the system clipboard.
- [ ] Full-width ruler aligns to the right edge (cols correct).

## 8. Components / files touched

```
rust/src/engine.rs        Term wrapper: add take_damage(); store palette + last size; keep snapshot
rust/src/event_proxy.rs   NEW — EventProxy + Event→EngineEvent mapping (testable)
rust/src/api/terminal.rs  async advance/take_damage; engine_new(sink); EngineEvent/RenderUpdate/LineUpdate
lib/engine/terminal_engine_client.dart  NEW — coalescing/backpressure, applies damage, routes events
lib/render/mirror_grid.dart   mutable per-line storage + applyLineUpdates
lib/render/glyph_cache.dart   NEW — cached ui.Paragraph per (codepoint,fg)
lib/render/terminal_painter.dart  draw from glyph cache
lib/render/cell_metrics.dart  sub-pixel width measurement (cols fix)
lib/ui/terminal_screen.dart   slimmed: hosts client, title notifier, bell flash
```

## 9. Risks & open questions

- **FRB async + `&mut` opaque under RwLock:** confirm `engine_advance`/`take_damage` don't
  deadlock if the events `StreamSink.add` is called while the write lock is held (it isn't —
  `send_event` only calls the sink closure, never re-enters the engine).
- **Glyph cache growth:** distinct `(char, color)` pairs are bounded in practice; the LRU cap
  guards pathological cases. Inverse/attributes (C) will expand the key later.
- **`take_damage` after `engine_advance` as two FFI hops:** acceptable; both async on the
  worker. Could be merged into one call returning `RenderUpdate` if profiling shows hop cost.
- **Open:** whether `TextAreaSizeRequest` needs real pixel dims (some apps care). A answers
  with cell-derived values; revisit if an app misbehaves.
