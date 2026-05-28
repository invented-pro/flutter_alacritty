# Plan 2L — IME Preedit Overlay Acceptance Findings

**Date:** 2026-05-28
**Branch:** `feature/L-ime-preedit`
**Status:** code-complete; manual smoke pending (see checklist below).

## What shipped

| Phase | Commit | Deliverable |
|-------|--------|-------------|
| **ImeSession** | `92599d6` | `lib/input/ime_session.dart` — `TextInputClient` implementation; `attach`/`detach` lifecycle; `updateEditingValue` → `onPreeditChanged` / `onCommit`; `setCaretRect` passthrough |
| **PreeditOverlay** | `118700e` | `lib/ui/preedit_overlay.dart` — `StatelessWidget` floating below cursor with config-driven bg/fg + optional underline |
| **`[ime]` config** | `41e4288` | Additive `ImeConfig { preeditBg, preeditFg, underline }`; defaults `0x282828 / 0xD8D8D8 / true`; `fromTomlString` per-field fallback |
| **TerminalScreen wiring** | `f469922` | Focus → `attach/detach`; `_onKey` gate for printable + no-modifier; per-frame `_reportCaretRectToIme`; committed text → `_pty.write(utf8.encode(text))` raw; `PreeditOverlay` placed in `Stack` above bell |
| **Docs + sample** | *(this commit)* | `flutter_alacritty.toml.example` + this findings doc |
| **Review fixes** | *(this commit)* | Focus listeners moved to `initState` (fix race vs. autofocus & spawn-failure paths); `PreeditOverlay` mounted conditionally (`text` is non-nullable); `preeditFg` packed-RGB contract documented; `connectionClosed` mid-composition test |

## Spec deviations (intentional)

- **`_onKey` gate uses `_ime.isAttached && _ime.isComposing`** (terminal_screen.dart), tighter than the spec's "ignore when attached + printable + no-modifier". Reason: when `fcitx` is in 英 (English) mode the connection stays attached but GTK does NOT deliver ASCII via `updateEditingValue` — without the `isComposing` clause those characters would be silently swallowed. Pinned by the regression test `'ASCII with IME attached but not composing reaches the PTY via encodeKey'` in `test/terminal_lifecycle_test.dart`. The spec should be amended to match.

## Automated verification

| Check | Result |
|-------|--------|
| `cargo test` | **Pass** — no Rust changes; 29/29 |
| `flutter analyze lib/ test/ integration_test/` | **Pass** — zero issues |
| `flutter test` | **Pass** — 130 tests (113 baseline + new IME unit/widget tests, incl. platform-side connectionClosed) |
| `flutter build linux --debug` | **Not run** in this session (Dart-only change; prior debug bundle used for FFI tests) |

## Manual smoke checklist (Linux + fcitx5 / IBus) — REQUIRED before merge

- [ ] `vim` insert-mode pinyin → preedit below cursor → candidate window from OS IM → commit arrives in vim
- [ ] Bare shell + `git commit -m "<中文>"` → IME usable for the argument
- [ ] Esc during composition cancels; Esc out of composition reaches PTY
- [ ] Ctrl+Shift+C / V / F still trigger their hotkeys during composition
- [ ] Focus loss clears preedit; refocus starts fresh composition
- [ ] ASCII typing (`ls`, `cd`) still works (with IME attached but not composing — covered by widget test, but verify the live path too)
- [ ] First-focus IME attach: launching the app and immediately starting to compose works without an intermediate click (regression for the listener-moved-to-initState fix)

## Deferred / risks

- **Non-Linux**: macOS/Windows paths through the same `TextInputClient` API; expected to work but not gated here.
- **Bottom-row preedit clipping**: when the cursor is in the last row, the overlay extends below the window. Acceptable for v1 (most preedits are short); a follow-up could flip the overlay above the cursor near the bottom edge.
- **Long preedit**: container clips at the parent's right edge (default Flutter behavior).
- **`updateEditingValue` ordering** across platforms: Linux GTK verified manually; other platforms may need adjustments.
