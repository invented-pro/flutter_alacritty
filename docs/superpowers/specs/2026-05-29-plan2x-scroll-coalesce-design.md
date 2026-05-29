# flutter_alacritty Plan 2X — Per-Frame Scroll Coalescing

**Date:** 2026-05-29
**Status:** Design pending review
**Branch:** `feature/X-scroll-coalesce` (off `main` @ `fc873cc`)

---

## 1. Goal & Non-Goals

**Goal.** Cut the per-event full-grid snapshot work that fires on every wheel notch / trackpad pan tick / fling timer beat. Today every `scrollLines(delta)` call hits the engine via FFI and then does a follow-up `fullSnapshotSearched` + `_grid.apply` (~12 000 cells repacked, ~288 KB across FFI on a 200×60 terminal). Coalesce all scroll deltas arriving within a single frame into ONE `binding.scrollLines(sum)` + ONE `refreshView()`. Result: the snapshot rate is capped at 60 Hz regardless of input device polling rate.

The bug class mirrors Plan 2L's "per-keystroke double snapshot" issue (fixed by `_onTerminalInputStart` gates). Plan 2X is the analogue for the scroll input path.

**Non-goals (explicitly deferred):**

- **Eliminating the snapshot entirely.** Alacritty's renderer reads the grid directly without a FFI hop, so `scroll_display` is one integer mutation + a render-frame redraw. We can't replicate that without abandoning the mirror grid model — `CustomPaint.paint` runs synchronously on the UI thread and cannot make FFI calls. So per-frame coalescing is the realistic ceiling.
- **Eliminating the FFI hop for `binding.scrollLines`** — keep the existing async call; we only batch the *outer* refresh.
- **Reworking `refreshView()` to fetch only changed rows.** Damage tracking on pure scroll would require engine-side bookkeeping. Out of scope.
- **Repaint-throttling.** The painter already short-circuits via `shouldRepaint` (generation check) — repaint cost is correct.
- **Touch fling timer rate.** The 16 ms cadence stays; the saving comes from coalescing within the frame, not from changing the input rate.
- **Programmatic scroll (PageUp/PageDown, ScrollToTop, ScrollToBottom).** Those stay on the awaited path (`controller.scrollLines` / `controller.scrollToBottom`) since callers may want to know when the operation completes. Plan 2X adds a *new* fire-and-forget path; the awaited one is unchanged.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Coalescing primitive | New `void scheduleScrollBy(int delta)` on `TerminalEngineClient`. Internal state: `int _pendingScrollDelta = 0; bool _scrollScheduled = false;`. Returns immediately; multiple calls within one tick aggregate into a single `_flushScroll()` invocation. |
| Scheduling mechanism | Reuse the existing `_schedule` field (parameterized for tests; defaults to `SchedulerBinding.instance.addPostFrameCallback`). Same hop pattern the `feed`-drain pipeline uses. |
| Flush semantics | `_flushScroll()` reads + zeros the accumulator, calls `_binding.scrollLines(delta)`, and on its `Future` completion calls `refreshView()`. The async chain (`.then((_) => refreshView())`) is intentional — `refreshView()` must run AFTER the engine has actually applied the new display offset, otherwise the snapshot would race ahead of the FFI commit. |
| Sum semantics | `alacritty_terminal::grid::scroll_display` applies `Delta(count)` as `display_offset += count` clamped to `[0, history_size]`. Sum is mathematically equivalent to a sequence of individual deltas. **Test case included** for the clamp at scrollback start / end. |
| Public engine API | Add `void TerminalEngine.scrollBy(int delta)` — fire-and-forget wrapper around `_client?.scheduleScrollBy(delta)`. Sits alongside the existing `Future<void> scrollLines(int)` (which stays awaited for programmatic callers and the controller). |
| Public controller API | No change to `controller.scrollLines` (stays awaited; used by PageUp/PageDown / programmatic paths). View bypasses the controller for the wheel/trackpad path and calls `_engine.scrollBy(...)` directly — we explicitly do NOT want the controller's `notifyListeners()` firing per input event during a high-rate scroll. |
| View wiring | Three call sites in `TerminalView` switch from `_controller.scrollLines(...)` or `_engine.scrollLines(...)` to `_engine.scrollBy(...)`: `_onPointerSignal` (mouse wheel), `_touchScrollBy` else-branch (touch + trackpad pan + drag), and the fling timer (which calls `_touchScrollBy` internally so it's covered transitively). |
| Backwards compat | None broken. The existing `Future<void> scrollLines(int)` API is preserved unchanged; new method is additive. |
| Test strategy | Pin coalescing in `terminal_engine_client_test.dart` (or a new `scroll_coalesce_test.dart`) by injecting a fake `_schedule` that captures the closure rather than running it. Verify: N `scheduleScrollBy(±delta)` calls within one tick = exactly 1 `binding.scrollLines(sum)` + 1 `binding.fullSnapshotSearched`. Add a complementary widget test in `terminal_view_callback_test.dart` (or similar) that drives multiple `PointerScrollEvent`s and asserts the underlying binding call count. |

## 3. Architecture & data flow

### Today (per-event FFI snapshot)

```
Mouse wheel notch (60-360 Hz on modern devices)
  → onPointerSignal
  → _controller.scrollLines(±3)
  → await engine.scrollLines(±3)
  → await client.scrollLines(±3)
      → await binding.scrollLines(±3)        [FFI hop #1]
      → refreshView()
          → binding.fullSnapshotSearched()    [FFI hop #2 — 288 KB / 200×60 terminal]
          → _grid.apply(snapshot)              [Dart side: 12 000 cell repack + 60 setRange]
          → _grid.notifyListeners()            [painter shouldRepaint → paint]
  → controller.notifyListeners()               [ListenableBuilder rebuild — search bar]
```

Cost per event: 2 FFI hops + 288 KB transfer + 12 000-cell Dart repack + paint. At 360 Hz polling = 360 of these per second.

### After 2X (per-frame coalescing)

```
N mouse wheel notches arrive within one frame interval
  → onPointerSignal (×N)
  → _engine.scrollBy(±3) (×N)
  → client.scheduleScrollBy(±3) (×N)
      → _pendingScrollDelta += ±3
      → _scrollScheduled = true (only the first call schedules)
  → frame boundary reached
  → _flushScroll() runs ONCE
      → binding.scrollLines(sum)                [FFI hop #1, scaled work — sum is bounded by visible range × N]
      → .then(_) → refreshView()
          → binding.fullSnapshotSearched()      [FFI hop #2, exactly one]
          → _grid.apply(snapshot)
          → _grid.notifyListeners()              [exactly one paint]
```

Cost per frame: 2 FFI hops + 1 snapshot + 1 paint, regardless of N. The painter's `shouldRepaint` (generation bump) means at most one paint per coalesced batch even if multiple `notifyListeners` were to fire.

The cost model now matches what alacritty achieves natively: the inner work is paid once per frame, the input rate above 60 Hz is excess that gets dropped.

## 4. Components

### 4.1 `lib/engine/terminal_engine_client.dart` (MOD, additive)

Add accumulator fields + the new methods:

```dart
int _pendingScrollDelta = 0;
bool _scrollScheduled = false;

/// Coalesced scroll. Multiple calls within one scheduling tick aggregate
/// into a single FFI scrollLines + refreshView. Use this for input-driven
/// scroll paths (wheel, trackpad pan, touch fling) where the per-event
/// snapshot rate would otherwise saturate the UI thread.
///
/// Programmatic callers that need the future (PageUp/PageDown, ScrollTo*)
/// should keep using [scrollLines] / [scrollToBottom] which await the
/// underlying FFI.
void scheduleScrollBy(int delta) {
  if (delta == 0) return;
  _pendingScrollDelta += delta;
  if (_scrollScheduled) return;
  _scrollScheduled = true;
  _schedule(_flushScroll);
}

void _flushScroll() {
  _scrollScheduled = false;
  final delta = _pendingScrollDelta;
  _pendingScrollDelta = 0;
  if (delta == 0) return;
  // refreshView must wait for the engine to actually advance display_offset.
  // The async chain is the price of mirror semantics — alacritty avoids it
  // by reading the grid directly inside the render thread (impossible here
  // because CustomPaint cannot make FFI calls synchronously).
  _binding.scrollLines(delta).then((_) => refreshView());
}
```

No change to the existing `scrollLines(int delta)` / `scrollToBottom()` methods; they continue to await + refresh as today.

### 4.2 `lib/engine/terminal_engine.dart` (MOD, additive)

```dart
/// Fire-and-forget scroll for input-driven paths (mouse wheel, trackpad
/// pan, touch fling). Multiple calls within one frame coalesce into one
/// engine call + one snapshot.
///
/// For deterministic / awaited scroll (PageUp/Down, programmatic ScrollTo*),
/// use [scrollLines] / [scrollToBottom].
void scrollBy(int delta) => _client?.scheduleScrollBy(delta);
```

### 4.3 `lib/ui/terminal_view.dart` (MOD, three sites)

Three input-driven scroll sites switch from `_controller.scrollLines` / `_engine.scrollLines` to `_engine.scrollBy`:

1. `_onPointerSignal` mouse-wheel else-branch (currently `_controller.scrollLines(±scrollMultiplier)`).
2. `_touchScrollBy` non-mouse-non-alt else-branch (currently `_engine.scrollLines(±n)`).
3. The fling timer's callback path goes through `_touchScrollBy` so it's covered transitively.

No new fields, no new state on the View — just method-name swaps at the three call sites.

### 4.4 Tests

**New: `test/scroll_coalesce_test.dart`** (pure Dart with a fake binding):

```dart
test('multiple scheduleScrollBy in one tick → 1 FFI scrollLines + 1 snapshot', () async {
  final binding = _CountingFakeBinding();
  final grid = MirrorGrid();
  late void Function() pending;
  final client = TerminalEngineClient(
    binding: binding,
    grid: grid,
    schedule: (cb) { pending = cb; },  // capture, don't run
  );
  client.scheduleScrollBy(3);
  client.scheduleScrollBy(3);
  client.scheduleScrollBy(-1);
  // Nothing fired yet.
  expect(binding.scrollLinesCalls, 0);
  expect(binding.snapshotCalls, 0);
  pending();
  // Allow the .then(refreshView) microtask to drain.
  await Future<void>.value();
  expect(binding.scrollLinesCalls, 1);
  expect(binding.scrollLinesArgs.single, 5);
  expect(binding.snapshotCalls, 1);
});

test('coalesced delta clamps at scrollback start (engine semantics, sum is linear)', () async {
  // verifies that scheduleScrollBy(+10) + scheduleScrollBy(-3) → binding.scrollLines(+7)
  // — the clamping is the engine's responsibility, not ours.
});

test('a new scheduleScrollBy after flush starts a fresh batch', () async {
  // schedule, flush, schedule again, flush again → two distinct FFI calls.
});
```

**New / extended: a widget test** that drives multiple `PointerScrollEvent`s within a single `tester.pump()` and asserts the resulting `_FakeBinding.scrollLinesCalls` is 1 (not N).

`_FakeBinding` already counts `selClearCalls` and `scrollToBottomCalls` from Plan 2L. Add `scrollLinesCalls` + `scrollLinesArgs` + `snapshotCalls` (the last extracted from `fullSnapshotSearched()`).

## 5. Migration plan

Two small commits. Suite stays green after each:

| # | Commit | Files | Coverage |
|---|---|---|---|
| 1 | `perf(engine): coalesce input-driven scrollBy per frame` | `terminal_engine_client.dart`, `terminal_engine.dart`, new `test/scroll_coalesce_test.dart`, extended `test/fake_binding.dart` | pure-Dart pins coalescing semantics |
| 2 | `perf(ui): route wheel + trackpad + touch fling through engine.scrollBy` | `terminal_view.dart`, widget test in `terminal_view_callback_test.dart` (or new `terminal_view_scroll_test.dart`) | end-to-end pin |

## 6. Risks & known unknowns

| Risk | Mitigation |
|---|---|
| **Async race**: a flush in flight, new scrollBy arrives before the flush's `.then(refreshView)` returns. | The `_scrollScheduled` flag is reset at the START of `_flushScroll` (before the FFI call). A new `scheduleScrollBy` during the in-flight async call re-schedules cleanly. The two scroll calls hit the engine sequentially (FFI calls are serialized on the proxy side) and the second `refreshView` shows the latest engine state — correct behavior. Pinned by a test. |
| **Lost scroll on dispose**: client disposed between schedule and flush. | The `_schedule` callback closure captures `this` (`client._flushScroll`). After `dispose`, `_binding` is gone; `binding.scrollLines(delta)` would throw. Guard `_flushScroll` with an early return if `_disposed` (need to add the flag — `TerminalEngineClient` doesn't have one today, but it's a one-liner). |
| **Initial scroll is delayed by one frame**: today `controller.scrollLines(3)` updates the screen as soon as the FFI returns. With coalescing, the first scroll waits until the next post-frame callback. | Realistically imperceptible: post-frame fires on every vsync, and the input event itself was already post-vsync. One additional 16 ms wait at worst. Document; do not optimize. |
| **Controller `notifyListeners` no longer fires per scroll event.** | Intentional. The controller's `scrollLines` is the awaited / programmatic path; the input-driven path goes through `engine.scrollBy` directly. Side effect: any consumer wiring a `ListenableBuilder(listenable: controller)` for scroll-aware UI must check that they don't need the per-scroll notify (the search bar wraps for `searchValid` — not affected). Note in 2X findings. |
| **Test: `controller.scrollLines notifies after the engine await`** still passes because the awaited path is unchanged. Verify in Task 0. | — |
| **Submodule fetch errors on worktree create.** Known issue (in roadmap memory): the parent repo's submodule pointer (`packages/rust_lib_flutter_alacritty`) is at a commit only present in the main worktree's submodule, not on the remote. `git submodule update --init --recursive` in a fresh worktree fails to fetch. | Task 0 documents the local-reference fix: `cd packages/rust_lib_flutter_alacritty && git fetch ../../../packages/rust_lib_flutter_alacritty <SHA>`. Or, since Plan 2X is **Dart-only** (no Rust changes), the implementing agent can run `flutter test` against the already-built dylib in `build/linux/x64/debug/` without re-initializing the submodule. Documented in Task 0. |

## 7. Expected impact

Conservatively, on a 200×60 terminal under sustained scroll input:

| Scenario | Before 2X (snapshots/sec) | After 2X | Reduction |
|---|---|---|---|
| Standard mouse wheel (30 Hz) | 30 | ≤ 30 (already ≤ frame rate) | 0 % |
| High-poll-rate mouse / smooth-scroll (120 Hz) | 120 | 60 | 2× |
| High-end gaming mouse (360 Hz) | 360 | 60 | 6× |
| Trackpad two-finger pan (120 Hz events × cell-height threshold) | up to 120 | 60 | up to 2× |
| Touch fling at 16 ms cadence | 60 | 60 | (already aligned) |

So the worst-case input (high-poll-rate mouse on a coloured large terminal) drops from saturating one CPU core to using ~17 % of one core. Mid-range devices see 2× improvements. Touch fling and slow mice see no change because they were already within the frame budget — and that's correct, the fix is targeted at the over-firing class.

## 8. Resolved open questions

1. **Should `scrollBy` be async (`Future<void>`) so callers can await flush completion?** No — fire-and-forget is the contract that matches what the View needs. Programmatic callers use `scrollLines` (awaited).
2. **Should the controller proxy `scrollBy` too?** No — the View calls the engine directly. The controller's `scrollLines` is for programmatic / consumer code that wants the notify + await chain. Two distinct surfaces serving distinct callers.
3. **Should we coalesce `scrollToBottom` similarly?** No — `scrollToBottom` is one-shot (called after keystroke / paste, never in a tight loop). Coalescing wouldn't change anything.
4. **Should `_writeToEngine` arrow-key fallback (alt-screen scroll) also coalesce?** No — that path writes PTY bytes, not a scroll instruction. Each keystroke is independent.

Plan doc: `docs/superpowers/plans/2026-05-29-plan2x-scroll-coalesce.md`.
