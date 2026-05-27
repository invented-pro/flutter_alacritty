# Plan 2D — Acceptance Findings

**Date:** 2026-05-27  
**Branch:** `feature/d-scrollback-selection`  
**Base:** `f44ecb6` (main + A/C/B merged)

## Automated verification

| Check | Result |
|-------|--------|
| `cd rust && cargo build` | PASS |
| `cargo test engine` | 13/13 PASS (incl. `scroll_shows_history_then_returns_to_bottom`, `selection_text_and_selected_flag`) |
| `flutter test` | 57/57 PASS |
| `flutter analyze lib test` | No issues |

## Acceptance checklist (manual — Linux)

| Item | Status | Notes |
|------|--------|-------|
| D1: wheel scrolls back through long output | **Pending manual** | `ls -la /usr/bin \| head -100`, wheel up |
| D1: keypress snaps to bottom | **Pending manual** | Type after scrolling |
| D1: `less`/vim wheel scrolls pager (alt-screen arrows) | **Pending manual** | SS3 A/B ×3 per notch |
| D1: cursor hidden while scrolled | **Pending manual** | Engine sets `cursor_visible && display_offset == 0` |
| D2: drag-select highlights | **Pending manual** | Translucent `0x553A6EA5` overlay |
| D2: double-click word, triple-click line | **Pending manual** | 300 ms click-count window |
| D2: `Ctrl+Shift+C` copies (incl. scrollback span) | **Pending manual** | Uses `selection_to_string()` |
| D2: typing clears selection | **Pending manual** | `selectionClear` before PTY write |
| D3: middle-click pastes selection | **Pending manual** | In-app `_primary`, `pasteBytes` bracketing |

## Implementation notes

- **Selection highlight:** fixed accent `Color(0x553A6EA5)` over cell background in painter Pass 1.
- **Scroll damage:** `take_damage` returns full snapshot when `display_offset > 0`; offset-0 keeps per-line damage.
- **Selection damage:** selection changes go through `takeDamage()` / full path from UI (`_refreshSelection`); partial damage does not set `FLAG_SELECTED`.
- **FRB native lib:** after codegen, rebuild Rust (`cargo build`) and refresh Linux bundle `.so` or `flutter build linux --debug` to avoid FRB content-hash mismatch in `engine_bindings_test`.

## Edge cases / carry-over

- Wide characters inside selection ranges — not covered by unit tests; verify manually.
- Selection across resize — resize clears selection via engine reflow (safe fallback per design).
- Rectangular/block selection (Alt-drag) — deferred.
- Visible scrollbar widget — deferred.
- X11 PRIMARY system clipboard — out of scope; in-app `_primary` only.

## Commits (feature work)

1. `16366ab` — feat(rust): display_offset-aware render + scroll_lines/scroll_to_bottom
2. `764f816` — feat(engine): FRB scroll + carry display offset to the mirror grid
3. `9ca2926` — feat(ui): wheel scrollback, alt-screen wheel arrows, snap-to-bottom on key
4. `00c3af2` — feat(rust): alacritty selection + FLAG_SELECTED in snapshot
5. `4501780` — feat(render): selection FRB passthroughs + selected-cell highlight
6. `a77fd4d` — feat(ui): mouse selection (word/line) + Ctrl+Shift+C copy
7. `247c844` — feat(ui): middle-click pastes the in-app primary selection
