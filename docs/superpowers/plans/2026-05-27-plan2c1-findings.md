# Plan 2C-1 — Wide-Char / CJK Acceptance Findings

**Date:** 2026-05-27  
**Branch:** `feature/c1-wide-char-cjk`  
**Worktree:** `.worktrees/plan2c1-wide-char-cjk`  
**Spec:** `docs/superpowers/specs/2026-05-27-plan2c1-wide-char-cjk-design.md`

## Implementation summary

| Task | Commit | Description |
|------|--------|-------------|
| 1 | `77f3a33` | Rust `FLAG_WIDE_SPACER` + `map_flags` |
| 2 | `3e86b86` | `cell_flags.dart` + `MirrorGrid` flags lane |
| 3 | `f7a26d7` | `engine_binding` fills flags from FRB |
| 4 | `cff9481` | Wide-aware `GlyphCache` (2× layout width) |
| 5 | `de61e58` | Two-pass painter; wide draw; spacer skip; wide cursor |
| 6 | `7a86ce2` | CJK monospace in `kTerminalTextStyle` fallback |
| 7 | (this doc) | Acceptance findings |

## Automated verification

| Check | Command | Result |
|-------|---------|--------|
| Rust unit tests | `cd rust && cargo test` | **10 passed**, 0 failed |
| Dart unit/widget tests | `flutter test` | **19 passed**, 0 failed |
| Analyzer | `flutter analyze lib test` | No issues |
| Native lib build | `cd rust && cargo build` | OK |

### Rust tests added for C-1

- `wide_char_sets_wide_and_spacer_flags` — advances UTF-8 `中`; lead cell has `FLAG_WIDE`, next cell has `FLAG_WIDE_SPACER`, spacer `codepoint` is `' '` (space).

### Dart tests added for C-1

- `mirror_grid_test`: `stores per-cell flags` (`中X` + wide/spacer flags).
- `glyph_cache_test`: `wide and narrow keys are distinct` for U+4E2D.
- `terminal_painter_test`: `draws wide glyph once and skips the spacer column` (recording cache).

## Open question resolved

**Does `WIDE_CHAR_SPACER` carry a stray `cell.c` or a space?**

After advancing `"中"`, `cells[1].codepoint` is **`' '`** (U+0020), not a duplicate of the wide glyph. The painter correctly skips glyph draw on spacer cells (`kFlagWideSpacer`); any non-space codepoint in the spacer column would be invisible to the user but is not present in practice for this case.

## Environment

- **CJK font:** `fc-match` resolves `Noto Sans Mono CJK SC` on this host.
- **Fallback chain in app:** `Noto Sans Mono CJK SC` → `WenQuanYi Zen Hei Mono` → `monospace`.
- **Latin mono:** `DejaVu Sans Mono` (`kTerminalFontFamily`).

## Manual acceptance checklist

Run from worktree after rebuilding the native lib:

```bash
cd rust && cargo build && cd ..
flutter run -d linux
```

| Item | Status | Notes |
|------|--------|-------|
| `echo 中文测试` aligned, no overlap | **Pending manual** | Requires interactive Linux run |
| `ls` with CJK filenames in columns | **Pending manual** | |
| `hello` mistype message (screenshot case) | **Pending manual** | |
| CJK + Latin mixed line grid-aligned | **Pending manual** | |
| Cursor on CJK spans two cells | **Pending manual** | Code path: `onWide ? cellWidth * 2` in `TerminalPainter` |
| Single-codepoint wide emoji | **Pending manual** | ZWJ/combining sequences out of scope |

**Layout model:** Wide glyphs are laid out in a fixed `2 × cellWidth` box; grid alignment is by cell index, not font natural advance.

## Carry-over for C-2 (text attributes)

- `cell_flags.dart` already defines `kFlagBold` … `kFlagInverse`; painter does not read them yet.
- `map_flags` in Rust already bridges bold/italic/underline/inverse; FRB carries full `u16` flags.
- Painter still single-pass for attributes (underline, inverse bg, etc.) — C-2 scope.

## Risks observed

- **`LEADING_WIDE_CHAR_SPACER`** not mapped in Rust (wide char wrapping at EOL); not in C-1 spec.
- Headless CI cannot gate visual CJK alignment; rely on unit tests + manual checklist above.
