# Plan 2G·2J·2H — Search, Box-Drawing, Touch Acceptance Findings

**Date:** 2026-05-28  
**Branch:** `feature/g-search-box-touch`  
**Worktree:** `.worktrees/feature-g-search-box-touch`  
**Spec:** `docs/superpowers/specs/2026-05-28-plan2gjh-search-box-touch-design.md`

## What shipped

| Phase | Deliverable |
|-------|-------------|
| **2G** | Rust `search_set` / `search_next` / `search_prev` / `search_clear` + `full_snapshot_searched`; FRB passthroughs; `kFlagMatch` / `kFlagMatchCurrent` (1<<9 / 1<<10); opaque search-match colors in painter; bottom search bar (`Ctrl+Shift+F`); additive `[colors.search.*]` config |
| **2J** | Mixed light/heavy and single/double junction table rows in `box_drawing.dart`; `DashOp` for U+2504–250B and U+254C–254F |
| **2H** | Touch-only `GestureDetector` (scroll + fling, long-press select, tap clear); mouse `Listener` handlers gated to `PointerDeviceKind.mouse`; touch tap restarts when session exited |

## Search protocol

**Rust flags:** `FLAG_MATCH = 1 << 9`, `FLAG_MATCH_CURRENT = 1 << 10` (Dart `kFlagMatch` / `kFlagMatchCurrent`).

**Snapshot:** While search is active, the client calls `full_snapshot_searched()` (FRB `engine_full_snapshot_searched`) so visible cells get match flags without requiring content damage. Invalid regex → `search_set` returns `false`, no flags set.

**Config (additive):**

```toml
[colors.search.matches]
background = "#ac4242"
foreground = "#181818"

[colors.search.focused_match]
background = "#f4bf75"
foreground = "#181818"
```

Defaults match alacritty; missing sections keep 2F per-field fallback.

## Automated verification

| Check | Result |
|-------|--------|
| `cargo test` (rust/) | **Pass** — 22 tests (4 search tests) |
| `flutter build linux --debug` | **Pass** |
| `flutter analyze lib/ test/ integration_test/` | **Pass** — no issues |
| `flutter test` | **Pass** — 92 tests |

## Manual smoke (Linux)

| Area | Result | Notes |
|------|--------|-------|
| Search UI | **Not run in this session** | Automated: `Ctrl+Shift+F` widget test; regex/highlight/jump need interactive verify |
| Box-drawing | **Not run** | Unit tests cover dash segments and arm weights |
| Touch device | **Not run** | Widget tests: `tester.drag` scroll, `longPressAt` selection; fling decay constants untuned on hardware |

## Post-review fixes

- `_refreshSelection()` routes through `refreshView()` so search highlights survive selection updates.
- Search bar shows invalid-regex indicator (`Icons.error_outline`, red hint) when `searchSet` returns false.
- `_onKey` ignores terminal encoding while search bar is open.
- Resize during active search uses `refreshView()` instead of plain `fullSnapshot()`.

## Deferred / risks

- **Live re-highlight:** Match flags refresh on the next `full_snapshot_searched` / view refresh, not on every PTY byte while search is open (acceptable per spec perf note).
- **Fling tuning:** Decay `0.92`, velocity thresholds `200` / `40` px/s — tune on a real touch panel if inertia feels off.
- **Gesture arena:** Long-press vs vertical drag split into separate widget tests; combined drag-then-long-press on one pointer is flaky in tests (production paths are separate gestures).

## Post-review user-testing fixes (2026-05-28)

Four user-reported regressions surfaced once real-machine testing began. All
were Dart-side: Rust + FFI both proven correct via a new real-native
integration test (`search next/prev across the FFI boundary actually moves
focus`) and a Rust unit test for the failing scenario (`foofoofoo` three
matches one line).

- **Code review:** `5b28f5d` removes a dead `flutter/scheduler.dart` import,
  unblocks Ctrl+Shift+F toggle-close (the previous `_searchOpen` early-return
  shadowed the toggle branch), and replaces a smoke painter test with 4
  behavioural cases on `applySearchOverride`.
- **Search prev/next origin:** `8c7dbea` — origin was sitting AT
  `m.start()` / `m.end()`, so `search_next` could re-find the current match
  ("感觉不到"). Mirror alacritty's `advance_search_origin`:
  `m.end().add(&term, Boundary::None, 1)` / `m.start().sub(...)`.
- **Trackpad two-finger pan:** `51941dd` — Flutter delivers precision-trackpad
  pan as `PointerPanZoom*` events (`PointerDeviceKind.trackpad`), missed by
  both `onPointerSignal` and the mouse `Listener` (kind-guarded). Added
  `Listener.onPointerPanZoomStart/Update`, routed through `_touchScrollBy` for
  alt-screen-arrows / app-mouse / scrollLines.
- **TextField was eating Shift+Enter; `_searchActive` flag desync:** `c543b95`
  — TextField consumed Shift+Enter at the text-input pipeline before
  `Focus(onKeyEvent:)` saw it; moved to `FocusNode(onKeyEvent: ...)` (set
  directly on the FocusNode, fires before TextField). Removed redundant
  `onSubmitted` to dedupe Enter. Removed the `_searchActive` boolean in
  `TerminalEngineClient` (the Rust `full_snapshot_searched` already short-
  circuits on `search.is_none()`); always use the searched snapshot to remove
  a class of flag-desync bugs.
- **First-open lag (~2 s) on Linux:** `6f0b9d5` — Material icon/font load +
  TextField/IconButton widget construction at first Ctrl+Shift+F was the
  dominant cost. Keep the bar mounted from app start under
  `Offstage(offstage: !_searchOpen)`; bar gains a `visible` prop;
  `didUpdateWidget` manages focus + clears the pattern on close (matches
  alacritty's close-clears-pattern). Test asserts via `bar().visible`
  (`find.byType` defaults to `skipOffstage: true`).
- **Build pitfall reminder:** `flutter test` does NOT rebuild the Rust dylib.
  After any Rust/FRB change rebuild with `flutter build linux --debug` before
  `flutter test`; in `flutter run`, fully restart (not hot-reload) for
  late/initState changes.

## Commits (feature branch)

| SHA | Message |
|-----|---------|
| `bd6d8e1` | feat(rust): regex search (search_set/next/prev/clear + searched snapshot) |
| `08c1893` | feat(config): match flags + alacritty search colors |
| `d7e278f` | feat(render): opaque search-match color override in painter |
| `bd32f3a` | feat(engine): search passthroughs + searched-snapshot refresh |
| `a286855` | feat(ui): search bar + Ctrl+Shift+F wiring |
| `2784bbc` | feat(render): box-drawing long-tail — mixed junctions + dashed lines |
| `6463cf4` | feat(ui): touch input — one-finger scroll + long-press select |
| `ef2aeb8` | docs: sample search colors + Plan 2G/2J/2H acceptance findings |
| `c53f4e8` | fix(search): preserve highlights on selection + invalid-regex UI |
| `5b28f5d` | fix(search): Ctrl+Shift+F can toggle close + tighten review nits |
| `8c7dbea` | fix(search): step origin past match boundary so prev/next actually move |
| `51941dd` | feat(input): precision trackpad two-finger pan = scroll |
| `c543b95` | fix(search): TextField was eating Shift+Enter; flag desync masked highlights |
| `6f0b9d5` | perf(search): keep bar mounted under Offstage to skip first-open lag |
