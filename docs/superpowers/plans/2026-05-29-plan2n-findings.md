# Plan 2N Findings — Live Color Resolution + Chrome Sync + OSC Color-Query Replies

**Date:** 2026-05-29  
**Branch:** `feature/N-live-color-sync`  
**Commits:**
- `3a1e065` — `rust_lib_flutter_alacritty`: `feat(engine): resolve colors from live term.colors + answer OSC color queries`
- `7750657` — `flutter_alacritty`: `feat(ui): paint chrome from snapshot colors (OSC 10/11/12 follow)` (+ FRB regen + submodule bump)

---

## What shipped

### Commit 1 (Rust + FRB codegen)

- **Live color resolution:** `TerminalEngine` resolves every packed color from `term.colors()[i].unwrap_or(palette[i])` via `live()` / `live_named()`, mirroring alacritty `display/content.rs:105`. `ansi16`, `resolve_named` (Foreground/Background/Cursor + dim variants), and blank-cell fill in `full_snapshot` all route through it.
- **Chrome header:** `RenderUpdate` gains `default_fg`, `default_bg`, `cursor_color`. Populated on every full and partial snapshot via `chrome_colors()`.
- **Cursor sentinel:** `CURSOR_COLOR_UNSET = 0xFF000000` when OSC 12 never set (impossible as a `pack()` output).
- **OSC color-query replies:** `Event::ColorRequest` no longer hits `_ => {}`. The proxy stashes `(index, Arc<Fn(Rgb)->String>)` in a side `ReplyQueue`; `advance()` drains it post-parse, resolves color via `query_color_rgb()`, and pushes `EngineEvent::PtyWrite` bytes. Unset cursor-color queries emit no reply (alacritty parity).
- **Tests:** +6 Rust unit tests (OSC 11 SET/RESET, cursor sentinel, OSC 11/12 query reply paths). Full suite: 35 passed.

### Commit 2 (Dart)

- **`GridUpdate` / `MirrorGrid`:** carry `defaultFg`, `defaultBg`, `cursorColor` from each snapshot; `apply()` updates live defaults before resize so newly-grown cells pick up OSC 11 bg.
- **`FrbEngineBinding`:** maps the three new FRB fields.
- **`cursorInk()` helper:** painter honors OSC 12 when set; keeps inverse-video cursor on `kCursorColorUnset`.
- **Tests:** +1 mirror_grid chrome test, +2 cursor_color tests. Full suite: 180 passed (after `flutter build linux --debug` to refresh the dylib).

---

## Manual verification

The example app was launched successfully (`flutter run -d linux`). Interactive OSC checks were **not** exercised in this session (require typing in a live PTY). Recommended manual checks:

| Escape | Expected |
|--------|----------|
| `printf '\e]11;#ff0000\a'` | Background turns red (existing + new cells) |
| `printf '\e]11;\a'` or colorscheme reset | Reverts to config default bg |
| `printf '\e]12;#00ff00\a'` | Cursor turns green |
| (no OSC 12) | Cursor stays inverse-video |
| `printf '\e]11;?\a'; read -r reply` | Gets an OSC 11 rgb reply (no hang) |

Rust unit tests cover SET/query/RESET paths without GPU; the table above validates end-to-end PTY round-trip + paint.

---

## Deferred to 2N-b

Still on `_ => {}` or stubbed (unchanged from pre-2N):

- **ClipboardLoad / OSC 52 paste** — empty reply; needs Dart clipboard round-trip + `[clipboard] osc52_paste` gate
- **TextAreaSizeRequest** — needs cell-pixel dimensions from Dart `CellMetrics`
- **CursorBlinkingChange** — cursor blink following app DECSCUSR state
- **MouseCursorDirty** — OSC 22 mouse cursor shape

## Deferred to 2O-b

- **`[colors.cursor]` config knob** — static cursor color override; 2N honors program-set OSC 12 only

## Not in scope (cosmetic follow-up)

- **Window/padding background** was not repointed at live `default_bg`; per-cell fill from snapshot is correct; padding bg is a small cosmetic follow-up if a consumer needs it.

---

## Surprises / notes

- **`rust_lib_flutter_alacritty` is a submodule** on its own `main`; Rust commit lives there, parent bumps the pointer in the Dart commit.
- **FRB struct change requires dylib rebuild** before FFI integration tests pass (`flutter build linux --debug` or equivalent). Pure Dart unit tests (`mirror_grid`, `cursor_color`) do not need the dylib.
- Superseded the original roadmap note proposing `EngineEvent::ColorChange` + Dart mirror — snapshot-carries-chrome avoids stale-mirror bugs (2F class).
