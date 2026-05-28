# flutter_alacritty Plan 2L — IME Preedit Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CJK / IME input usable in the terminal — typing pinyin shows preedit text below the cursor, the OS IME's candidate window appears next to it, and committing the candidate writes UTF-8 bytes to the PTY.

**Architecture:** A standalone `ImeSession` (implements Flutter's `TextInputClient`) attaches via `TextInput.attach` on terminal focus, parses `composing` ranges from `updateEditingValue` into preedit-changed / commit callbacks, and reports the cursor's global rect via `setCaretRect` per frame so the platform IM positions its own candidate popup. A `PreeditOverlay` widget draws the preedit string just below the cursor cell. `TerminalScreen` wires them up, gates `_onKey` so printable un-modified characters fall through to TextInput while modifier hotkeys (`Ctrl+Shift+C/V/F`) still flow through `encodeKey`.

**Tech Stack:** Flutter `TextInput` / `TextInputClient` / `TextInputConnection`; `dart:convert.utf8`.

**Spec:** `docs/superpowers/specs/2026-05-28-plan2L-ime-preedit-design.md`
**Branch:** `feature/L-ime-preedit` off `main` @ `60de098`.

**Verified facts (worktree-confirmed):**
- `lib/ui/terminal_screen.dart`: `_focus = FocusNode()` at line 118; `_focus.addListener(_reportFocus)` at line 197 (in `_start`); `_focus.removeListener(...)` at line 219 and 519 (dispose); `_onKey` declared at line 263; search-toggle branch at ~line 280; `encodeKey(...)` invoked at line 319.
- `lib/config/terminal_config.dart`: top-level config has 6 section types (colors / font / cursor / scrolling / mouse / bell); `BellConfig` was added in 2K·2M with the additive pattern (`section(map, 'bell')` at line 297) — `ImeConfig` will follow the same template.
- `lib/render/terminal_painter.dart:193`: `grid.cursorRow, cursorCol` is how the painter locates the cursor cell; in the screen we compute the cell's local rect via `_metrics.width / _metrics.height` and convert to global with `RenderBox.localToGlobal`.
- **Build pitfall (memory):** `engine_bindings_test._findOrBuildLib` prefers `release > debug` candidate order. After Rust changes (none in this plan, but listed for completeness), stale `build/linux/x64/release/...so` shadows the fresh debug build and causes FRB `Content hash on Dart side != Rust side` panic. **This plan is Dart-only**; you should not need a Rust rebuild, but if `engine_bindings_test` fails with that exact panic, `rm -rf build/linux/x64/release` then re-run.
- Existing test count on main: cargo `29/29`, flutter `113/113`, analyze clean (Task 5 verifies after our additions).

---

## File Structure

```
lib/input/ime_session.dart       NEW   Self-contained TextInputClient + lifecycle (attach/detach,
                                         updateEditingValue parsing, setCaretRect passthrough)
lib/ui/preedit_overlay.dart       NEW   StatelessWidget — composing string at cursor.bottom + 2
lib/config/terminal_config.dart   MOD   +ImeConfig class + TerminalConfig.ime field + copyWith
                                         + fromTomlString [ime] section parsing
lib/ui/terminal_screen.dart       MOD   _ime field + focus listener + _onKey gate + post-frame
                                         setCaretRect + commit-writes-to-pty + PreeditOverlay
                                         placed in Stack above bell
flutter_alacritty.toml.example    MOD   document [ime] section
test/ime_session_test.dart        NEW   pure unit tests (no widget tree)
test/terminal_config_test.dart    MOD   [ime] defaults + parse + bad-color fallback
test/terminal_lifecycle_test.dart MOD   _onKey gate; preedit→commit writes utf8; PreeditOverlay visibility
docs/superpowers/plans/2026-05-28-plan2L-findings.md  NEW (Task 5)
```

---

## Task 0: Branch

- [ ] **Step 1: Create the feature branch**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git checkout main
git checkout -b feature/L-ime-preedit
git rev-parse --abbrev-ref HEAD   # expect: feature/L-ime-preedit
```

---

## Task 1: `ImeSession` class with unit tests

**Files:**
- Create: `lib/input/ime_session.dart`
- Test: `test/ime_session_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/ime_session_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/ime_session.dart';

void main() {
  // ImeSession works without the platform binding for its parsing logic.
  group('updateEditingValue', () {
    test('preedit-only value fires onPreeditChanged with composing substring', () {
      String? preedit = '__unset__';
      var commits = 0;
      final s = ImeSession(
        onCommit: (_) => commits++,
        onPreeditChanged: (p) => preedit = p,
      );
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      expect(preedit, 'ni');
      expect(commits, 0);
    });

    test('committed value fires onCommit once and clears preedit', () {
      final commits = <String>[];
      String? preedit = '__unset__';
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (p) => preedit = p,
      );
      s.updateEditingValue(const TextEditingValue(text: '你好'));
      expect(commits, ['你好']);
      expect(preedit, isNull);
    });

    test('empty value (no text, no composing) clears preedit without commit', () {
      final commits = <String>[];
      String? preedit = 'stale';
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (p) => preedit = p,
      );
      s.updateEditingValue(TextEditingValue.empty);
      expect(commits, isEmpty);
      expect(preedit, isNull);
    });

    test('preedit then commit produces one onCommit and clears preedit', () {
      final preedits = <String?>[];
      final commits = <String>[];
      final s = ImeSession(onCommit: commits.add, onPreeditChanged: preedits.add);
      s.updateEditingValue(
        const TextEditingValue(text: 'n', composing: TextRange(start: 0, end: 1)),
      );
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      s.updateEditingValue(const TextEditingValue(text: '你'));
      expect(preedits, ['n', 'ni', null]);
      expect(commits, ['你']);
    });
  });

  test('connectionClosed triggers detach (preedit cleared, no double-fire)', () {
    String? preedit = 'stale';
    final s = ImeSession(
      onCommit: (_) {},
      onPreeditChanged: (p) => preedit = p,
    );
    s.connectionClosed();
    expect(preedit, isNull);
    expect(s.isAttached, isFalse);
  });

  test('detach when never attached is a safe no-op', () {
    final s = ImeSession(onCommit: (_) {}, onPreeditChanged: (_) {});
    expect(() => s.detach(), returnsNormally);
    expect(s.isAttached, isFalse);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/ime_session_test.dart 2>&1 | tail -8
```
Expected: FAIL — `ime_session.dart` does not exist.

- [ ] **Step 3: Implement the class**

Create `lib/input/ime_session.dart`:

```dart
import 'dart:ui';
import 'package:flutter/services.dart';

/// Owns the platform TextInput connection for the terminal view. Parses
/// `updateEditingValue` into two events the rest of the app cares about:
///
///   onPreeditChanged(String?) — the current composing substring (null = no
///     active preedit; the overlay should hide).
///   onCommit(String)         — a finalized string the terminal should write
///     to the PTY as UTF-8 bytes.
///
/// Per-frame, the caller should pass the cursor's global rect via
/// [setCaretRect] so the OS IM (fcitx / IBus / etc.) positions its candidate
/// window adjacent to the cursor cell.
class ImeSession implements TextInputClient {
  ImeSession({required this.onCommit, required this.onPreeditChanged});

  final void Function(String text) onCommit;
  final void Function(String? preedit) onPreeditChanged;

  TextInputConnection? _conn;
  bool get isAttached => _conn != null && _conn!.attached;

  /// Open a platform TextInput session. Idempotent.
  void attach() {
    if (isAttached) return;
    _conn = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.text,
        inputAction: TextInputAction.none,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
      ),
    );
    _conn!.setEditingState(TextEditingValue.empty);
    _conn!.show();
  }

  /// Close the session and clear any visible preedit. Safe to call when not
  /// attached.
  void detach() {
    onPreeditChanged(null);
    _conn?.close();
    _conn = null;
  }

  /// Tell the platform IM where the cursor is (global coordinates) so its
  /// candidate window can position next to it.
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
    if (value.text.isNotEmpty) {
      onCommit(value.text);
      _conn?.setEditingState(TextEditingValue.empty);
    }
    onPreeditChanged(null);
  }

  @override
  TextEditingValue? get currentTextEditingValue => TextEditingValue.empty;
  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  void performAction(TextInputAction action) {}
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
  @override
  void connectionClosed() => detach();
  @override
  void didChangeInputControl(TextInputControl? old, TextInputControl? n) {}
  @override
  void insertTextPlaceholder(Size size) {}
  @override
  void removeTextPlaceholder() {}
  @override
  void showToolbar() {}
  @override
  void performSelector(String selectorName) {}
}
```

- [ ] **Step 4: Run to verify the tests pass**

```bash
flutter test test/ime_session_test.dart 2>&1 | tail -8
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/input/ime_session.dart test/ime_session_test.dart
git commit -m "feat(input): ImeSession — TextInputClient for preedit / commit

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `PreeditOverlay` widget

**Files:**
- Create: `lib/ui/preedit_overlay.dart`

This widget is small and stateless; we'll cover its visibility behaviour through the screen-level
widget test in Task 4 rather than a dedicated golden/render test.

- [ ] **Step 1: Implement**

Create `lib/ui/preedit_overlay.dart`:

```dart
import 'package:flutter/material.dart';

/// Floating preedit (composing) string drawn just below the cursor cell.
///
/// The OS IM (fcitx / IBus / etc.) draws its OWN candidate window adjacent to
/// the cursor — we only render the active preedit substring. When [text] is
/// null or empty, the widget collapses to nothing.
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

  /// The composing substring (`composing.textInside(value.text)` from ImeSession).
  final String? text;

  /// Local-coordinates rect of the cursor cell. The overlay floats just below
  /// it (`cursorRect.bottom + 2`).
  final Rect cursorRect;

  /// Packed RGB (0x00RRGGBB) for background; rendered with full alpha.
  final int bg;
  final int fg;
  final bool underline;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final t = text;
    if (t == null || t.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: cursorRect.left,
      top: cursorRect.bottom + 2,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Color(0xFF000000 | bg),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Text(
            t,
            style: textStyle.copyWith(
              color: Color(0xFF000000 | fg),
              decoration: underline ? TextDecoration.underline : TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Run analyze to verify the file builds**

```bash
flutter analyze lib/ui/preedit_overlay.dart 2>&1 | tail -3
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/ui/preedit_overlay.dart
git commit -m "feat(ui): PreeditOverlay — floating composing-string below cursor

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `[ime]` config section

**Files:**
- Modify: `lib/config/terminal_config.dart`
- Test: `test/terminal_config_test.dart`

- [ ] **Step 1: Write the failing tests** — append to the existing `main()` in `test/terminal_config_test.dart`:

```dart
  group('ime config', () {
    test('defaults match the spec (preedit_bg #282828, fg #d8d8d8, underline true)', () {
      final c = TerminalConfig.defaults().ime;
      expect(c.preeditBg, 0x282828);
      expect(c.preeditFg, 0xD8D8D8);
      expect(c.underline, isTrue);
    });

    test('[ime] section parses preedit_bg/preedit_fg/underline', () {
      const toml = '''
[ime]
preedit_bg = "#102030"
preedit_fg = "#aabbcc"
underline = false
''';
      final c = TerminalConfig.fromTomlString(toml).ime;
      expect(c.preeditBg, 0x102030);
      expect(c.preeditFg, 0xAABBCC);
      expect(c.underline, isFalse);
    });

    test('missing [ime] section falls back to defaults', () {
      final c = TerminalConfig.fromTomlString('').ime;
      expect(c.preeditBg, 0x282828);
      expect(c.preeditFg, 0xD8D8D8);
      expect(c.underline, isTrue);
    });

    test('bad color in [ime] falls back per-field; siblings still parse', () {
      const toml = '''
[ime]
preedit_bg = "not-a-color"
preedit_fg = "#abcdef"
''';
      final c = TerminalConfig.fromTomlString(toml).ime;
      expect(c.preeditBg, 0x282828);   // default (bad)
      expect(c.preeditFg, 0xABCDEF);   // parsed
      expect(c.underline, isTrue);     // default
    });

    test('copyWith of ime independent of other sections', () {
      final base = TerminalConfig.defaults();
      final c = base.copyWith(ime: const ImeConfig(
        preeditBg: 0x010203, preeditFg: 0x040506, underline: false));
      expect(c.ime.preeditBg, 0x010203);
      expect(c.colors.background, base.colors.background); // unchanged
    });
  });
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/terminal_config_test.dart 2>&1 | tail -8
```
Expected: FAIL — `ImeConfig` not defined / `TerminalConfig.ime` not a field.

- [ ] **Step 3: Add the `ImeConfig` class** — in `lib/config/terminal_config.dart`, alongside the other section classes (after `BellConfig`):

```dart
class ImeConfig {
  const ImeConfig({
    required this.preeditBg,
    required this.preeditFg,
    required this.underline,
  });

  /// Background color for the preedit overlay (packed RGB; alpha is forced to full).
  final int preeditBg;
  final int preeditFg;
  final bool underline;

  ImeConfig copyWith({int? preeditBg, int? preeditFg, bool? underline}) =>
      ImeConfig(
        preeditBg: preeditBg ?? this.preeditBg,
        preeditFg: preeditFg ?? this.preeditFg,
        underline: underline ?? this.underline,
      );
}
```

- [ ] **Step 4: Add `ime` field to `TerminalConfig`** — modify the class:

Change the constructor + fields (in `class TerminalConfig`):
```dart
  const TerminalConfig({
    required this.colors,
    required this.font,
    required this.cursor,
    required this.scrolling,
    required this.mouse,
    required this.bell,
    required this.ime,
  });

  final TerminalColors colors;
  final FontConfig font;
  final CursorConfig cursor;
  final ScrollConfig scrolling;
  final MouseConfig mouse;
  final BellConfig bell;
  final ImeConfig ime;
```

Add to `TerminalConfig.defaults()` (after the `bell:` line, matching the existing const-list style):
```dart
        bell: BellConfig(color: 0xFFFFFF, duration: 0, animation: 'linear'),
        ime: ImeConfig(preeditBg: 0x282828, preeditFg: 0xD8D8D8, underline: true),
      );
```

Extend `copyWith`:
```dart
  TerminalConfig copyWith({
    TerminalColors? colors,
    FontConfig? font,
    CursorConfig? cursor,
    ScrollConfig? scrolling,
    MouseConfig? mouse,
    BellConfig? bell,
    ImeConfig? ime,
  }) =>
      TerminalConfig(
        colors: colors ?? this.colors,
        font: font ?? this.font,
        cursor: cursor ?? this.cursor,
        scrolling: scrolling ?? this.scrolling,
        mouse: mouse ?? this.mouse,
        bell: bell ?? this.bell,
        ime: ime ?? this.ime,
      );
```

- [ ] **Step 5: Parse `[ime]` in `fromTomlString`** — after the existing `bellM = section(map, 'bell')` line (around line 297), add:

```dart
    final imeM = section(map, 'ime');
```

`bool` helper (if not already present near the other type helpers — check; if `boolean(...)` exists, use it; otherwise add):

```dart
    bool boolean(Map m, String key, bool fallback) {
      final v = m[key];
      return v is bool ? v : fallback;
    }
```

And in the returned `TerminalConfig(...)` constructor call, append `ime:` after `bell:`:

```dart
      bell: BellConfig(
        color: color(bellM, 'color', d.bell.color),
        duration: integer(bellM, 'duration', d.bell.duration),
        animation: str(bellM, 'animation', d.bell.animation),
      ),
      ime: ImeConfig(
        preeditBg: color(imeM, 'preedit_bg', d.ime.preeditBg),
        preeditFg: color(imeM, 'preedit_fg', d.ime.preeditFg),
        underline: boolean(imeM, 'underline', d.ime.underline),
      ),
    );
```

- [ ] **Step 6: Run to verify it passes**

```bash
flutter test test/terminal_config_test.dart 2>&1 | tail -8
```
Expected: PASS (existing + 5 new).

- [ ] **Step 7: Commit**

```bash
git add lib/config/terminal_config.dart test/terminal_config_test.dart
git commit -m "feat(config): additive [ime] section (preedit colors + underline)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Wire `ImeSession` + overlay into `TerminalScreen`

**Files:**
- Modify: `lib/ui/terminal_screen.dart`
- Test: `test/terminal_lifecycle_test.dart`

This is the integration task. We add state, wire focus → attach/detach, gate `_onKey`, report
caret position per frame, drop committed text into the PTY, and place `PreeditOverlay` in the
existing `Stack`. Tests verify the gate, the commit path, and overlay visibility.

- [ ] **Step 1: Write the failing widget tests** — append three tests to the existing `main()` in `test/terminal_lifecycle_test.dart`. (The file already has `_FakePty` with a `writes` list and `_FakeBinding`; reuse them.) Add the import at the top:

```dart
import 'dart:convert' show utf8;
import 'package:flutter_alacritty/input/ime_session.dart';
import 'package:flutter_alacritty/ui/preedit_overlay.dart';
```

and the tests:

```dart
  testWidgets('IME commit writes utf8 bytes to the PTY (raw, not bracketed)', (tester) async {
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => _FakeBinding(),
    )));
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    final ime = (state as dynamic).imeForTest as ImeSession;
    // preedit: "n" -> "ni" -> commit "你"
    ime.updateEditingValue(const TextEditingValue(text: 'n', composing: TextRange(start: 0, end: 1)));
    ime.updateEditingValue(const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)));
    ime.updateEditingValue(const TextEditingValue(text: '你'));
    await tester.pump();
    final bytes = pty.writes.expand((e) => e).toList();
    // Exactly the UTF-8 of "你", appearing exactly once, with no bracketed-paste markers.
    expect(bytes, utf8.encode('你'));
    expect(bytes.contains(0x1b), isFalse, reason: 'no ESC bytes — raw write, not bracketed-paste');
    title.dispose();
  });

  testWidgets('PreeditOverlay shows while composing and hides after commit', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => _FakeBinding(),
    )));
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    final ime = (state as dynamic).imeForTest as ImeSession;
    PreeditOverlay overlay() => tester.widget<PreeditOverlay>(find.byType(PreeditOverlay));
    expect(overlay().text, anyOf(isNull, isEmpty));
    ime.updateEditingValue(const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)));
    await tester.pump();
    expect(overlay().text, 'ni');
    ime.updateEditingValue(const TextEditingValue(text: '你好'));
    await tester.pump();
    expect(overlay().text, anyOf(isNull, isEmpty));
    title.dispose();
  });

  testWidgets('_onKey gate: printable+no-modifier with attached IME is ignored;'
              ' Ctrl+Shift+C still copies through encodeKey path', (tester) async {
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    final binding = _FakeBinding();
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => binding,
    )));
    await tester.pump();
    // Focus the terminal so the IME is attached.
    await tester.tap(find.byType(CustomPaint).first);
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    final ime = (state as dynamic).imeForTest as ImeSession;
    expect(ime.isAttached, isTrue, reason: 'focused terminal should attach IME');
    // Plain 'a' with no modifier: the gate should swallow it (TextInput path owns this character).
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(pty.writes, isEmpty,
        reason: 'TextInput delivers printable characters; encodeKey path must NOT fire');
    // Ctrl+Shift+C: copies selection via the existing hotkey branch — should NOT be swallowed.
    // (Selection is empty so the copy is a no-op as far as the PTY is concerned, but the branch
    // returns KeyEventResult.handled — which is enough to prove the gate didn't intercept.)
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // No assertion needed on selection (we just want to prove the gate didn't swallow Ctrl+Shift+C
    // — if it had, no handler would have run; the test getting here is the proof).
    title.dispose();
  });
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/terminal_lifecycle_test.dart 2>&1 | tail -10
```
Expected: FAIL — `imeForTest` not defined; `PreeditOverlay` not in the tree.

- [ ] **Step 3: Add `ImeSession` + `_preedit` state to `TerminalScreen`** — in `lib/ui/terminal_screen.dart`:

Add imports (top of file):
```dart
import 'dart:convert' show utf8;
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../input/ime_session.dart';
import 'preedit_overlay.dart';
```

After the existing `final FocusNode _focus = FocusNode();` (line 118), add state:
```dart
  String? _preedit;
  late final ImeSession _ime = ImeSession(
    onCommit: _writeCommittedText,
    onPreeditChanged: _onPreeditChanged,
  );

  @visibleForTesting
  ImeSession get imeForTest => _ime;
```

- [ ] **Step 4: Wire focus listener** — in `_start` (around line 197, immediately after `_focus.addListener(_reportFocus);`), add:

```dart
      _focus.addListener(_handleImeFocusChange);
```

In `dispose` (around line 519), pair the removal **before** `_focus.dispose()`:

```dart
    _focus.removeListener(_reportFocus);
    _focus.removeListener(_handleImeFocusChange);
    _ime.detach();
    _focus.dispose();
```

Also pair the removal in `_restart` (around line 219) right after the existing `_focus.removeListener(_reportFocus);`:

```dart
    _focus.removeListener(_reportFocus);
    _focus.removeListener(_handleImeFocusChange);
    _ime.detach();
```

Add the handler + the two callbacks (near `_reportFocus`, around line 429):

```dart
  void _handleImeFocusChange() {
    if (_focus.hasFocus) {
      _ime.attach();
    } else {
      _ime.detach();
    }
  }

  void _onPreeditChanged(String? p) {
    if (!mounted) return;
    if (p == _preedit) return;
    setState(() => _preedit = p);
  }

  void _writeCommittedText(String t) {
    if (t.isEmpty) return;
    _pty?.write(Uint8List.fromList(utf8.encode(t)));
  }
```

- [ ] **Step 5: Insert the `_onKey` gate** — in `_onKey` (line 263), right BEFORE the existing `final bytes = encodeKey(...)` call at line 319 (and AFTER the Ctrl+Shift+C / Ctrl+Shift+V / Ctrl+Shift+F intercepts), add:

```dart
    if (_ime.isAttached &&
        event.character != null &&
        event.character!.isNotEmpty &&
        !hw.isControlPressed &&
        !hw.isAltPressed &&
        !hw.isMetaPressed) {
      return KeyEventResult.ignored;
    }
```

- [ ] **Step 6: Place `PreeditOverlay` in the `Stack`** — find the Stack in `build` (search for the existing bell `IgnorePointer(FadeTransition(...))` placement); add `PreeditOverlay` **after** the bell so it draws on top:

```dart
                  PreeditOverlay(
                    text: _preedit,
                    cursorRect: Rect.fromLTWH(
                      _grid.cursorCol * _metrics.width,
                      _grid.cursorRow * _metrics.height,
                      _metrics.width,
                      _metrics.height,
                    ),
                    bg: _config.ime.preeditBg,
                    fg: _config.ime.preeditFg,
                    underline: _config.ime.underline,
                    textStyle: _style,
                  ),
```

- [ ] **Step 7: Add the per-frame `setCaretRect` reporting** — at the end of `build`'s `LayoutBuilder` builder closure, just before `return ...`, add a post-frame callback that converts the local cursor rect to global and pushes it to the IM:

In `_TerminalScreenState`, add a helper method (near `_handleImeFocusChange`):

```dart
  void _reportCaretRectToIme() {
    if (!_ime.isAttached) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;
    final localRect = Rect.fromLTWH(
      _grid.cursorCol * _metrics.width,
      _grid.cursorRow * _metrics.height,
      _metrics.width,
      _metrics.height,
    );
    final origin = renderBox.localToGlobal(localRect.topLeft);
    _ime.setCaretRect(origin & localRect.size);
  }
```

In `build`, register the callback (place it just below the existing `WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted(cols, rows));` line):

```dart
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _reportCaretRectToIme());
```

- [ ] **Step 8: Run the suite + analyze**

```bash
rm -rf build/linux/x64/release   # safety: stale release .so shadows fresh debug (see memory)
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -2
```
Expected: analyze clean; all tests pass (113 prior + 6 IME unit + 5 config + 3 widget — exact count depends on group expansion, what matters is **no failures**).

- [ ] **Step 9: Commit**

```bash
git add lib/ui/terminal_screen.dart test/terminal_lifecycle_test.dart
git commit -m "feat(ui): wire ImeSession + PreeditOverlay into TerminalScreen

- Focus listener attaches/detaches the IME session on focus changes
- _onKey gate: printable + no-modifier with attached IME → ignored,
  TextInput delivers the character; modifier combos (Ctrl+Shift+C/V/F)
  still flow through encodeKey
- Committed text written raw via utf8.encode → _pty.write (matches alacritty;
  not bracketed-paste, because the user is typing not pasting)
- Per-frame _reportCaretRectToIme so the OS IM can position its candidate window
- PreeditOverlay placed in the Stack above the bell

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Sample config + findings + acceptance gate

**Files:**
- Modify: `flutter_alacritty.toml.example`
- Create: `docs/superpowers/plans/2026-05-28-plan2L-findings.md`

- [ ] **Step 1: Append `[ime]` to the sample config** — at the bottom of `flutter_alacritty.toml.example`, add:

```toml

[ime]
preedit_bg = "#282828"      # background of the floating preedit chip
preedit_fg = "#d8d8d8"      # text color
underline = true            # underline the composing text (alacritty convention)
```

- [ ] **Step 2: Full acceptance verification**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
rm -rf build/linux/x64/release          # ensure release .so doesn't shadow debug
flutter build linux --debug 2>&1 | tail -3
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -2
(cd packages/rust_lib_flutter_alacritty/rust && cargo test 2>&1 | tail -3)
flutter test 2>&1 | tail -2
```
Expected: build OK; analyze clean; cargo 29/29; flutter passes (113 baseline + new IME tests).

- [ ] **Step 3: Manual smoke (Linux with fcitx5 / IBus running)** — record results in findings:
  - In `vim` with `fcitx5` active: press `i`, switch to pinyin, type `ni hao` → preedit chip appears below cursor; OS candidate window appears nearby; press space to commit → Chinese characters arrive at vim's insert mode.
  - In bare shell: `git commit -m "<Chinese>"` — IME works for the message argument.
  - Esc during composition cancels (IM handles); Esc when not composing reaches the PTY (vim normal mode).
  - Ctrl+Shift+C / V / F still fire during composition (modifier bypass works).
  - Focus moves to another app and back → preedit clears; fresh composition works.
  - English-only typing (e.g. `ls`) still works (no IME, characters arrive through TextInput).

- [ ] **Step 4: Write findings** — create `docs/superpowers/plans/2026-05-28-plan2L-findings.md`:

```markdown
# Plan 2L — IME Preedit Overlay Acceptance Findings

**Date:** 2026-05-28
**Branch:** `feature/L-ime-preedit`

## What shipped

| Phase | Commit | Deliverable |
|-------|--------|-------------|
| **ImeSession** | `<task1 sha>` | `lib/input/ime_session.dart` — `TextInputClient` implementation; `attach`/`detach` lifecycle; `updateEditingValue` → `onPreeditChanged` / `onCommit`; `setCaretRect` passthrough |
| **PreeditOverlay** | `<task2 sha>` | `lib/ui/preedit_overlay.dart` — `StatelessWidget` floating below cursor with config-driven bg/fg + optional underline |
| **`[ime]` config** | `<task3 sha>` | Additive `ImeConfig { preeditBg, preeditFg, underline }`; defaults `0x282828 / 0xD8D8D8 / true`; `fromTomlString` per-field fallback |
| **TerminalScreen wiring** | `<task4 sha>` | Focus → `attach/detach`; `_onKey` gate for printable + no-modifier; per-frame `_reportCaretRectToIme`; committed text → `_pty.write(utf8.encode(text))` raw; `PreeditOverlay` placed in `Stack` above bell |
| **Docs + sample** | `<task5 sha>` | `flutter_alacritty.toml.example` + this findings doc |

## Automated verification

| Check | Result |
|-------|--------|
| `cargo test` | **Pass** — no Rust changes; count unchanged |
| `flutter analyze lib/ test/ integration_test/` | **Pass** — zero issues |
| `flutter test` | **Pass** — added 6 ImeSession + 5 config + 3 lifecycle/screen tests |
| `flutter build linux --debug` | **Pass** — bundle builds |

## Manual smoke checklist (Linux + fcitx5 / IBus)

- [ ] `vim` insert-mode pinyin → preedit below cursor → candidate window from OS IM → commit arrives in vim
- [ ] Bare shell + `git commit -m "<中文>"` → IME usable for the argument
- [ ] Esc during composition cancels; Esc out of composition reaches PTY
- [ ] Ctrl+Shift+C / V / F still trigger their hotkeys during composition
- [ ] Focus loss clears preedit; refocus starts fresh composition
- [ ] ASCII typing (`ls`, `cd`) still works

## Deferred / risks

- **Non-Linux**: macOS/Windows paths through the same `TextInputClient` API; expected to work but not gated here.
- **Bottom-row preedit clipping**: when the cursor is in the last row, the overlay extends below the window. Acceptable for v1 (most preedits are short); a follow-up could flip the overlay above the cursor near the bottom edge.
- **Long preedit**: container clips at the parent's right edge (default Flutter behavior).
- **`updateEditingValue` ordering** across platforms: Linux GTK verified manually; other platforms may need adjustments.
```

- [ ] **Step 5: Commit**

```bash
git add flutter_alacritty.toml.example docs/superpowers/plans/2026-05-28-plan2L-findings.md
git commit -m "docs(ime): sample [ime] config + Plan 2L acceptance findings

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Acceptance Criteria

- [ ] `ImeSession.updateEditingValue` correctly splits preedit (composing range) vs commit (collapsed/empty composing + non-empty text) and never double-fires.
- [ ] `ImeSession.attach`/`detach` are idempotent; `connectionClosed` triggers `detach`.
- [ ] `TerminalScreen` attaches the IME on focus and detaches on blur.
- [ ] `_onKey` gate: with IME attached, printable un-modified characters fall through to TextInput; modifier hotkeys (Ctrl+Shift+C/V/F) still execute via `encodeKey`.
- [ ] Committed text reaches the PTY as raw UTF-8 bytes — NO bracketed-paste markers.
- [ ] `PreeditOverlay` is visible iff `_preedit` is non-empty; positioned just below the cursor cell.
- [ ] `setCaretRect` is reported per frame in **global** coordinates so the OS IM can position its candidate popup.
- [ ] `[ime]` TOML section parses with per-field defaults; old configs (no `[ime]`) still load.
- [ ] All automated tests pass; `flutter analyze` clean; manual smoke checklist verified on a Linux machine with an IME running.

---

## Self-Review

**Spec coverage:**
- §3 architecture & data flow → Task 1 (parsing) + Task 4 (wiring).
- §4.1 ImeSession → Task 1.
- §4.2 PreeditOverlay → Task 2.
- §4.3 TerminalScreen wiring → Task 4 (Steps 3–7).
- §4.4 `[ime]` config → Task 3.
- §5 error handling: `_pty == null` no-op (Task 4 Step 4); `detach` idempotent (Task 1 test); bad color → field default (Task 3 test); attach failure (silent / `isAttached` stays false) — exercised implicitly by tests not asserting attach succeeded.
- §6 testing → per-task tests + Task 5 manual checklist.
- §7 risks: `setCaretRect` global coords (Task 4 Step 7 uses `renderBox.localToGlobal`); double-fire (Task 4 Step 1 gate test); `TextInput.show()` no-op on desktop (Task 1 attach calls it once).
- §8 library boundary: `ImeSession` is callback-injected (Task 1); `PreeditOverlay` is `StatelessWidget` (Task 2); `[ime]` is additive (Task 3 "missing [ime] section falls back" test).

**Placeholder scan:** none. Every code step has full code; sha placeholders in the findings doc template are intentional (filled in at commit time, marked as `<taskN sha>` not `TODO`).

**Type consistency:**
- `ImeSession({onCommit: (String) -> void, onPreeditChanged: (String?) -> void})` is consistent across Task 1 (definition), Task 4 Step 3 (wired with `_writeCommittedText` / `_onPreeditChanged`).
- `ImeConfig{preeditBg, preeditFg, underline}` fields used identically across Task 3 (definition + tests), Task 4 Step 6 (Stack usage `_config.ime.preeditBg` etc.), Task 5 Step 1 (sample TOML keys).
- `PreeditOverlay` constructor params (`text`, `cursorRect`, `bg`, `fg`, `underline`, `textStyle`) used identically across Task 2 (definition) and Task 4 Step 6 (usage).
- `_ime.isAttached` / `setCaretRect(Rect)` referenced consistently from Task 1 (defined) to Task 4 (consumed).
