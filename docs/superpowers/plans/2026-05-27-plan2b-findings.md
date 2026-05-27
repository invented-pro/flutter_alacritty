# Plan 2B acceptance findings (input completeness)

**Branch:** `feature/b-input-completeness`  
**Date:** 2026-05-27  
**Verifier:** Agent (automated build/test/analyze) + manual interactive gate pending

## Automated verification (agent environment)

| Check | Result |
|-------|--------|
| `cd rust && cargo build` | **PASS** — dev profile builds cleanly |
| `cd rust && cargo test` | **PASS** — 13 tests (includes `mode_flags_reflect_private_modes`) |
| `flutter test` | **PASS** — 54 tests |
| `flutter analyze lib test` | **PASS (info only)** — 2 info hints: unnecessary `dart:typed_data` imports in `lib/input/key_input.dart` and `test/key_input_test.dart` (elements re-exported via `package:flutter/services.dart`) |

Full-repo `flutter analyze` also reports errors in `rust_builder/cargokit/build_tool/` (missing dev-only packages); those are pre-existing and outside Plan 2B scope.

## Manual acceptance checklist (Plan FINAL §Step 2)

Run locally:

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter run -d linux
```

| Item | Status | Notes |
|------|--------|-------|
| **B1:** vim arrows / F-keys / PageUp | **AUTO (unit)** | `key_input_test.dart` — CSI arrows, SS3 app-cursor, F1/F5/Shift+F5, PageUp/Delete |
| **B1:** `Ctrl+→` word-jump in shell/tmux | **pending manual verification** | `Ctrl+arrow` CSI+mod encoding covered in unit tests; readline/tmux behavior needs live PTY |
| **B1:** `Alt+.` (last-argument recall) | **pending manual verification** | Alt+printable ESC-prefix covered generically; punctuation key needs live shell |
| **B1:** app-cursor app (vim) — arrows still move | **AUTO (unit)** | `kModeAppCursor` → SS3 `ESC O A` verified |
| **B2:** htop mouse + scroll | **pending manual verification** | SGR wheel (button 64/65) and click encoding unit-tested; htop UX needs live app |
| **B2:** vim `:set mouse=a` click / scroll / drag-select | **pending manual verification** | Drag gated on `kModeMouseDrag`; pointer wiring uses `Listener` + cell clamp |
| **B2:** no stray bytes when mouse mode off | **AUTO (unit)** | `encodeMouse` returns `null` when `anyMouse(modeFlags)` is false |
| **B3:** `Ctrl+Shift+V` multi-line paste into vim (verbatim, bracketed) | **pending manual verification** | `pasteBytes` wrap + end-marker strip unit-tested; clipboard → PTY path is UI-only |
| **B3:** focus-aware app reacts to focus | **pending manual verification** | `FocusNode` listener emits `ESC[I` / `ESC[O` when `focusReport(modeFlags)`; no widget test |

## Known limitations

| Limitation | Detail |
|------------|--------|
| **Mouse mode 1003 (any-event / hover)** | Deferred. `onPointerMove` only fires while a button is held, so drag mode (1002) works; bare-hover tracking needs `onPointerHover` plus button code 3 — not wired to avoid incorrect reports. |
| **`character` null under Ctrl** | Flutter often omits `KeyEvent.character` while Ctrl is held. `encodeKey` falls back to `key.keyLabel` for single-character control codes (`Ctrl+a`..`z`, `Ctrl+Space`, `Ctrl+[` etc.). |
| **Stale Linux bundle `.so`** | After Rust/FRB changes, an old `lib/librust_lib_flutter_alacritty.so` in the Linux bundle can cause FRB hash/symbol mismatch at runtime until `cargo build` + rebuild the Flutter app. |

## Flutter modifier quirks

| Quirk | Handling |
|-------|----------|
| **`event.character` null with Ctrl** | Use `key.keyLabel` fallback in `encodeKey` control-code path (see above). |
| **Modifiers from `HardwareKeyboard.instance`** | `_onKey` and `_reportMouse` read `isShiftPressed` / `isAltPressed` / `isControlPressed` / `isMetaPressed` at event time — not from `KeyEvent` fields alone. |
| **Meta vs Alt** | `isMetaPressed` treated like Alt (ESC prefix on printables). Super/Windows key is not mapped to terminal Meta. |
| **Enter = CR (`0x0d`)** | `\n` is never sent; PTY line discipline maps CR. |
| **Dead keys / IME composing** | Out of scope (Plan 2B non-goal); composing text may be dropped. |
| **Mouse cell rounding** | `(dx/cw).floor().clamp(0, cols-1)+1` — 1-based, clamped to grid; right/bottom edge uses last cell. |

## Carry-over for sub-project D (selection / copy / scrollback)

| Topic | Carry-over |
|-------|------------|
| **Text selection + copy** | No selection model; `Ctrl+Shift+C` not reserved (spec defers to D). |
| **Primary-selection paste** | Middle-click → primary selection paste not wired; B3 only claims `Ctrl+Shift+V` (clipboard). |
| **Scrollback on wheel** | When mouse reporting is off, wheel is a no-op (`onPointerSignal` ignored for scrollback); scrollback view belongs in D. |
| **OSC52 / clipboard integration** | Plan 2A wired OSC52 store → system clipboard; D may unify with selection copy. |

## Spec §3–§6 compliance (automated skim)

| Area | Status |
|------|--------|
| `RenderUpdate.mode_flags` → `MirrorGrid.modeFlags` | **Done** — Rust test + `mirror_grid_test` |
| `term_mode.dart` bit constants + helpers | **Done** — `term_mode_test` |
| Mode-aware `encodeKey` (all key classes) | **Done** — `key_input_test` |
| `encodeMouse` SGR/X10 + gating | **Done** — `mouse_input_test` |
| `pasteBytes` bracketed + sanitize | **Done** — `paste_test` |
| `TerminalScreen` wiring (keys, Listener, paste, focus) | **Done** — manual gate for end-to-end behavior |

## Integration notes

- **Mode-flag sync:** `term_mode.dart` mirrors `alacritty_terminal::term::TermMode` by comment; drift is a maintenance risk.
- **FRB regen:** Any Rust `RenderUpdate` field change requires `flutter_rust_bridge_codegen generate` and a fresh native build.
- **Next step:** Run manual checklist above, then merge `feature/b-input-completeness` → `main` (or open PR).
