# Plan 2C — Rendering Fidelity Acceptance Findings

**Date:** 2026-05-27  
**Branch:** `worktree/plan2c-rendering-fidelity` (from `feature/c-rendering-fidelity` @ 5c0897d)  
**Worktree:** `.worktrees/plan2c-rendering-fidelity`

## Automated verification

| Suite | Result |
|-------|--------|
| `flutter test` | 40/40 passed |
| `flutter analyze lib test` | clean |
| `cd rust && cargo test` | 12/12 passed |
| `cd rust && cargo build` | OK |
| `flutter build linux --debug` | OK (native FRB lib rebuilt after `RenderUpdate` field add) |

## Acceptance checklist (manual)

| Item | Status | Notes |
|------|--------|-------|
| P1: rounded borders / `│` columns seamless | **Pending manual** | Programmatic `box_drawing` + painter intercept landed; unit tests cover geometry ops |
| P1: `├──┤` / double-line tables | **Pending manual** | Arm-weight table includes light/heavy/double junctions |
| P1: htop bars/shades | **Pending manual** | Blocks/shades/quadrants in `_blockOps`; shades use `RectOp` alpha 0.25/0.5/0.75 |
| P2: bold/underline/reverse/dim in `git diff`/`man` | **Pending manual** | `effectiveColors` + glyph cache bold/italic + decorations |
| P2: strikeout | **Pending manual** | `FLAG_STRIKEOUT` bridged; decoration line at cell mid |
| P3: `\e[5 q` blinking beam | **Pending manual** | Rust test: shape=2, blinking=true; 530 ms timer + `Listenable.merge` |
| P3: `\e[2 q` steady block | **Pending manual** | Rust test: shape=0, blinking=false |
| P3: `\e[4 q` underline cursor | **Pending manual** | `cursorRect` shape 1 |
| P3: CJK cursor spans 2 cells | **Pending manual** | Wide-char width preserved from C-1 |

## Implementation notes

- **`lineWidth`:** `(cellHeight * 0.08).clamp(1.0, 4.0)` — shared by box-drawing, underline, strikeout, beam/underline cursor. No visual tuning pass yet.
- **Box-drawing long tail:** Dashed lines (┄┅┈┉╌╍) and eighth/sextant blocks (U+2581–2587, etc.) return `[]` from `boxOps` → font fallback. Acceptable per plan (no border seams).
- **FRB:** `RenderUpdate` gained `cursor_shape: u8`, `cursor_blinking: bool`. Regenerated via `flutter_rust_bridge_codegen generate`. Dart: `cursorShape`, `cursorBlinking`.
- **CursorShape mapping:** Block=0, Underline=1, Beam=2, HollowBlock=3, Hidden=4 — matches `alacritty_terminal::vte::ansi::CursorShape`.

## Commits (P1 → P3)

1. `624e557` — box-drawing core + arm-weight ops (P1.1)
2. `eacb07e` — rounded/diagonal/blocks/shades/quadrants (P1.2)
3. `eb59830` — paintBoxGlyph + painter intercept (P1.3)
4. `ba18baf` — FLAG_DIM / FLAG_STRIKEOUT (P2.1)
5. `d6a2d76` — effectiveColors (P2.2)
6. `23f3231` — bold/italic glyph cache (P2.3)
7. `c81ddd6` — underline + strikeout (P2.4)
8. `62335e8` — cursor shape/blink in RenderUpdate (P3.1)
9. `b68c7d9` — MirrorGrid + FRB (P3.2)
10. `e610801` — cursor by shape (P3.3)
11. `4b9fbfb` — blink timer (P3.4)

## Merge recommendation

Merge `worktree/plan2c-rendering-fidelity` into `feature/c-rendering-fidelity` after manual acceptance pass on Linux (`flutter run -d linux`).
