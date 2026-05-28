# Plan 2K·2M — Hyperlinks + Desktop UX Acceptance Findings

**Date:** 2026-05-28  
**Branch:** `feature/km-hyperlinks-desktop-ux`  
**Worktree:** `.worktrees/km-hyperlinks-desktop-ux`  
**Tasks:** 0–8 (hyperlinks, hint rendering, Ctrl+click, font zoom, drag-drop, context menu, visual bell, sample config + acceptance gate)

## What shipped (by phase)

| Phase | Commit | Deliverable |
|-------|--------|-------------|
| **2K — Rust hyperlinks** | `5a7c689` | OSC 8 hyperlink interning (`hyperlinks: Vec<String>`, `hyperlink_ids: HashMap`); URL auto-detect regex on visible region; `CellData.hyperlink_id`; `FLAG_HYPERLINK = 1 << 11`; `engine_resolve_hyperlink(id)` |
| **2K — hot-path fix** | `a045fe8` | URL hint pass also runs on `take_damage` incremental path (not only full snapshot) |
| **2K — Dart render** | `0cb32e6` | `kFlagHyperlink`, `MirrorGrid.hyperlinkId` lane, `HintColors`, `applyMatchOrHint` precedence (focused-match > match > hyperlink), hyperlink underline in painter |
| **2K — Ctrl+click** | `4147e4c` | `MouseRegion` click cursor on hyperlink cells; Ctrl+left-click resolves URI via `engine_resolve_hyperlink` → `url_launcher`; injectable `UrlLauncher` for tests |
| **2M — drag-drop** | `9cceab8` | `desktop_drop` `DropTarget`; paths shell-quoted (single-quote when needed), space-joined; written through `pasteBytes` (bracketed-paste when enabled) |
| **2M — font zoom** | `c9053a6` | `Ctrl+=` / `Ctrl+-` / `Ctrl+0`; step ±1.0 clamped [6, 72]; `_metrics` / `_glyphs` / `_grid` rebuilt; prior `GlyphCache` disposed |
| **2M — drag-drop restore** | `6b6f535` | Re-applied `DropTarget` wrapper after font-zoom commit accidentally dropped it |
| **2M — context menu** | `929dc23` | gnome-terminal-style right-click menu: Copy (enabled iff selection), Paste, Search…; Open Hyperlink / Copy Hyperlink Address when on hyperlink cell; Shift+right-click bypasses menu (forwards button-2 to program) |
| **2M — visual bell** | `a1e8e96` | `BellConfig { color, duration, animation }`; `[bell]` TOML parsing; `FadeTransition` overlay on `EngineEvent::Bell` when `duration > 0`; `@visibleForTesting` helpers for widget smoke test |
| **Task 8 — docs/config** | *(this commit)* | `[colors.hints.start]` + `[bell]` appended to `flutter_alacritty.toml.example`; acceptance findings |

## Protocol addition: `FLAG_HYPERLINK` + `hyperlink_id`

Render cells now carry a fifth field across the Rust → FRB → Dart → `MirrorGrid` path:

```rust
pub struct CellData {
    pub codepoint: u32,
    pub fg: u32,
    pub bg: u32,
    pub flags: u16,
    pub hyperlink_id: u32,   // 0 = none; non-zero indexes interned URI table
}
pub const FLAG_HYPERLINK: u16 = 1 << 11;
```

Dart mirror:

```dart
const int kFlagHyperlink = 1 << 11;
// MirrorGrid stores hyperlinkId per cell; resolve at click time via engine_resolve_hyperlink(id)
```

**Precedence:** OSC 8 sequences win over URL auto-detect on the same cell. Painter hint colors lose to search match / focused-match flags (`applyMatchOrHint`).

**Additive:** Old configs and bindings that ignore `hyperlink_id` still load; unset cells default to `0`.

## Additive config: `[colors.hints.start]` + `[bell]`

Both sections are optional; missing keys fall back to alacritty-compatible defaults.

| Section | Keys | Default | Effect |
|---------|------|---------|--------|
| `[colors.hints.start]` | `background`, `foreground` | `#f4bf75` / `#181818` | Opaque highlight for auto-detected URLs and OSC 8 hyperlinks (when not overridden by search match colors) |
| `[bell]` | `color`, `duration`, `animation` | `#ffffff`, `0`, `"linear"` | `duration = 0` → audio bell only; `duration > 0` → full-screen fade overlay in `color` over `duration` ms; `animation` accepted for forward-compat (only linear curve rendered today) |

Sample keys documented in `flutter_alacritty.toml.example`.

## Automated verification

| Check | Result |
|-------|--------|
| `cargo test` (`packages/rust_lib_flutter_alacritty/rust`) | **Pass** — 29 tests (6 new hyperlink/hint tests) |
| `flutter build linux --debug` | **Pass** — `build/linux/x64/debug/bundle/flutter_alacritty` |
| `flutter analyze lib/ test/ integration_test/` | **Pass (info only)** — 1 info: `sort_child_properties_last` in `terminal_screen.dart:392` (pre-existing style lint; no errors/warnings) |
| `flutter test` | **Pass** — 111 tests |

### New / extended test coverage (highlights)

- **Rust:** `osc8_hyperlink_is_carried_on_cell_data`, `url_auto_detect_marks_visible_region`, `url_auto_detect_applies_on_take_damage_path`, `osc8_wins_over_auto_detect_when_both_apply`, `resolve_hyperlink_returns_none_for_unknown_id`
- **Dart unit:** `terminal_config_test.dart` — hint + bell defaults and TOML parsing; `terminal_painter_test.dart` — hyperlink hint precedence; `mirror_grid_test.dart` — `hyperlinkId` lane round-trip
- **Dart widget / integration:** Ctrl+click launches URL; drag-drop shell quoting; font zoom rebuild; context menu items + Shift bypass; bell animation smoke (`flashBellForTest` + extra `pump` frame)

**Note:** Rebuild native (`flutter build linux --debug`) after any Rust/FRB change before `flutter test` — the dylib is not rebuilt by `flutter test` alone.

## Manual smoke checklist (Linux)

Environment: GUI smoke requires a running display; not executed in this automated session.

| Checklist item | Status | Notes |
|----------------|--------|-------|
| `ls --hyperlink=auto ~` → gold underline; Ctrl+click opens via `xdg-open` | **Pending user verification** | Automated: OSC 8 + URL detect + Ctrl+click widget tests pass |
| `echo "see https://example.com"` → underlined URL; Ctrl+click opens | **Pending user verification** | Rust `url_auto_detect_*` tests cover detection path |
| `Ctrl+=` / `Ctrl+-` / `Ctrl+0` → visible zoom; clamps at extremes | **Pending user verification** | Widget tests cover clamp + glyph cache dispose |
| Drag file with spaces → single-quoted path at prompt via bracketed paste | **Pending user verification** | Widget test covers `_shellQuote` + `pasteBytes` |
| Right-click → Copy/Paste/Search; on hyperlink → Open / Copy Hyperlink Address; Shift+right-click → no menu | **Pending user verification** | Widget tests cover menu items + Shift bypass |
| `printf '\a'` with `bell.duration = 200` → white flash; with `0` → audio only | **Pending user verification** | Widget smoke confirms animation controller progresses when `duration > 0` |

## Deferred follow-ups (out of 2K·2M scope)

Pointers to later plans — not shipped here:

1. **Non-linear bell animations** — `[bell].animation` values beyond `"linear"` (e.g. ease curves) accepted in config but not rendered; see Plan 2L.
2. **OSC 7 cwd reporting** — working-directory tracking for smarter link/context behavior; see Plan 2L.
3. **OSC 9 desktop notifications** — forward terminal notification sequences to the host OS; see Plan 2N.
4. **IME preedit overlay** — compose-string rendering for CJK input methods; see Plan 2O.
5. **`sort_child_properties_last` lint** — cosmetic analyzer info in `terminal_screen.dart`; optional cleanup.

## Spec coverage

- §3 P1 hyperlinks → Tasks 1–3 ✅
- §4 P2 font zoom → Task 4 ✅
- §5 P3 drag-drop → Task 5 ✅
- §6 P4 context menu → Task 6 ✅
- §7 P5 visual bell → Task 7 ✅
- §9 error handling (bad URI silent, stale id, empty drop path, font clamp) ✅
- §10 testing → per-task automated tests + Task 8 manual checklist ✅
- §11 library boundary → additive `[colors.hints.start]` + `[bell]`; old configs unchanged ✅
