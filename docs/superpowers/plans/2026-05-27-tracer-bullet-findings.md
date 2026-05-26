# Tracer-bullet acceptance findings (Plan 1 gate)

**Branch:** `feature/tracer-bullet`  
**Worktree:** `.worktrees/tracer-bullet`  
**Date:** 2026-05-27  
**Verifier:** Agent (automated build/test) + user interactive gate pending

## Automated verification (agent environment)

| Check | Result |
|-------|--------|
| `cd rust && cargo test engine` | **PASS** — 4 tests |
| `flutter analyze lib test` | **PASS** |
| `flutter build linux` | **PASS** |
| `flutter test` | **PASS** — key_input (5), mirror_grid (1), engine_bindings (1), widget placeholder (1) |
| `flutter run -d linux` (interactive) | **NOT RUN** — no display in agent environment |

## Manual acceptance checklist (Task 8)

Run locally:

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty/.worktrees/tracer-bullet
flutter run -d linux
```

| Item | Status | Notes |
|------|--------|-------|
| Prompt appears; typing is echoed | **USER** | Requires interactive run |
| `ls --color` shows colored directory entries | **USER** | |
| `echo $TERM` prints `xterm-256color` | **USER** | `FlutterPtyBackend` sets `TERM=xterm-256color` |
| 256-color block test (`for i in $(seq 0 15); do printf "\e[48;5;${i}m  \e[0m"; done; echo`) | **USER** | |
| Window resize re-flows prompt (`tput cols` after resize) | **USER** | `engineResize` + `_pty.resize` wired in `TerminalScreen` |
| Ctrl-C interrupts `sleep 100` | **USER** | `encodeKey` maps Ctrl+C → `0x03` |
| (Stretch) `vim` / `htop` | **USER** | Glitches → Plan 2; do not fix in Plan 1 |

## Plan 2 inputs

### `engine_advance` sync / jank

- FRB `engine_advance` is **sync**; `TerminalScreen._onOutput` calls it on the PTY output stream (UI isolate).
- **Expectation:** heavy output (`cat` large file) may jank the UI thread.
- **Plan 2 decision:** move `engine_advance` to an async/worker isolate; batch/coalesce PTY reads before advance.

### Full snapshot per frame

- Every PTY chunk triggers `engineSnapshot` → full `MirrorSnapshot` → `MirrorGrid.notifyListeners` → full-grid `TerminalPainter` repaint (per-cell `TextPainter`).
- **Expectation:** acceptable for tracer bullet; slow on large/reflow output.
- **Plan 2 decision:** damage-based incremental updates + glyph cache / `ParagraphBuilder` runs.

### Spec §10 open questions (resolved for Plan 1 scope)

| Question | Plan 1 resolution |
|----------|-------------------|
| `mode_flags` subset for input | **Deferred.** `encodeKey` handles default cursor mode only (Enter, arrows, Ctrl+A–Z, printable UTF-8). Plan 2: read engine mode flags for application cursor keypad, etc. |
| Damage indices viewport vs absolute | **Deferred.** Plan 1 transfers full viewport snapshot each frame; no `take_damage` yet. Plan 2: confirm viewport-relative indices when wiring damage. |
| Scrollback in `MirrorBuffer` | **Not implemented.** Engine snapshot is viewport-only (`display_iter`). Plan 2: scrollback view + history representation. |

## `alacritty_terminal` API vs plan

| Plan assumption | Actual |
|-----------------|--------|
| `TermSize` via `term::test::TermSize` | **Used as written** — exported and works |
| `Flags::ALL_UNDERLINES` | **Exists** — used in `map_flags` |
| `indexed.cell` on `display_iter` | **Works** — `indexed.cell` field access |
| Path dep `../../../opensource/alacritty/alacritty_terminal` | **Requires** repo-root symlink `flutter_alacritty/opensource` → `/home/hhoa/git/opensource` when building from `.worktrees/tracer-bullet/rust` |
| `home` crate | **Pinned** to `0.5.9` in `Cargo.lock` for rustc 1.86 (plan assumes 1.93+) |

## Other implementation notes

- **flutter_pty:** pub.dev `0.4.2` (plan `^0.4.0`); API matches `Pty.start` / `output` / `write` / `resize` / `kill`.
- **FRB:** `TerminalEngine` opaque type imported from `lib/src/rust/engine.dart` in `terminal_screen.dart` (not re-exported by `api/terminal.dart` alone).
- **Tests:** `widget_test` replaced with placeholder; `TerminalScreen` needs native shell (Task 8 manual gate).

## Rendering glitches observed

None in agent environment (no interactive UI). User should record glitches here after manual run.
