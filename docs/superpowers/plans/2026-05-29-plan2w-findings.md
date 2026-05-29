# Plan 2W — Library Widget Seam — Findings

**Date:** 2026-05-29
**Branch:** `worktree-W-library-seam` (was planned as `feature/W-library-seam`; worktree harness named it differently — same semantics)
**Base:** `main @ 25b0ebb`
**HEAD:** `57a811e`
**Spec:** [`docs/superpowers/specs/2026-05-29-plan2w-library-seam-design.md`](../specs/2026-05-29-plan2w-library-seam-design.md)
**Plan:** [`docs/superpowers/plans/2026-05-29-plan2w-library-seam.md`](2026-05-29-plan2w-library-seam.md)

## What shipped

| Task | Commit | Summary |
|---|---|---|
| 1 — TerminalEngine | `b7c506c` | `lib/engine/terminal_engine.dart` wraps client + grid + binding behind streams (`output`/`bell`/`clipboardStore`) + `ValueListenable` (`title`). FRB callbacks become internal. `_FakeBinding` lifted to shared `test/fake_binding.dart`. |
| 2 — TerminalController | `104f627` | Selection/search/scroll/primary state pulled out of `_TerminalScreenState` into `TerminalController extends ChangeNotifier`. Pure-Dart tests. |
| 3a — TerminalView extract | `9663825` | `lib/ui/terminal_view.dart` owns render/IME/pointer/bell/blink. `TerminalTheme` + `TerminalStyle` data classes in `lib/theme/terminal_theme.dart`. `TerminalScreen` wraps the view; hotkeys still inline pending 3b. |
| 3b — Shortcuts/Actions | `ce65869` | Inline hotkey switch replaced with `Shortcuts`+`Actions`. `lib/ui/terminal_shortcuts.dart` ships `defaultTerminalShortcuts` (top-level const) + Intent classes + `defaultTerminalActions` factory. Ad-hoc 3a callbacks (`onPaste`/`onCopy`/`onSearchToggle`/`onRestart`) gone. |
| 4 — Example app | `3110add` | `lib/ui/terminal_screen.dart` → `lib/example/example_app.dart` as `ExampleTerminalApp`. Library exports trimmed; `terminal_screen.dart` no longer public. |
| 5 — Docs | `57a811e` | `docs/library-api.md` (317 lines) + README "Use as a library" section. |

## Spec deviations

Each item below diverged from spec §2 / §4 in some way; none are blockers.

1. **`@internal` annotation on `TerminalEngine.gridForView`** — the spec recommended `@internal` from `package:meta`. The Dart analyzer rejects it on exported elements (`invalid_internal_annotation: only public elements in a package's private API can be annotated as being internal`). Downgraded to a doc comment marking the field as package-internal. If `TerminalEngine` ever moves to `lib/src/`, re-add `@internal`.
2. **`TerminalEngine.fromBinding` has an extra optional `schedule` parameter** — not in the spec API table, but legitimate test infrastructure that lets `terminal_engine_test.dart` drive the drain pipeline synchronously without `tester.pump()`. `@visibleForTesting`-bounded.
3. **`TerminalEngine` exposes `refreshView()` and `initializeEmpty(rows, cols)`** — pure pass-throughs needed during the `TerminalScreen` migration (the original code called the same methods on the underlying client/grid). Necessary for behavior preservation, not API expansion.
4. **`engine.repaint` getter is unused by the in-package painter** (`TerminalPainter` rebinds the grid via `Listenable.merge` each build). The getter exists for future external consumers wanting to drive a `CustomPaint(repaint:)` directly. Doc comment clarifies the asymmetry.
5. **`TerminalView` line count: 784** (target was 400–600). Inline pointer/IME handler bulk is intrinsic; further reduction would require extracting pointer dispatch into a helper (out of scope for 2W). Filed as a follow-up note.
6. **`TerminalView` exposes per-knob props beyond the spec list** (`cursorBlinkInterval`, `bellDuration`, `doubleClickThreshold`, `scrollMultiplier`, `preeditBg`/`preeditFg`/`preeditUnderline`). These were added during 3a to give the screen control without going back through config. Reasonable but not in the spec table — flagged for review when 2O re-shapes config.
7. **`onTapDown`/`onTapUp` callbacks** — declared in 3a but only wired in 3b (on primary-button selection-start / selection-end paths). Hosts that don't pass them see no behavior change.
8. **`MaterialApp` ownership** — plan Step 2 of Task 4 suggested `runApp(ExampleTerminalApp(config: ...))` with `ExampleTerminalApp` owning the `MaterialApp`. Kept the original `MyApp` + `MaterialApp(home: ExampleTerminalApp)` pattern instead because test sites already wrap targets in `MaterialApp`; nesting would have either caused churn (rewriting 16 test wrappers) or duplicate-Navigator warnings. `ExampleTerminalApp.title` is now optional so a future task can promote `MaterialApp` ownership into the example app with zero impact on the library surface.
9. **`_onTerminalInputStart` duplication** — exists on both `ExampleTerminalApp` (for drop/paste) and `TerminalView` (for keystrokes). Intentional and documented in code (one per driver). A future task could route the screen's paste through the controller to dedupe.
10. **Bell sound** — kept inside `TerminalView` (audible bell is render-time effect tied to the visual flash). `TerminalView.onBell` override exists for consumers wanting custom audio behavior.
11. **`Scrollable` integration** — explicitly deferred per spec §1; not addressed in 2W.

## Test counts

- **Baseline (`main @ 25b0ebb`):** 134 Flutter tests / 29 cargo tests / `flutter analyze` clean.
- **Plan 2W HEAD (`57a811e`):** **166 Flutter tests** / 29 cargo tests / `flutter analyze` clean.

Additions (+32 Flutter tests):
- `test/terminal_engine_test.dart` — 10 tests (write→output round-trip, title/bell/clipboardStore events, hyperlink lookup, dispose closes streams, search proxies, lazy ctor).
- `test/terminal_controller_test.dart` — 16 pure-Dart tests (selection/search/scroll/notify counts + gates).
- `test/terminal_view_shortcut_test.dart` — 3 tests (defaults / override / disabled).
- `test/terminal_view_callback_test.dart` — 3 tests (`onTapUp` / `onSecondaryTapUp` / `onLinkActivate`).

No cargo changes (Plan 2W is Dart-only).

## Manual smoke checklist

To be verified by running `flutter run -d linux` from the worktree (or from the merge target after merge). Each item is a check the consumer-side wiring is preserved through the refactor.

- [ ] Typing ASCII works; latency feels the same as pre-2W (Plan 2L perf fix preserved through controller's `_onTerminalInputStart`).
- [ ] Ctrl+Shift+F toggles the search bar.
- [ ] Ctrl+= / Ctrl+- / Ctrl+0 zoom works.
- [ ] Ctrl+Shift+C / V copies/pastes (default Actions hit clipboard).
- [ ] IME composition: pinyin → preedit overlay below cursor → commit reaches PTY.
- [ ] Right-click → context menu appears (`TerminalView.onSecondaryTapUp` wired to `ExampleTerminalApp._showContextMenu`).
- [ ] Drag a file → bracketed-paste appears (`DropTarget` → `engine.write(pasteBytes)`).
- [ ] Ctrl+click on a URL launches it (`TerminalView.onLinkActivate` wired to `url_launcher`).
- [ ] Process exit overlay appears when shell exits; click restarts.

(Smoke not run during plan implementation — run before merging to `main`.)

## Deferred / risks

- **`Scrollable` integration** — not in 2W. Engine handles scrollback internally; consumer can `controller.scrollLines(delta)` / `scrollToBottom()`. A future task can wrap the view in `Scrollable` for native scrollbar parity.
- **Per-platform PTY abstraction** — `PtyBackend` already exists; library doesn't pick one. Consumer chooses (`FlutterPtyBackend` desktop, future SSH/Mosh — Plan 2S).
- **Tabs / multi-engine** — Plan 2R. 2W enables it by giving each tab its own `TerminalEngine`, but the API and lifecycle aren't shaped here.
- **Config schema overhaul** — Plan 2O. `TerminalTheme` and `TerminalStyle` are data slices; the source of truth is still `TerminalConfig`.
- **Keybinding config from TOML** — Plan 2O-a. Shortcuts are programmatic for 2W.
- **OSC pump-through fixes** — Plan 2N.
- **Web / WASM** — Plan 2V.

## Public API surface (post-2W)

`lib/flutter_alacritty.dart` exports:

```dart
export 'config/config_loader.dart';
export 'config/terminal_config.dart';
export 'controller/terminal_controller.dart';
export 'engine/engine_binding.dart';
export 'engine/terminal_engine.dart';
export 'pty/pty_backend.dart';
export 'pty/flutter_pty_backend.dart';
export 'theme/terminal_theme.dart';
export 'ui/terminal_shortcuts.dart';
export 'ui/terminal_view.dart';
```

`lib/example/example_app.dart` (`ExampleTerminalApp`) is NOT exported — it's the reference consumer, not the API.

## Diff stats

```
24 files changed, 3289 insertions(+), 1089 deletions(-)
```

Largest moves:
- `lib/ui/terminal_screen.dart` (-894): removed (was the god widget).
- `lib/ui/terminal_view.dart` (+784): new view.
- `lib/example/example_app.dart` (+500): the reference consumer.
- `lib/engine/terminal_engine.dart` (+256): engine handle.
- `test/fake_binding.dart` (+175): lifted from lifecycle test.
- `test/terminal_view_callback_test.dart` (+141), `test/terminal_view_shortcut_test.dart` (+173), `test/terminal_engine_test.dart` (+208), `test/terminal_controller_test.dart` (+169): new.
- `test/terminal_lifecycle_test.dart` (-185): `_FakeBinding` lift + find-target adjustments.

## Follow-up notes

- **Trim `TerminalView`** below 600 lines by extracting pointer dispatch into a helper (intrinsic complexity is in IME + post-frame caret IPC; the rest is mechanical).
- **Dedupe `_onTerminalInputStart`** once paste routing converges.
- **Centralize the hardcoded default title** (`'flutter_alacritty'` appears in `TerminalEngine`, `FrbEngineBinding`'s ResetTitle handler, `FakeBinding`). A consumer who wants a different reset-title is stuck. Could expose via `TerminalConfig` or a `TerminalEngine` ctor param.
- **`gridForView` returns a mutable `MirrorGrid`**. Consider a read-only view type for the public seam.
- **Promote `MaterialApp` ownership** into `ExampleTerminalApp` after migrating test sites that wrap targets externally.
