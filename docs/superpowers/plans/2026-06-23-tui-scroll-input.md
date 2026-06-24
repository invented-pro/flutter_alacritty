# TUI Scroll Input Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify wheel / trackpad / touch scroll in `TerminalView` with Alacritty-parity routing and batched PTY writes for TUI, while keeping scrollback on local sub-cell `scroll_pixels`.

**Status (2026-06-23):** Implemented. History **wheel** uses discrete `scrollLines` + pixel remainder (Alacritty parity); **pan/fling** uses awaited `scrollPixels` on a single serialized queue. Absolute scroll (`scrollTo*`) cancels pending gesture scroll and awaits `drainHistoryScroll` before applying. Edge snaps during gesture flush use `scrollToBottomSnap` / `scrollToTopSnap` (no cancel/drain re-entry). Legacy `scrollBy` / `scheduleScrollBy` coalescing removed.

**Architecture (as built):** `TerminalScrollController` routes via `scroll_destination`. History wheel → `_pendingHistoryLines`; pan/fling → `_pendingHistoryPx`; both drain through one `_flushHistoryScroll` queue. TUI program scroll → `engine.scheduleWrite`. **No** alt-screen `scrollFraction` preview.

---

## Problem statement

### Symptoms (before)

| Mode | Issue |
|------|-------|
| Scrollback | Generally acceptable (local `scrollByPixels` + `scrollFraction`) |
| TUI (vim/htop) | Discrete `3×` SS3 arrows per wheel tick, one `engine.write` per arrow, no pixel accumulation, fling disabled in alt-screen |

### Root cause

TUI scrolling is **not** local viewport panning — it is **remote semantics** (arrow keys / SGR wheel → app redraw → PTY round-trip). The old `terminal_view_pointer.dart` inlined scroll logic with fixed `3×` arrows and no batching.

Scrollback feels smoother because `engine.scroll_pixels` updates `display_offset` + `scroll_fraction` locally with zero PTY latency.

### Reference implementations

**gnome-terminal (VTE + GtkScrolledWindow)**

- `vte_terminal_set_scroll_unit_is_pixels(TRUE)` — input accumulation in pixel/scroll units
- `vte_terminal_set_enable_fallback_scrolling(FALSE)` — no GTK fallback in alt-screen
- Alt-screen + DEC 1007: accumulate wheel delta, emit cursor up/down keys (line-discrete)
- Scrollback: fractional `scroll_delta` on the normal buffer (true sub-cell **rendering**)
- Alt-screen comment in VTE: *"The alternate scrn isn't allowed to scroll at all"* — no fractional viewport pan in TUI

**Alacritty (`alacritty/src/input/mod.rs::scroll_terminal`)**

- `AccumulatedScroll` pixel remainder, `% cell_height` retention
- Route: mouse bindings → mouse mode SGR wheel → `ALT_SCREEN | ALTERNATE_SCROLL` SS3 batch → else `Scroll::Delta(lines)` for history
- `write_to_pty` synchronously in the event handler (no post-frame delay)

**flutter_alacritty target**

| Path | Behavior |
|------|----------|
| History wheel | `scrollLines` — discrete lines + sub-line remainder |
| History pan/fling | `scrollPixels` — sub-cell, serialized queue, **wheel sign ≠ pan sign** |
| Alt + DEC 1007 | `encodeAlternateScrollLines` batched via `scheduleWrite` |
| Mouse report | `encodeMouseWheelLines` batched via `scheduleWrite` |
| Shift + wheel | History (even in alt-screen) |
| TUI fling | Same line accumulator as wheel/pan — **not** disabled |

---

## Out of scope (explicit decisions)

1. **TUI visual smooth scroll** — no local `scrollFraction` / scroll-preview on alt-screen. Empirical check: gnome-terminal also has no true TUI sub-line rendering; perceived smoothness in scrollback comes from `scroll_delta`, not alt-screen.
2. **Row-level `Picture` cache** (optional perf task) — deferred; partial TUI damage still repaints via existing grid `generation` + atlas path.
3. **Backward compatibility** — replace inline `terminal_view_pointer` scroll paths entirely.

---

## File map

| File | Responsibility |
|------|----------------|
| `lib/input/term_mode.dart` | `kModeAlternateScroll` (bit 15), `alternateScroll()` |
| `lib/input/scroll_destination.dart` | `scrollDestination()` routing |
| `lib/input/scroll_accumulator.dart` | Pixel → signed whole lines + remainder |
| `lib/input/program_scroll_encoder.dart` | Batch SS3 arrows / SGR wheel bytes |
| `lib/engine/terminal_engine.dart` | `scheduleWrite`, `scheduleTask` (microtask batch) |
| `lib/ui/terminal_scroll_controller.dart` | Gesture state, routing, fling |
| `lib/ui/terminal_view.dart` | Own `TerminalScrollController` |
| `lib/ui/terminal_view_pointer.dart` | Forward wheel/pan/fling to controller |
| `docs/library-api.md` | Scroll input architecture section |
| `test/scroll_destination_test.dart` | Routing unit tests |
| `test/scroll_accumulator_test.dart` | Remainder unit tests |
| `test/program_scroll_encoder_test.dart` | Encoder unit tests |
| `test/terminal_engine_write_coalesce_test.dart` | `scheduleWrite` coalesce |
| `test/terminal_scroll_controller_test.dart` | Controller integration + sign tests |
| `test/terminal_view_tui_scroll_test.dart` | Widget: multi-wheel → one PTY write |

---

### Task 1: `kModeAlternateScroll` term bit

**Files:**
- Modify: `lib/input/term_mode.dart`
- Test: `test/term_mode_test.dart`

- [x] **Step 1:** Add `kModeAlternateScroll = 1 << 15` and `alternateScroll(int f)`.
- [x] **Step 2:** Test bit helper.
- [x] **Step 3:** `flutter test test/term_mode_test.dart`

---

### Task 2: Scroll routing (`scroll_destination`)

**Files:**
- Create: `lib/input/scroll_destination.dart`
- Create: `test/scroll_destination_test.dart`

- [x] **Step 1:** Implement routing table:

```dart
enum ScrollDestination { history, program }

ScrollDestination scrollDestination({required int modeFlags, required bool shiftHeld}) {
  if (anyMouse(modeFlags)) return ScrollDestination.program;
  if (shiftHeld) return ScrollDestination.history;
  if (alternateScroll(modeFlags) && (modeFlags & kModeAltScreen) != 0) {
    return ScrollDestination.program;
  }
  return ScrollDestination.history;
}
```

- [x] **Step 2:** Tests for mouse, Shift, alt+1007, alt without 1007.
- [x] **Step 3:** `flutter test test/scroll_destination_test.dart`

**Note:** Do **not** route all `kModeAltScreen` to program — only when DEC 1007 is set (matches Alacritty `TermMode::ALTERNATE_SCROLL` gating).

---

### Task 3: Pixel accumulator

**Files:**
- Create: `lib/input/scroll_accumulator.dart`
- Create: `test/scroll_accumulator_test.dart`

- [x] **Step 1:** `ingest(dyPx, multiplier)` → signed whole lines; retain `remainderPx % cellHeight`.
- [x] **Step 2:** Tests for sub-line remainder and negative scroll.
- [x] **Step 3:** `flutter test test/scroll_accumulator_test.dart`

Used for **program/TUI path only**. History uses raw scaled pixels (Task 6).

---

### Task 4: Program scroll encoder

**Files:**
- Create: `lib/input/program_scroll_encoder.dart`
- Create: `test/program_scroll_encoder_test.dart`

- [x] **Step 1:** `encodeAlternateScrollLines` — `lines × ESC O A/B` (SS3, Alacritty parity).
- [x] **Step 2:** `encodeMouseWheelLines` — `lines × encodeMouse(scrollUp/Down)`.
- [x] **Step 3:** `flutter test test/program_scroll_encoder_test.dart`

---

### Task 5: `engine.scheduleWrite` + `scheduleTask`

**Files:**
- Modify: `lib/engine/terminal_engine.dart`
- Create: `test/terminal_engine_write_coalesce_test.dart`

- [x] **Step 1:** `scheduleWrite(Uint8List)` — `BytesBuilder` + single flush per scheduling tick.
- [x] **Step 2:** `scheduleTask(void Function())` — batch multiple tasks in one tick.
- [x] **Step 3:** Default scheduler = **microtask** batch (lower latency than post-frame for input).
- [x] **Step 4:** Inject same `schedule` callback as `TerminalEngineClient` via `_bindEager`.
- [x] **Step 5:** Coalesce test with `TestWidgetsFlutterBinding.ensureInitialized()` + `await Future<void>.value()`.

```dart
void scheduleWrite(Uint8List bytes) {
  _pendingWrite.add(bytes);
  if (_writeFlushScheduled) return;
  _writeFlushScheduled = true;
  _schedule(_flushPendingWrite);
}
```

---

### Task 6: `TerminalScrollController`

**Files:**
- Create: `lib/ui/terminal_scroll_controller.dart`
- Create: `test/terminal_scroll_controller_test.dart`

- [x] **Step 1:** Constructor takes `engine`, `cellHeight`, `scrollMultiplier` (`multiplier = scrollMultiplier / 3`, neutral at default `3`).
- [x] **Step 2:** History path — **split sign by input type:**

| API | Engine delta | Rationale |
|-----|--------------|-----------|
| `onWheelSignal(dy)` | `-dy × multiplier` | Matches legacy `PointerScrollEvent` |
| `onPanDelta(dy)` / fling | `+dy × multiplier` | Matches legacy touch drag / `scrollByPixels(dy)` |

```dart
if (dest == ScrollDestination.history) {
  final scaled = dyPx * _multiplier;
  _scheduleHistoryPixels(wheelStyle ? -scaled : scaled);
  return;
}
```

- [x] **Step 3:** Program path — `ScrollAccumulator.ingest` → `encode*` → `_scheduleProgramWrite` → `scheduleTask` → `scheduleWrite`.
- [x] **Step 4:** `startFling` / `stopFling` — TUI fling enabled (routes through `onPanDelta`).
- [x] **Step 5:** Tests: alt-screen batched write; history pan sign; history wheel sign.

**Regression:** Unifying wheel and pan with a single `-dy` breaks scrollback on Linux trackpad pan gestures.

---

### Task 7: Wire `TerminalView`

**Files:**
- Modify: `lib/ui/terminal_view.dart`
- Modify: `lib/ui/terminal_view_pointer.dart`
- Create: `test/terminal_view_tui_scroll_test.dart`

- [x] **Step 1:** `TerminalViewState` owns `TerminalScrollController`; dispose on `dispose()` and engine swap (`stopFling`).
- [x] **Step 2:** Remove `_touchScrollAccum`, inline `_startFling` / `_onFlingTick` (moved to controller).
- [x] **Step 3:** `terminal_view_pointer.dart` — delete fixed `3×` arrow loop and inline history/program branches.
- [x] **Step 4:** Wheel: `setWheelCell` from hit-test + `onWheelSignal(scrollDelta.dy, shiftHeld)`.
- [x] **Step 5:** Pan/touch: `onPanDelta` / `onGestureStart` / `startFling` on controller.
- [x] **Step 6:** Widget test — multiple wheel events in alt-screen → single `output` event.

---

### Task 8: Row-damage compositor painting (deferred)

**Files (not implemented):**
- Modify: `lib/render/mirror_grid.dart` — per-row `rowGeneration`
- Modify: `lib/render/terminal_painter.dart` — row `Picture` cache
- Create: `test/terminal_painter_row_cache_test.dart`

- [ ] **Deferred** — rendering perf optimization only; does not affect scroll input semantics. Revisit if TUI redraw CPU is profiled as a bottleneck.

---

### Task 9: Docs + full suite

**Files:**
- Modify: `docs/library-api.md`

- [x] **Step 1:** Add **Scroll input architecture** table (history / DEC 1007 / mouse / Shift).
- [x] **Step 2:** Document line-discrete TUI model and explicit non-goal of alt-screen smooth scroll.
- [x] **Step 3:** `flutter test` — all pass.

---

## Manual smoke checklist

| Check | App | Expected |
|-------|-----|----------|
| Trackpad fling in scrollback | `less` output before `less` | smooth sub-cell; direction matches finger |
| Mouse wheel in scrollback | shell with long history | smooth; **opposite** sign convention vs two-finger pan is OK |
| Trackpad in vim (no mouse) | large file | line-discrete scroll, batched arrows, not 3× jumps per tick |
| htop wheel | `htop` | column scroll follows keys |
| Shift+wheel in vim | alt-screen | scrolls terminal history overlay |
| `\e[?1007l` in vim | wheel | mouse/report or history path per mode — not blind arrows |

---

## Self-review

| Requirement | Task |
|-------------|------|
| Alacritty-parity pixel accumulation (TUI) | 3, 6 |
| Batch PTY writes | 4, 5, 6 |
| Alt-screen / mouse routing | 2, 6, 7 |
| DEC 1007 gating (not bare alt-screen) | 1, 2 |
| Shift → history in alt-screen | 2, 6 |
| TUI fling | 6, 7 |
| History sub-cell + correct wheel/pan signs | 6 |
| No TUI visual smooth scroll | Out of scope |
| Row-damage render perf | 8 deferred |
| Tests | 1–7, 9 |
| Docs | 9 |

---

## Execution handoff

Plan complete. For a fresh implementation session:

**1. Subagent-Driven (recommended)** — one task per subagent, review between tasks.

**2. Inline Execution** — `superpowers:executing-plans` with checkpoints after Tasks 5 and 7.

When resuming from this doc on an already-implemented tree, run `flutter test` first, then verify Task 6 wheel/pan sign split if scrollback direction is reported wrong.
