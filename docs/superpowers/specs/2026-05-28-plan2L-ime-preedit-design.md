# flutter_alacritty Plan 2L — IME Preedit Overlay

**Date:** 2026-05-28
**Status:** Design approved, pending spec review
**Branch:** `feature/L-ime-preedit` (off `main` @ ae353ac)

---

## 1. Goal & Non-Goals

**Goal.** Make CJK / IME input usable in the terminal. Today, typing pinyin into the terminal does
nothing visible — the OS IME (fcitx / IBus on Linux, etc.) cannot attach to our view because
`TerminalScreen` doesn't implement `TextInputClient`. After 2L, typing `ni` while focused in the
terminal shows the preedit string in a small overlay just below the cursor, the OS IME's own
candidate window appears next to it, and selecting a candidate commits the finalized text to the
PTY as UTF-8 — usable in `vim`, `git commit -m`, `ssh`, etc.

**Non-goals (explicitly deferred):**
- **Custom candidate window**: we rely on the OS IME (fcitx / IBus / IME server) to draw its own
  candidate popup. We only report the cursor position via `setCaretRect`.
- **Custom IME state indicator** (中/英 toggle icon): the OS IM panel shows this.
- **Cross-platform parity**: Linux is the primary test target; macOS/Windows are expected to work
  through Flutter's platform text-input plugin but are not gated.
- **vi-mode / keyboard-only modes**: vi-mode itself is deferred.
- **OSC IME sequences**: not a standard protocol.
- **Persisting partial composition across focus loss**: if focus moves away, preedit is dropped and
  the OS IM context resets — matches most terminals' behavior.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Platform API | Flutter's `TextInput` + `TextInputClient`. Implement `TextInputClient` on a small `ImeSession` class; attach via `TextInput.attach` when focus arrives, detach on focus loss. Subscribe with `TextInputConfiguration(inputType: text, inputAction: none, autocorrect: false, enableSuggestions: false, smartDashesType: disabled, smartQuotesType: disabled)` so the platform doesn't try to autocorrect or rewrite terminal input |
| Preedit display | **Floating overlay just below the cursor** (gnome-terminal / kitty style). A `PreeditOverlay` widget placed in the existing `Stack` shows the composing substring inside a rounded container with a slightly elevated background (`#282828`) and the configured fg color. Optional underline (alacritty / IME convention) controlled by `[ime] underline` |
| Candidate window | **OS-drawn** — we call `TextInputConnection.setCaretRect(rect)` (and `setEditableSizeAndTransform(size, matrix)`) per frame so the platform IM positions its candidate popup adjacent to the cursor. We never render candidates ourselves |
| Commit path | When `updateEditingValue` arrives with `composing == TextRange.empty` and `text` non-empty → write `utf8.encode(text)` to the PTY via `_pty.write` (raw — **not** `pasteBytes` / bracketed paste, since the user is typing, not pasting; alacritty does the same). Immediately reset the connection via `setEditingState(TextEditingValue.empty)` so the next keystroke starts clean |
| Hardware-key vs text-input split | `_onKey` gate: when `_ime.isAttached`, `event.character` is non-empty, AND no modifier (`Ctrl`/`Alt`/`Meta`) is held → return `KeyEventResult.ignored` and let `TextInputClient.updateEditingValue` deliver the character. Modifier combos (Ctrl+letter), function keys, arrows, Esc, Enter — all continue through `encodeKey` (IM doesn't consume those) |
| Config | Additive `[ime]` section. Not aligned with alacritty schema (alacritty's IME story is incomplete); we own this surface. Defaults: `preedit_bg = "#282828"`, `preedit_fg = "#d8d8d8"`, `underline = true` |
| Library boundary | `ImeSession` is a standalone class with constructor-injected `onCommit(String)` / `onPreeditChanged(String?)` callbacks. Library consumers using `TerminalScreen` get IME automatically; consumers driving the engine themselves can use `ImeSession` independently |

## 3. Architecture & data flow

```
Focus on TerminalScreen:
  ImeSession.attach()
    → TextInput.attach(self, TextInputConfiguration(...))
    → platform IM context (fcitx / IBus / etc.) connects to this view

User types pinyin "n":
  OS IM intercepts → produces preedit "n"
    → TextInputClient.updateEditingValue(TextEditingValue(text: "n", composing: TextRange(0, 1)))
    → ImeSession extracts composing.textInside(text) = "n"
    → onPreeditChanged("n") → setState → PreeditOverlay repaints

Per frame while IME attached:
  ImeSession.setCaretRect(<global rect of cursor cell>)
    → OS IM positions its candidate window adjacent to that rect

User presses space to commit "你":
  IM commits → updateEditingValue(TextEditingValue(text: "你", composing: TextRange.empty))
    → ImeSession sees composing empty + text non-empty
    → onCommit("你") → _pty.write(utf8.encode("你"))
    → ImeSession.setEditingState(TextEditingValue.empty)  // reset for next keystroke
    → onPreeditChanged(null) → PreeditOverlay hides

Focus leaves terminal:
  ImeSession.detach() → TextInputConnection.close()
  → preedit cleared, OS IM context resets
```

## 4. Components

### 4.1 `lib/input/ime_session.dart` (NEW)

Self-contained class. Owns the `TextInputConnection`, tracks the current composition state, exposes
callbacks. Implements `TextInputClient` + the subset of `TextInputClient` methods Flutter
actually invokes for a non-editing text input (most are no-ops for us).

```dart
class ImeSession implements TextInputClient {
  ImeSession({required this.onCommit, required this.onPreeditChanged});

  /// Fired when a finalized string should be written to the PTY.
  final void Function(String text) onCommit;
  /// Fired when the composing substring changes (null = no active preedit).
  final void Function(String? preedit) onPreeditChanged;

  TextInputConnection? _conn;
  bool get isAttached => _conn != null && _conn!.attached;

  void attach() {
    if (isAttached) return;
    _conn = TextInput.attach(this, const TextInputConfiguration(
      inputType: TextInputType.text,
      inputAction: TextInputAction.none,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
    ));
    _conn!.setEditingState(TextEditingValue.empty);
    _conn!.show();
  }

  void detach() {
    onPreeditChanged(null);
    _conn?.close();
    _conn = null;
  }

  /// Per-frame caret position so the OS IM positions its candidate popup correctly.
  void setCaretRect(Rect globalCaret) {
    if (!isAttached) return;
    _conn!.setCaretRect(globalCaret);
  }

  // TextInputClient ----------------------------------------------------------

  @override
  void updateEditingValue(TextEditingValue value) {
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      onPreeditChanged(composing.textInside(value.text));
      return;
    }
    // composing collapsed / empty: any non-empty text is a commit.
    if (value.text.isNotEmpty) {
      onCommit(value.text);
      _conn?.setEditingState(TextEditingValue.empty);
    }
    onPreeditChanged(null);
  }

  // No-op for terminal use:
  @override TextEditingValue? get currentTextEditingValue => TextEditingValue.empty;
  @override AutofillScope? get currentAutofillScope => null;
  @override void performAction(TextInputAction action) {}
  @override void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override void showAutocorrectionPromptRect(int start, int end) {}
  @override void connectionClosed() => detach();
  @override void didChangeInputControl(TextInputControl? old, TextInputControl? n) {}
  @override void insertTextPlaceholder(Size size) {}
  @override void removeTextPlaceholder() {}
  @override void showToolbar() {}
  @override void performSelector(String selectorName) {}
}
```

### 4.2 `lib/ui/preedit_overlay.dart` (NEW)

A pure widget — receives the preedit string, position, and config-derived style. Draws nothing
when `text` is null/empty.

```dart
class PreeditOverlay extends StatelessWidget {
  const PreeditOverlay({
    required this.text,
    required this.cursorRect,
    required this.bg,
    required this.fg,
    required this.underline,
    required this.textStyle,
    super.key,
  });

  final String? text;
  final Rect cursorRect;   // local-coordinates rect of the cursor cell
  final int bg;
  final int fg;
  final bool underline;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    if (text == null || text!.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: cursorRect.left,
      top: cursorRect.bottom + 2,                       // half-cell gap below cursor
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Color(0xFF000000 | bg),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Text(text!, style: textStyle.copyWith(
            color: Color(0xFF000000 | fg),
            decoration: underline ? TextDecoration.underline : TextDecoration.none,
          )),
        ),
      ),
    );
  }
}
```

### 4.3 `lib/ui/terminal_screen.dart` changes

- Import `ime_session.dart`, `preedit_overlay.dart`.
- New state: `late final ImeSession _ime = ImeSession(onCommit: _writeCommittedText, onPreeditChanged: _onPreeditChanged);`, `String? _preedit;`.
- `initState`: `_focus.addListener(_handleFocusChange);` so we `_ime.attach()` when focused and `detach()` otherwise.
- `_handleFocusChange`: `if (_focus.hasFocus) _ime.attach(); else _ime.detach();`.
- `_onPreeditChanged(String? p) { setState(() => _preedit = p); }`.
- `_writeCommittedText(String t) { _pty?.write(Uint8List.fromList(utf8.encode(t))); }`.
- Per-frame caret reporting in `build` via `addPostFrameCallback`: compute the cursor cell rect in
  global coordinates from `_metrics` + `_grid.cursor*` + a `RenderBox` ancestor lookup, call
  `_ime.setCaretRect(rect)`.
- `_onKey` gate (inserted **after** the existing hotkey intercepts, **before** `encodeKey`):
  ```dart
  if (_ime.isAttached &&
      event.character != null &&
      event.character!.isNotEmpty &&
      !hw.isControlPressed &&
      !hw.isAltPressed &&
      !hw.isMetaPressed) {
    return KeyEventResult.ignored; // let TextInput deliver this character
  }
  ```
- Add `PreeditOverlay(text: _preedit, cursorRect: _cursorRect, bg: cfg.ime.preeditBg, fg: cfg.ime.preeditFg, underline: cfg.ime.underline, textStyle: _style)` to the `Stack` after the bell overlay.
- `dispose`: `_ime.detach()`.

### 4.4 `lib/config/terminal_config.dart` changes (additive `[ime]`)

- New `class ImeConfig { int preeditBg; int preeditFg; bool underline; … copyWith }`.
- `TerminalConfig.ime` field (default `ImeConfig(preeditBg: 0x282828, preeditFg: 0xD8D8D8, underline: true)`).
- `fromTomlString`: read `[ime] preedit_bg/preedit_fg/underline`. Per-field fallback (2F pattern).
- `flutter_alacritty.toml.example` gets the new section appended.

## 5. Error handling

| Situation | Behavior |
|-----------|----------|
| `TextInput.attach` throws / unavailable | Silent — `_conn` stays null, `isAttached` false; non-IME ASCII still works through `encodeKey` |
| Focus lost mid-composition | `detach()` clears preedit; OS IM context resets; reattaches on next focus |
| `updateEditingValue` called with both composing AND new committed text in one tick | Treated as commit (`composing.isCollapsed` branch) — matches IM convention |
| Preedit longer than the window's right edge | Container clips at the parent's right (default Flutter behavior); YAGNI for left-drifting / line-wrapping |
| `_pty` is null (engine starting / exited) | `_writeCommittedText` no-ops; preedit overlay still updates |
| Malformed `[ime]` color | That field defaults to its built-in (2F's `parseColor` returns null → fallback) |

## 6. Testing & acceptance

**Unit (`test/ime_session_test.dart` NEW):**
- `updateEditingValue(TextEditingValue(text: "n", composing: TextRange(0,1)))` → `onPreeditChanged("n")`, `onCommit` NOT called.
- `updateEditingValue(TextEditingValue(text: "你", composing: TextRange.empty))` → `onCommit("你")` AND `onPreeditChanged(null)` (in that order).
- `connectionClosed()` → `detach()` is called; `isAttached` false.
- Re-attach idempotent.

**Widget (`test/terminal_lifecycle_test.dart` extended):**
- Simulate a preedit sequence on the screen's `ImeSession` (private — exposed via `@visibleForTesting`): preedit "n" → "ni" → commit "你" → assert `_FakePty.writes` contains `utf8.encode("你")` exactly once and **does not** contain `utf8.encode("n")` / `utf8.encode("ni")`.
- `_onKey` gate: with IME attached + `KeyEvent('a', character: 'a')` + no modifier → `_FakePty.writes` is empty (TextInput owns it); with `Ctrl+'c'` (character null or modifier set) → `_FakePty.writes` contains the encoded byte sequence (existing encodeKey path).
- `_preedit` set → `PreeditOverlay` widget is visible; cleared → not visible (smoke).

**Config:**
- `[ime]` parsing tests: defaults, custom values, bad color falls back per-field.

**Manual (Linux):**
- `fcitx5` or `ibus` running. Open the terminal, run `vim`, press `i`, switch to pinyin → type `ni hao`. Expected: preedit shows below cursor, candidate window appears nearby; pressing space commits the candidate; selected text appears in vim as Chinese.
- In bare shell: type `git commit -m "<Chinese>"` — Chinese committed cleanly.
- Esc during composition cancels (handled by IM); Esc when not composing reaches PTY (vim normal mode).
- Ctrl+Shift+C/V/F still work during composition (modifier combos bypass the gate).
- Focus moves out (Alt-Tab) → preedit clears; refocus → fresh composition session.

## 7. Risks & open questions

- **Flutter `TextInputClient` callback set is large**: the implementations list above covers the
  required surface; if a future Flutter version adds a method, fail-open with a default no-op.
- **`updateEditingValue` ordering across platforms**: Linux GTK delivers commit-then-empty in
  consistent order; macOS/Windows path may differ. We test Linux primarily; tweaks may be needed.
- **`setCaretRect` coordinate space**: must be in **global** coordinates (`RenderBox.localToGlobal`).
  Wrong space → candidate window appears at screen origin or under cursor at wrong position. Verify
  on first Linux run.
- **Double-fire risk**: if a future Flutter behaves so that both `KeyEvent('a')` AND
  `updateEditingValue("a")` arrive for plain ASCII while IME is attached, our gate suppresses the
  KeyEvent path, leaving only TextInput. The test pins this invariant.
- **`TextInput.show()`**: shows the platform soft keyboard on mobile; on desktop it's a no-op.
  Calling it on attach is safe.
- **Preedit overlay positioning when cursor is at the bottom row**: the overlay would clip below
  the window. Acceptable for v1 (most preedits are short); a follow-up could flip the overlay above
  the cursor at the last few rows.

## 8. Library boundary

`ImeSession` is a self-contained, constructor-injected class with `onCommit` / `onPreeditChanged`
callbacks and no Flutter widget dependencies (only `dart:ui` / `flutter/services`). A library
consumer can:
- Use `TerminalScreen(config: cfg)` and get IME for free.
- Or drive their own engine + use `ImeSession(onCommit: writeToPty, onPreeditChanged: drawPreedit)`
  with their own widget tree.

`PreeditOverlay` is a `StatelessWidget`, also reusable. `[ime]` config is additive: old configs
parse unchanged (per-field defaults).
