# flutter_alacritty Plan 2B — Input Completeness (keyboard, mouse, paste)

**Date:** 2026-05-27
**Status:** Design approved, pending spec review
**Branch:** `feature/b-input-completeness` (off `main` with A + C-1 + C merged @ 158ba71)

Sub-project B brings input to fidelity, in one spec **staged into three mergeable phases**:

- **B1 — keyboard** (mode-aware encoding, modifiers, function/nav keys).
- **B2 — mouse reporting** (SGR/X10, click/drag/scroll).
- **B3 — bracketed paste + focus reporting**.

A small **foundation** (exposing the terminal's mode flags to Dart) lands in B1 and the
other phases consume it.

---

## 1. Goal & Non-Goals

**Goal.** Keyboard, mouse, and paste behave like a real terminal: app-cursor/keypad modes,
full modifier combinations, function/navigation keys, mouse reporting in the modes apps
request, and bracketed paste + focus reporting.

**Non-goals:**
- Text selection / copy / primary-selection middle-click paste (sub-project D).
- IME / composing text, dead keys (later).
- Custom keybindings / keyboard-layout remapping, kitty keyboard protocol (later).
- Scrollback on wheel when mouse reporting is off (D).

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Encoders | **Approach 1**: pure-Dart `encodeKey` / `encodeMouse` / `pasteBytes` functions (input → bytes), unit-testable; alacritty/xterm standard sequences |
| Mode flags | Carried in `RenderUpdate` (`term.mode().bits()`), cached in `MirrorGrid`; input reads the cache — lock-free, always current (only PTY output changes modes, and that triggers a drain that refreshes the cache) |
| Staging | One spec; phases B1 (keyboard) / B2 (mouse) / B3 (paste+focus), each TDD + own commit/merge |

## 3. Foundation — mode flags to Dart (lands in B1)

- **Rust:** add `mode_flags: u32` to `RenderUpdate`, set from `self.term.mode().bits()` in both
  `full_snapshot` and `take_damage`.
- **`lib/input/term_mode.dart`** (NEW): bit constants mirroring `alacritty_terminal::term::TermMode`
  (kept in sync by a comment):
  ```
  kModeAppCursor   = 1 << 1   kModeAppKeypad     = 1 << 2
  kModeMouseClick  = 1 << 3   kModeBracketedPaste= 1 << 4
  kModeSgrMouse    = 1 << 5   kModeMouseMotion   = 1 << 6
  kModeFocusInOut  = 1 << 11  kModeAltScreen     = 1 << 12
  kModeMouseDrag   = 1 << 13
  kModeMouseAny = kModeMouseClick | kModeMouseDrag | kModeMouseMotion
  ```
  plus helpers `bool appCursor(int f)`, `bool anyMouse(int f)`, `bool sgrMouse(int f)`,
  `bool bracketedPaste(int f)`, `bool focusReport(int f)`.
- **`MirrorGrid`/`GridUpdate`:** add `modeFlags` (carried like the cursor fields);
  `FrbEngineBinding._toGridUpdate` maps it. Input handlers read `_grid.modeFlags`.

## 4. Phase B1 — keyboard

Rewrite `lib/input/key_input.dart`:
```
Uint8List? encodeKey(LogicalKeyboardKey key, String? character,
    {bool shift, bool alt, bool ctrl, bool meta, required int modeFlags})
```
Modifier parameter (xterm): `mod = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0) + (meta?8:0)`.

- **Cursor/edit keys** (final bytes: ↑A ↓B →C ←D, Home H, End F):
  - no modifiers + app-cursor → SS3: `ESC O <final>`
  - no modifiers + normal → CSI: `ESC [ <final>`
  - with modifiers → `ESC [ 1 ; <mod> <final>`
- **Function keys:** F1–F4 → `ESC O P/Q/R/S` (mods: `ESC [ 1 ; <mod> P..S`);
  F5–F12 → CSI tilde `15,17,18,19,20,21,23,24` (`ESC [ <n> ~`, mods `ESC [ <n> ; <mod> ~`).
- **Navigation (CSI tilde):** Insert 2, Delete 3, PageUp 5, PageDown 6 (mods `;<mod>`).
  Home/End also accept `ESC[1~`/`ESC[4~`; emit `H`/`F` form by default.
- **Named:** Enter → `\r`; Tab → `\t`; Shift+Tab → `ESC [ Z`; Backspace → `0x7f`
  (Alt+Backspace → `ESC 0x7f`); Escape → `0x1b`.
- **Control codes:** Ctrl+`a..z` → `0x01..0x1a`; Ctrl+Space → `0x00`; Ctrl+`[` → `0x1b`,
  `\` → `0x1c`, `]` → `0x1d`, `^` → `0x1e`, `_`/`/` → `0x1f`.
- **Printable:** Alt/Meta + char → `ESC` + utf8(char); otherwise utf8(char).
- `TerminalScreen._onKey` reads modifiers from `HardwareKeyboard.instance`
  (`isShiftPressed`/`isAltPressed`/`isControlPressed`/`isMetaPressed`) and passes
  `modeFlags: _grid.modeFlags`.

## 5. Phase B2 — mouse reporting

`lib/input/mouse_input.dart` (NEW):
```
enum MouseAction { down, move, up, scrollUp, scrollDown }
Uint8List? encodeMouse(int button, MouseAction action, int col, int row,
    {bool shift, bool alt, bool ctrl, required int modeFlags})
```
- Returns `null` unless a mouse mode is active (`anyMouse(modeFlags)`), or for `move` unless
  `kModeMouseDrag`/`kModeMouseMotion` is set (drag needs a pressed button + DRAG; bare motion
  needs MOTION).
- Button code: left 0, middle 1, right 2; wheel up 64, wheel down 65; **+32** for motion
  (drag); modifiers add shift 4, alt/meta 8, ctrl 16.
- **SGR** (`sgrMouse`): `ESC [ < Cb ; col ; row M` (press/scroll) / `m` (release). 1-based col/row.
- **X10/normal** (no SGR): `ESC [ M` then bytes `32+Cb`, `32+col`, `32+row` (clamped to 255).
- `TerminalScreen`: a `Listener` (onPointerDown/Move/Up + onPointerSignal for
  `PointerScrollEvent`) computes the cell `(col,row) = (dx/cellWidth+1, dy/cellHeight+1)`,
  clamped to the grid, and writes `encodeMouse(...)` to the PTY when non-null. When mouse
  reporting is off, pointer events keep the current behavior (tap → focus); wheel is a no-op
  for now (scrollback is D).

## 6. Phase B3 — bracketed paste + focus

- **Paste:** `lib/input/paste.dart` (NEW):
  ```
  Uint8List pasteBytes(String text, {required int modeFlags})
  ```
  If `bracketedPaste(modeFlags)`: `ESC[200~` + sanitized + `ESC[201~`, where **sanitize strips
  any `ESC[201~` occurrences** from `text` (prevents a paste from breaking out — security).
  Otherwise raw `utf8(text)`.
- **Paste action:** `Ctrl+Shift+V` → `Clipboard.getData('text/plain')` → `pasteBytes` → PTY.
  (Middle-click primary-selection paste is deferred to D since it needs selection.)
- **Focus reporting:** when `focusReport(modeFlags)`, a `FocusNode` listener writes `ESC[I` on
  focus gain and `ESC[O` on loss.

## 7. Components / files touched (by phase)

```
Foundation/B1: rust/src/engine.rs (mode_flags in RenderUpdate); rust/src/api/terminal.rs (regen);
               lib/input/term_mode.dart (NEW); lib/render/mirror_grid.dart (modeFlags);
               lib/engine/engine_binding.dart (_toGridUpdate); lib/input/key_input.dart (rewrite);
               lib/ui/terminal_screen.dart (_onKey modifiers + modeFlags)
B2: lib/input/mouse_input.dart (NEW); lib/ui/terminal_screen.dart (Listener → encodeMouse)
B3: lib/input/paste.dart (NEW); lib/ui/terminal_screen.dart (Ctrl+Shift+V paste; focus listener)
```

## 8. Testing & acceptance

**Foundation (Rust):** advance `\x1b[?1h` → `mode_flags & APP_CURSOR`; `\x1b[?1000h` →
MOUSE_REPORT_CLICK; `\x1b[?1006h` → SGR_MOUSE; `\x1b[?2004h` → BRACKETED_PASTE; reset (`l`) clears.

**B1 (Dart unit):** `↑` normal → `ESC[A`, app-cursor → `ESC O A`; `Ctrl+↑` → `ESC[1;5A`;
`Alt+a` → `ESC a`; `Ctrl+a` → `0x01`; `F5` → `ESC[15~`; `Shift+F5` → `ESC[15;2~`;
`Home` → `ESC[H`; `Shift+Tab` → `ESC[Z`; `Backspace` → `0x7f`.

**B2 (Dart unit):** mouse off → `null`; SGR left-down at (3,4) → `ESC[<0;3;4M`, up → `...m`;
X10 left-down → `ESC[M` + `32,35,36`; wheel-up → button 64; drag emits only when DRAG/MOTION set.

**B3 (Dart unit):** bracketed on → wrapped + end-marker stripped; off → raw; focus seq `ESC[I`/`ESC[O`.

**Manual (Linux):** vim arrows/F-keys/PageUp; `Ctrl+→` word-jump in shell/tmux; htop & vim mouse
(click, scroll, drag-select inside vim); paste multi-line into vim (no auto-indent cascade =
bracketed paste working); focus-aware app (vim `autoread`) reacts to focus.

## 9. Risks & open questions

- **Flutter key events:** modifiers via `HardwareKeyboard.instance`; `event.character` for
  printables. Dead keys / IME composing are deferred (non-goal) — may drop some exotic input.
- **Enter = `\r`** (CR); the PTY line discipline maps it. Newline (`\n`) is not sent.
- **Meta vs Alt:** treat `Alt` as Meta (ESC prefix); `Super`/`Meta` key is not used for input.
- **Mouse cell rounding** at the right/bottom edge — clamp to `[1, cols]`/`[1, rows]`.
- **Mode-flag bit drift** between Rust `TermMode` and `term_mode.dart` (comment-guarded).
- **Open:** whether `Ctrl+Shift+C` (copy) should be reserved now — deferred to D (selection);
  B3 only claims `Ctrl+Shift+V` (paste).
