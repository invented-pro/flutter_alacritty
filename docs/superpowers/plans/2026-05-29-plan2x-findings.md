# flutter_alacritty Plan 2X — Findings (Per-Frame Scroll Coalescing)

**Date:** 2026-05-29
**Status:** DONE — merged to `main`
**Commits:** `97d305b` (engine), `068db4d` (UI + zoom resize)
**Spec:** `docs/superpowers/specs/2026-05-29-plan2x-scroll-coalesce-design.md`

---

## What shipped

Input-driven scroll (mouse wheel, trackpad pan, touch drag/fling) no longer
fires one full-grid FFI snapshot per event. Deltas arriving within a single
scheduling tick coalesce into ONE `binding.scrollLines(sum)` + ONE
`refreshView()`, capping the snapshot rate at the frame rate regardless of
input device polling rate.

### Commit 1 — `perf(engine): coalesce input-driven scroll per frame`

- **`TerminalEngineClient.scheduleScrollBy(int delta)`** — fire-and-forget,
  accumulates into `_pendingScrollDelta` and arms a single post-frame flush via
  `_ensureScrollScheduled()`. Early-returns on `delta == 0` or `_disposed`.
- **`TerminalEngine.scrollBy(int delta)`** — thin wrapper over
  `_client?.scheduleScrollBy(delta)`. Additive; the awaited
  `Future<void> scrollLines(int)` is unchanged for programmatic callers.
- Tests: `test/scroll_coalesce_test.dart` (304 lines) — pins coalescing,
  linear-sum semantics, fresh-batch-after-flush, dispose safety, re-arm.

### Commit 2 — `perf(ui): route wheel/trackpad/fling through engine.scrollBy; resize engine on font zoom`

- Three `TerminalView` sites switched from awaited `scrollLines` to
  fire-and-forget `scrollBy`: `_onPointerSignal` (wheel), `_touchScrollBy`
  (pan/drag), and the fling timer (transitively via `_touchScrollBy`).
- Tests: `test/terminal_view_scroll_test.dart` (end-to-end pin), extended
  `test/fake_binding.dart` with scroll/snapshot counters.

## Deviations from spec (intentional, found during implementation)

1. **Flush is integrated into `_drain`, not a standalone `_flushScroll`.** The
   spec proposed a self-contained `_flushScroll()` that runs only on the
   post-frame callback. The implementation applies the coalesced scroll at the
   **start of `_drain`** (`await _applyPendingScroll()` before ingesting PTY
   bytes) so that user scroll wins over PTY output landing in the same frame —
   without this, fast output can outrun a wheel-down and the viewport can never
   reach the live end. `_applyPendingScroll()` is *also* armed independently
   via `_ensureScrollScheduled()` for the no-output case.

2. **Re-entrancy guard is `_scrollApplying` re-armed from `finally`, not a
   start-of-flush flag reset.** The spec's risk table proposed resetting
   `_scrollScheduled` at the start of the flush. The shipped design instead:
   `_scrollScheduled` is cleared when the callback fires; `_applyPendingScroll`
   no-ops if `_scrollApplying` is already true; and the in-flight flush's
   `finally` calls `_ensureScrollScheduled()` to pick up any delta that
   accumulated mid-await. This closes the strand-the-accumulator hole (callback
   fires mid-flush → `_scrollScheduled` stuck true with no queued callback).

3. **`_advancing` is held across the whole `_drain`, including the scroll
   apply.** Otherwise a `feed()` arriving during the awaited scroll/advance
   slips past `_scheduleDrain`'s `(_drainScheduled || _advancing)` gate and
   starts a second overlapping `advanceAndTakeDamage` on the same engine.

4. **Added: engine resize on font zoom (`onViewportResize` callback).** Not in
   the 2X spec — folded into commit 2 because it shares the scroll-offset
   correctness concern. `TerminalView._ensureSizing` now posts
   `engine.resize(cols, rows)` + a new `onViewportResize(columns, rows)`
   callback when the cell grid changes (font zoom / layout). Mirrors alacritty
   `display/mod.rs`: a font-zoom changes cell size → new `screen_lines/columns`
   → `term.resize()`; without it the scrollback offset is wrong relative to the
   painted grid. `example_app` moved its PTY resize out of `_ensureStarted` into
   `_onViewportResize`. Tests: `test/terminal_lifecycle_test.dart` (zoom resize).

## Verification

`flutter test test/scroll_coalesce_test.dart test/terminal_view_scroll_test.dart
test/terminal_lifecycle_test.dart` → **All tests passed** (28 tests, 2026-05-29).
Plan 2X is Dart-only (no Rust changes), so tests run against the already-built
debug dylib without re-initializing the submodule.

## Expected impact (from spec §7, unchanged)

High-poll-rate / gaming mouse (120–360 Hz) on a large coloured terminal drops
from saturating a CPU core to ~17% of one core (6× fewer snapshots at 360 Hz,
2× at 120 Hz). Standard 30 Hz wheel and 60 Hz touch fling are unchanged — they
were already within the frame budget; the fix targets the over-firing class.

## Deferred / risks (carried forward)

- **Controller `notifyListeners` no longer fires per input scroll event** (the
  input path bypasses the controller, calling `engine.scrollBy` directly). A
  consumer wiring a `ListenableBuilder(listenable: controller)` for scroll-aware
  UI must not depend on the per-scroll notify. The bundled search bar wraps for
  `searchValid` only — not affected.
- **First scroll is delayed by one post-frame callback** (≤16 ms). Imperceptible
  in practice; not optimized.
- Non-goals from the spec stand: no damage-based partial-row refresh on scroll,
  no elimination of the FFI hop or the mirror snapshot.
