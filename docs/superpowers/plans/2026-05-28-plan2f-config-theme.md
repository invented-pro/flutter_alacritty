# flutter_alacritty Plan 2F — Config File & Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull every hardcoded look-and-feel constant into one immutable, library-friendly `TerminalConfig`, loaded once at startup from an alacritty-style TOML file, with built-in defaults on any failure.

**Architecture:** Colors resolve in Rust (cells already arrive packed RGB → zero render-protocol change): the hardcoded ANSI table + default fg/bg become a per-`TerminalEngine` palette injected at `engine_new`. Everything else (font, line-height, blink, scroll, selection color, window bg, double-click) is a Dart `TerminalConfig` consumed by the widget. Three decoupled layers — value object (`TerminalConfig`) → pure parser (`fromTomlString`) → app-level file resolver (`ConfigLoader`) — so a library host can use just `TerminalScreen(config:)` with no file.

**Tech Stack:** Rust (`alacritty_terminal`), flutter_rust_bridge 2.12, Flutter/Dart, `toml: ^0.16`.

**Spec:** `docs/superpowers/specs/2026-05-28-plan2f-config-theme-design.md`
**Branch:** `feature/f-config-theme` off `main` @ `c823ec6`.

**Verified facts:**
- `alacritty_terminal::term::Config` derives `Default`; field `scrolling_history: usize` (default 10000). `Config { scrolling_history: n, ..Default::default() }` compiles.
- Codegen: `flutter_rust_bridge_codegen generate` (config `flutter_rust_bridge.yaml`: `rust_input: crate::api`, `dart_output: lib/src/rust`).
- Current defaults to preserve verbatim: ANSI table `engine.rs:66-69`; `DEFAULT_FG=0x00D8D8D8`, `DEFAULT_BG=0x00181818` (`engine.rs:57-58`); selection `0x553A6EA5` (`terminal_painter.dart:88`); font `DejaVu Sans Mono` + fallback `['Noto Sans Mono CJK SC','WenQuanYi Zen Hei Mono','monospace']` size 14 height 1.2 (`terminal_painter.dart:11-18`); blink 530ms (`terminal_screen.dart:71`); window bg `0xFF181818` (`:285`); double-click 300ms (`:308`); scroll 3 (`:366`).
- Existing test count: 59 (must still pass; `TerminalScreen.config` is optional, defaulting to `.defaults()`).

---

## File Structure

```
rust/src/engine.rs            EngineConfig struct + TerminalEngine.palette[18];
                                ansi16/xterm256/resolve_named/resolve_color/cell_data → &self methods
rust/src/api/terminal.rs      pub use EngineConfig; engine_new(cols,rows,config)
rust/src/frb_generated.rs     (regen)
lib/src/rust/**               (regen — engineNew gains config; EngineConfig Dart type)
lib/config/color_parse.dart   NEW  parseColor(String) -> int?
lib/config/terminal_config.dart NEW  public value object (sections + copyWith + defaults + getters + fromTomlString)
lib/config/config_loader.dart NEW  resolveConfigPath() + loadFile(path?) + load()
lib/engine/engine_binding.dart  FrbEngineBinding ctor takes engineConfig → engineNew
lib/render/terminal_painter.dart TerminalPainter gains `int selectionColor`
lib/ui/terminal_screen.dart   config field + EngineFactory param; replace 530/bg/300/3; feed painter+glyphs
lib/main.dart                 ConfigLoader.load() → MyApp → TerminalScreen(config:)
pubspec.yaml                  + toml: ^0.16
flutter_alacritty.toml.example NEW  documented sample config
test/color_parse_test.dart    NEW
test/terminal_config_test.dart NEW
test/config_loader_test.dart   NEW
test/terminal_lifecycle_test.dart  +config widget test; update 2 factory closures for engineConfig
```

---

## Task 0: Branch

- [ ] **Step 1: Create the feature branch**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git checkout main && git pull --ff-only 2>/dev/null; git checkout -b feature/f-config-theme
git rev-parse --abbrev-ref HEAD   # expect: feature/f-config-theme
```

---

## Task 1: Rust palette injection

**Files:**
- Modify: `rust/src/engine.rs` (palette field, `EngineConfig`, methods, ctor)
- Modify: `rust/src/api/terminal.rs:1,7-10` (`pub use`, `engine_new` signature)
- Regen: `rust/src/frb_generated.rs`, `lib/src/rust/**`

- [ ] **Step 1: Write the failing test** — append to the `tests` module in `rust/src/engine.rs` (before its closing `}`):

```rust
    #[test]
    fn palette_injection_overrides_ansi_colors() {
        // ANSI red (index 1) remapped to 0x112233 via injected palette.
        let mut pal = EngineConfig::default_palette();
        pal[1] = 0x0011_2233;
        let cfg = EngineConfig { palette: pal.to_vec(), scrollback: 1000 };
        let mut e = TerminalEngine::new(20, 5, cfg);
        e.advance(b"\x1b[31mR".to_vec());
        let u = e.full_snapshot();
        assert_eq!(u.lines[0].cells[0].fg & 0x00FF_FFFF, 0x0011_2233);
    }

    #[test]
    fn default_palette_matches_v1_table() {
        let p = EngineConfig::default_palette();
        assert_eq!(p[0], 0x0000_0000); // black
        assert_eq!(p[1], 0x00CC_0000); // red
        assert_eq!(p[15], 0x00EE_EEEC); // bright white
        assert_eq!(p[16], 0x00D8_D8D8); // default fg
        assert_eq!(p[17], 0x0018_1818); // default bg
    }

    #[test]
    fn custom_scrollback_is_honored() {
        let mut cfg = EngineConfig::defaults();
        cfg.scrollback = 50;
        let mut e = TerminalEngine::new(10, 3, cfg);
        for _ in 0..200 { e.advance(b"x\r\n".to_vec()); }
        e.scroll_lines(1000); // try to scroll past the (small) history
        let u = e.full_snapshot();
        assert!(u.display_offset <= 50, "offset {} exceeds history 50", u.display_offset);
    }
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd rust && cargo test palette_injection 2>&1 | tail -20
```
Expected: FAIL — `EngineConfig` not found / `new` takes 2 args.

- [ ] **Step 3: Add `EngineConfig` + `default_palette` table** — in `rust/src/engine.rs`, after the `RenderUpdate`/`columns()` block (around line 44), add:

```rust
/// Color configuration passed from Dart at engine creation.
/// `palette` is length 18: [0..15] = ANSI colors, [16] = default fg, [17] = default bg
/// (each packed 0x00RRGGBB). `scrollback` = max history lines.
#[derive(Clone, Debug)]
pub struct EngineConfig {
    pub palette: Vec<u32>,
    pub scrollback: u32,
}

impl EngineConfig {
    /// The canonical v1 palette (ANSI 0-15, then default fg, default bg).
    pub fn default_palette() -> [u32; 18] {
        [
            0x0000_0000, 0x00CC_0000, 0x004E_9A06, 0x00C4_A000, 0x0034_65A4, 0x0075_507B,
            0x0006_989A, 0x00D3_D7CF, 0x0055_5753, 0x00EF_2929, 0x008A_E234, 0x00FC_E94F,
            0x0072_9FCF, 0x00AD_7FA8, 0x0034_E2E2, 0x00EE_EEEC,
            DEFAULT_FG, DEFAULT_BG,
        ]
    }

    pub fn defaults() -> EngineConfig {
        EngineConfig { palette: Self::default_palette().to_vec(), scrollback: 10000 }
    }
}
```

- [ ] **Step 4: Add the `palette` field + thread config through `new`** — change the struct and constructor:

```rust
pub struct TerminalEngine {
    term: Term<EventProxy>,
    parser: Processor,
    events: EventQueue,
    palette: [u32; 18],
}

impl TerminalEngine {
    pub fn new(columns: u16, rows: u16, config: EngineConfig) -> TerminalEngine {
        let size = alacritty_terminal::term::test::TermSize::new(
            columns as usize,
            rows as usize,
        );
        // Length-guard: Dart always sends 18; fall back defensively if not.
        let palette: [u32; 18] = config
            .palette
            .try_into()
            .unwrap_or_else(|_| EngineConfig::default_palette());
        let events: EventQueue = Arc::new(Mutex::new(Vec::new()));
        let term_config = Config {
            scrolling_history: config.scrollback as usize,
            ..Default::default()
        };
        let mut term = Term::new(term_config, &size, EventProxy::new(events.clone()));
        term.reset_damage();
        TerminalEngine { term, parser: Processor::new(), events, palette }
    }
```

- [ ] **Step 5: Convert color resolution to methods consulting `self.palette`** — replace the free fns `ansi16`, `xterm256`, `resolve_named`, `resolve_color`, `cell_data` (lines ~64-196) with `&self` methods inside `impl TerminalEngine` (place near `line_cells`). Delete the old free fns. `pack` stays a free fn.

```rust
    fn ansi16(&self, i: u8) -> u32 {
        self.palette[i as usize]
    }

    fn xterm256(&self, i: u8) -> u32 {
        match i {
            0..=15 => self.ansi16(i),
            16..=231 => {
                let i = i - 16;
                let r = i / 36;
                let g = (i % 36) / 6;
                let b = i % 6;
                let step = |v: u8| if v == 0 { 0u8 } else { 55 + v * 40 };
                pack(step(r), step(g), step(b))
            }
            232..=255 => {
                let v = 8 + (i - 232) * 10;
                pack(v, v, v)
            }
        }
    }

    fn resolve_named(&self, c: NamedColor) -> u32 {
        use NamedColor::*;
        match c {
            Foreground | BrightForeground => self.palette[16],
            Background => self.palette[17],
            Black => self.ansi16(0),
            Red => self.ansi16(1),
            Green => self.ansi16(2),
            Yellow => self.ansi16(3),
            Blue => self.ansi16(4),
            Magenta => self.ansi16(5),
            Cyan => self.ansi16(6),
            White => self.ansi16(7),
            BrightBlack => self.ansi16(8),
            BrightRed => self.ansi16(9),
            BrightGreen => self.ansi16(10),
            BrightYellow => self.ansi16(11),
            BrightBlue => self.ansi16(12),
            BrightMagenta => self.ansi16(13),
            BrightCyan => self.ansi16(14),
            BrightWhite => self.ansi16(15),
            Cursor => self.palette[16],
            DimBlack => self.ansi16(0),
            DimRed => self.ansi16(1),
            DimGreen => self.ansi16(2),
            DimYellow => self.ansi16(3),
            DimBlue => self.ansi16(4),
            DimMagenta => self.ansi16(5),
            DimCyan => self.ansi16(6),
            DimWhite => self.ansi16(7),
            DimForeground => self.palette[16],
        }
    }

    fn resolve_color(&self, c: Color, is_fg: bool) -> u32 {
        match c {
            Color::Named(n) => self.resolve_named(n),
            Color::Spec(Rgb { r, g, b }) => pack(r, g, b),
            Color::Indexed(i) => self.xterm256(i),
            #[allow(unreachable_patterns)]
            _ => if is_fg { self.palette[16] } else { self.palette[17] },
        }
    }

    fn cell_data(&self, cell: &Cell) -> CellData {
        CellData {
            codepoint: cell.c as u32,
            fg: self.resolve_color(cell.fg, true),
            bg: self.resolve_color(cell.bg, false),
            flags: map_flags(cell.flags),
        }
    }
```

- [ ] **Step 6: Update the two `cell_data` call sites + blank cell to use the palette** — in `line_cells` (line ~277) change `cell_data(&g_line[Column(col)])` → `self.cell_data(&g_line[Column(col)])`; in `full_snapshot` (line ~323) change `cell_data(indexed.cell)` → `self.cell_data(indexed.cell)`; and change the `blank` cell (lines ~303-308) to read the injected defaults:

```rust
        let blank = CellData {
            codepoint: ' ' as u32,
            fg: self.palette[16],
            bg: self.palette[17],
            flags: 0,
        };
```

- [ ] **Step 7: Update the in-crate test constructor** — in `rust/src/engine.rs` tests module, change the helper (line ~401-403):

```rust
    fn engine(cols: u16, rows: u16) -> TerminalEngine {
        TerminalEngine::new(cols, rows, EngineConfig::defaults())
    }
```

- [ ] **Step 8: Update the FRB surface** — in `rust/src/api/terminal.rs`:
  - line 1: add `EngineConfig` to the `pub use`: `pub use crate::engine::{CellData, EngineConfig, LineUpdate, RenderUpdate, TerminalEngine};`
  - lines 7-10: change `engine_new`:

```rust
#[frb(sync)]
pub fn engine_new(columns: u16, rows: u16, config: EngineConfig) -> TerminalEngine {
    TerminalEngine::new(columns, rows, config)
}
```

- [ ] **Step 9: Run the Rust tests to verify they pass**

```bash
cd rust && cargo test 2>&1 | tail -25
```
Expected: all pass, including the 3 new tests. (If `try_into` errors on `Vec<u32> -> [u32;18]`, ensure no stray `&`; `config.palette.try_into()` consumes the Vec.)

- [ ] **Step 10: Regenerate FRB bindings**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty && flutter_rust_bridge_codegen generate 2>&1 | tail -15
```
Expected: regenerates `lib/src/rust/api/terminal.dart` (now `engineNew({required columns, required rows, required EngineConfig config})` + an `EngineConfig` class) and `rust/src/frb_generated.rs`. Confirm:

```bash
grep -n "class EngineConfig\|engineNew" lib/src/rust/api/terminal.dart | head
```

- [ ] **Step 11: Commit**

```bash
git add rust/src/engine.rs rust/src/api/terminal.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "feat(rust): inject color palette + scrollback via EngineConfig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Color parsing

**Files:**
- Create: `lib/config/color_parse.dart`
- Test: `test/color_parse_test.dart`

- [ ] **Step 1: Write the failing test** — create `test/color_parse_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/color_parse.dart';

void main() {
  test('parses #rrggbb to 0x00RRGGBB', () {
    expect(parseColor('#181818'), 0x181818);
    expect(parseColor('#CC0000'), 0xCC0000);
    expect(parseColor('#3a6ea5'), 0x3A6EA5);
  });
  test('parses #aarrggbb preserving alpha', () {
    expect(parseColor('#80ffffff'), 0x80FFFFFF);
  });
  test('parses 0x prefix', () {
    expect(parseColor('0xcc0000'), 0xCC0000);
    expect(parseColor('0XCC0000'), 0xCC0000);
  });
  test('returns null on malformed input', () {
    expect(parseColor('nope'), isNull);
    expect(parseColor('#xyz'), isNull);
    expect(parseColor('#12'), isNull);     // wrong length
    expect(parseColor('#1234567'), isNull); // 7 hex digits
    expect(parseColor(''), isNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/color_parse_test.dart 2>&1 | tail -10
```
Expected: FAIL — `color_parse.dart` does not exist.

- [ ] **Step 3: Implement** — create `lib/config/color_parse.dart`:

```dart
/// Parses an alacritty-style color string into a packed int.
///
/// Accepts `#rrggbb` and `0xrrggbb` (→ `0x00RRGGBB`) and `#aarrggbb`
/// (→ `0xAARRGGBB`, alpha preserved). Returns null on any malformed input.
int? parseColor(String s) {
  var hex = s.trim();
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  } else if (hex.startsWith('0x') || hex.startsWith('0X')) {
    hex = hex.substring(2);
  } else {
    return null;
  }
  if (hex.length != 6 && hex.length != 8) return null;
  return int.tryParse(hex, radix: 16);
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
flutter test test/color_parse_test.dart 2>&1 | tail -10
```
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/config/color_parse.dart test/color_parse_test.dart
git commit -m "feat(config): parseColor for #rrggbb/#aarrggbb/0x..

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: TerminalConfig value object

**Files:**
- Create: `lib/config/terminal_config.dart`
- Modify: `pubspec.yaml` (+ `toml`)
- Test: `test/terminal_config_test.dart`

- [ ] **Step 1: Add the toml dependency**

```bash
flutter pub add toml 2>&1 | tail -5
grep -n "toml" pubspec.yaml
```
Expected: `toml: ^0.16.0` (or current) under dependencies.

- [ ] **Step 2: Write the failing test** — create `test/terminal_config_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';

void main() {
  test('defaults match v1 constants', () {
    final c = TerminalConfig.defaults();
    expect(c.colors.background, 0x181818);
    expect(c.colors.foreground, 0xD8D8D8);
    expect(c.colors.selection, 0x3A6EA5);
    expect(c.colors.ansi.length, 16);
    expect(c.colors.ansi[1], 0xCC0000);
    expect(c.font.family, 'DejaVu Sans Mono');
    expect(c.font.fallback, ['Noto Sans Mono CJK SC', 'WenQuanYi Zen Hei Mono', 'monospace']);
    expect(c.font.size, 14.0);
    expect(c.font.lineHeight, 1.2);
    expect(c.cursor.blinkInterval, 530);
    expect(c.scrolling.history, 10000);
    expect(c.scrolling.multiplier, 3);
    expect(c.mouse.doubleClickThreshold, 300);
  });

  test('textStyle reflects font config', () {
    final c = TerminalConfig.defaults().copyWith(font: const FontConfig(
      family: 'X', fallback: ['Y'], size: 20, lineHeight: 1.5));
    final s = c.textStyle;
    expect(s.fontFamily, 'X');
    expect(s.fontFamilyFallback, ['Y']);
    expect(s.fontSize, 20);
    expect(s.height, 1.5);
  });

  test('engineConfig palette is length 18 in documented order', () {
    final ec = TerminalConfig.defaults().engineConfig;
    expect(ec.palette.length, 18);
    expect(ec.palette[1], 0xCC0000);    // ansi red
    expect(ec.palette[16], 0xD8D8D8);   // fg
    expect(ec.palette[17], 0x181818);   // bg
    expect(ec.scrollback, 10000);
  });

  test('selectionOverlay applies 0x55 alpha over selection rgb', () {
    expect(TerminalConfig.defaults().selectionOverlay, 0x553A6EA5);
  });

  test('top-level copyWith overrides one section only', () {
    final base = TerminalConfig.defaults();
    final c = base.copyWith(cursor: const CursorConfig(blinkInterval: 100));
    expect(c.cursor.blinkInterval, 100);
    expect(c.colors.background, base.colors.background); // unchanged
  });

  group('fromTomlString', () {
    test('reads every section', () {
      const toml = '''
[colors.primary]
background = "#102030"
foreground = "#ffeedd"
[colors.normal]
red = "#010203"
[colors.selection]
background = "#445566"
[font]
family = "Mono X"
size = 18.0
line_height = 1.6
fallback = ["A", "B"]
[cursor]
blink_interval = 250
[scrolling]
history = 5000
multiplier = 7
[mouse]
double_click_threshold = 400
''';
      final c = TerminalConfig.fromTomlString(toml);
      expect(c.colors.background, 0x102030);
      expect(c.colors.foreground, 0xFFEEDD);
      expect(c.colors.ansi[1], 0x010203);          // overridden red
      expect(c.colors.ansi[2], 0x4E9A06);          // un-set green keeps default
      expect(c.colors.selection, 0x445566);
      expect(c.font.family, 'Mono X');
      expect(c.font.size, 18.0);
      expect(c.font.lineHeight, 1.6);
      expect(c.font.fallback, ['A', 'B']);
      expect(c.cursor.blinkInterval, 250);
      expect(c.scrolling.history, 5000);
      expect(c.scrolling.multiplier, 7);
      expect(c.mouse.doubleClickThreshold, 400);
    });

    test('missing sections fall back to defaults', () {
      final c = TerminalConfig.fromTomlString('[font]\nsize = 22.0\n');
      expect(c.font.size, 22.0);
      expect(c.font.family, 'DejaVu Sans Mono');     // default
      expect(c.colors.background, 0x181818);         // default
      expect(c.cursor.blinkInterval, 530);           // default
    });

    test('a bad color string falls back for that field only', () {
      final c = TerminalConfig.fromTomlString(
          '[colors.primary]\nbackground = "not-a-color"\nforeground = "#abcdef"\n');
      expect(c.colors.background, 0x181818);  // default (bad)
      expect(c.colors.foreground, 0xABCDEF);  // parsed
    });
  });
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
flutter test test/terminal_config_test.dart 2>&1 | tail -10
```
Expected: FAIL — `terminal_config.dart` does not exist.

- [ ] **Step 4: Implement** — create `lib/config/terminal_config.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:toml/toml.dart';

import '../src/rust/api/terminal.dart' show EngineConfig;
import 'color_parse.dart';

/// Foreground/background/selection (packed 0x00RRGGBB) + the 16 ANSI colors.
class TerminalColors {
  const TerminalColors({
    required this.background,
    required this.foreground,
    required this.selection,
    required this.ansi,
  });

  final int background;
  final int foreground;
  final int selection;
  final List<int> ansi; // length 16

  TerminalColors copyWith({
    int? background,
    int? foreground,
    int? selection,
    List<int>? ansi,
  }) =>
      TerminalColors(
        background: background ?? this.background,
        foreground: foreground ?? this.foreground,
        selection: selection ?? this.selection,
        ansi: ansi ?? this.ansi,
      );
}

class FontConfig {
  const FontConfig({
    required this.family,
    required this.fallback,
    required this.size,
    required this.lineHeight,
  });

  final String family;
  final List<String> fallback;
  final double size;
  final double lineHeight;

  FontConfig copyWith({
    String? family,
    List<String>? fallback,
    double? size,
    double? lineHeight,
  }) =>
      FontConfig(
        family: family ?? this.family,
        fallback: fallback ?? this.fallback,
        size: size ?? this.size,
        lineHeight: lineHeight ?? this.lineHeight,
      );
}

class CursorConfig {
  const CursorConfig({required this.blinkInterval});
  final int blinkInterval; // ms
  CursorConfig copyWith({int? blinkInterval}) =>
      CursorConfig(blinkInterval: blinkInterval ?? this.blinkInterval);
}

class ScrollConfig {
  const ScrollConfig({required this.history, required this.multiplier});
  final int history;
  final int multiplier;
  ScrollConfig copyWith({int? history, int? multiplier}) =>
      ScrollConfig(history: history ?? this.history, multiplier: multiplier ?? this.multiplier);
}

class MouseConfig {
  const MouseConfig({required this.doubleClickThreshold});
  final int doubleClickThreshold; // ms
  MouseConfig copyWith({int? doubleClickThreshold}) =>
      MouseConfig(doubleClickThreshold: doubleClickThreshold ?? this.doubleClickThreshold);
}

/// Immutable, programmatic terminal configuration. Build with [TerminalConfig.defaults]
/// + [copyWith], or parse from TOML via [fromTomlString]. No file IO here — that lives
/// in ConfigLoader, so a library host can use this directly with no file.
class TerminalConfig {
  const TerminalConfig({
    required this.colors,
    required this.font,
    required this.cursor,
    required this.scrolling,
    required this.mouse,
  });

  final TerminalColors colors;
  final FontConfig font;
  final CursorConfig cursor;
  final ScrollConfig scrolling;
  final MouseConfig mouse;

  /// The v1 look-and-feel, verbatim.
  factory TerminalConfig.defaults() => const TerminalConfig(
        colors: TerminalColors(
          background: 0x181818,
          foreground: 0xD8D8D8,
          selection: 0x3A6EA5,
          ansi: [
            0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
            0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
          ],
        ),
        font: FontConfig(
          family: 'DejaVu Sans Mono',
          fallback: ['Noto Sans Mono CJK SC', 'WenQuanYi Zen Hei Mono', 'monospace'],
          size: 14.0,
          lineHeight: 1.2,
        ),
        cursor: CursorConfig(blinkInterval: 530),
        scrolling: ScrollConfig(history: 10000, multiplier: 3),
        mouse: MouseConfig(doubleClickThreshold: 300),
      );

  TerminalConfig copyWith({
    TerminalColors? colors,
    FontConfig? font,
    CursorConfig? cursor,
    ScrollConfig? scrolling,
    MouseConfig? mouse,
  }) =>
      TerminalConfig(
        colors: colors ?? this.colors,
        font: font ?? this.font,
        cursor: cursor ?? this.cursor,
        scrolling: scrolling ?? this.scrolling,
        mouse: mouse ?? this.mouse,
      );

  /// TextStyle the renderer measures cells from and feeds the glyph cache.
  TextStyle get textStyle => TextStyle(
        fontFamily: font.family,
        fontFamilyFallback: font.fallback,
        fontSize: font.size,
        height: font.lineHeight,
      );

  /// Translucent overlay color (ARGB) the painter draws over selected cells.
  int get selectionOverlay => 0x55000000 | (colors.selection & 0xFFFFFF);

  /// Palette + scrollback handed to the Rust engine. palette is length 18:
  /// [0..15] ANSI, [16] fg, [17] bg.
  EngineConfig get engineConfig => EngineConfig(
        palette: [...colors.ansi, colors.foreground, colors.background],
        scrollback: scrolling.history,
      );

  /// Parse an alacritty-style TOML document. Unknown keys are ignored; any
  /// missing or malformed field keeps its default. Pure — no file IO.
  static TerminalConfig fromTomlString(String input) {
    final map = TomlDocument.parse(input).toMap();
    final d = TerminalConfig.defaults();

    Map<String, dynamic> section(Map m, String key) =>
        (m[key] is Map) ? Map<String, dynamic>.from(m[key] as Map) : const {};

    int color(Map m, String key, int fallback) {
      final v = m[key];
      if (v is String) {
        final c = parseColor(v);
        if (c != null) return c;
      }
      return fallback;
    }

    final colorsM = section(map, 'colors');
    final primary = section(colorsM, 'primary');
    final normal = section(colorsM, 'normal');
    final bright = section(colorsM, 'bright');
    final selectionM = section(colorsM, 'selection');

    const names = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'];
    final ansi = List<int>.generate(16, (i) {
      final group = i < 8 ? normal : bright;
      return color(group, names[i % 8], d.colors.ansi[i]);
    });

    final fontM = section(map, 'font');
    List<String> fallbackList() {
      final v = fontM['fallback'];
      if (v is List) return v.map((e) => '$e').toList();
      return d.font.fallback;
    }

    double dbl(Map m, String key, double fallback) {
      final v = m[key];
      if (v is num) return v.toDouble();
      return fallback;
    }

    int integer(Map m, String key, int fallback) {
      final v = m[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return fallback;
    }

    String str(Map m, String key, String fallback) {
      final v = m[key];
      return v is String ? v : fallback;
    }

    final cursorM = section(map, 'cursor');
    final scrollM = section(map, 'scrolling');
    final mouseM = section(map, 'mouse');

    return TerminalConfig(
      colors: TerminalColors(
        background: color(primary, 'background', d.colors.background),
        foreground: color(primary, 'foreground', d.colors.foreground),
        selection: color(selectionM, 'background', d.colors.selection),
        ansi: ansi,
      ),
      font: FontConfig(
        family: str(fontM, 'family', d.font.family),
        fallback: fallbackList(),
        size: dbl(fontM, 'size', d.font.size),
        lineHeight: dbl(fontM, 'line_height', d.font.lineHeight),
      ),
      cursor: CursorConfig(
        blinkInterval: integer(cursorM, 'blink_interval', d.cursor.blinkInterval),
      ),
      scrolling: ScrollConfig(
        history: integer(scrollM, 'history', d.scrolling.history),
        multiplier: integer(scrollM, 'multiplier', d.scrolling.multiplier),
      ),
      mouse: MouseConfig(
        doubleClickThreshold:
            integer(mouseM, 'double_click_threshold', d.mouse.doubleClickThreshold),
      ),
    );
  }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
flutter test test/terminal_config_test.dart 2>&1 | tail -15
```
Expected: PASS (all groups). Note: constructing `EngineConfig` is pure Dart (no native lib), so the `engineConfig` test runs without `RustLib.init`.

- [ ] **Step 6: Commit**

```bash
git add lib/config/terminal_config.dart test/terminal_config_test.dart pubspec.yaml pubspec.lock
git commit -m "feat(config): TerminalConfig value object + fromTomlString

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: ConfigLoader (file/path layer)

**Files:**
- Create: `lib/config/config_loader.dart`
- Test: `test/config_loader_test.dart`

- [ ] **Step 1: Write the failing test** — create `test/config_loader_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/config_loader.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cfg2f'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('loadFile parses a valid file', () {
    final f = File('${tmp.path}/c.toml')
      ..writeAsStringSync('[font]\nsize = 19.0\n[colors.primary]\nbackground = "#123456"\n');
    final c = ConfigLoader.loadFile(f.path);
    expect(c.font.size, 19.0);
    expect(c.colors.background, 0x123456);
  });

  test('missing file returns defaults', () {
    final c = ConfigLoader.loadFile('${tmp.path}/nope.toml');
    expect(c.font.size, 14.0);
    expect(c.colors.background, 0x181818);
  });

  test('null path returns defaults', () {
    final c = ConfigLoader.loadFile(null);
    expect(c.font.size, 14.0);
  });

  test('broken TOML returns full defaults (no throw)', () {
    final f = File('${tmp.path}/bad.toml')..writeAsStringSync('this is = = not toml [[[');
    final c = ConfigLoader.loadFile(f.path);
    expect(c.font.size, 14.0);
    expect(c.colors.background, 0x181818);
  });

  test('resolveConfigPath prefers XDG_CONFIG_HOME', () {
    expect(
      ConfigLoader.resolveConfigPath({'XDG_CONFIG_HOME': '/xdg', 'HOME': '/home/u'}),
      '/xdg/flutter_alacritty/flutter_alacritty.toml',
    );
    expect(
      ConfigLoader.resolveConfigPath({'HOME': '/home/u'}),
      '/home/u/.config/flutter_alacritty/flutter_alacritty.toml',
    );
    expect(ConfigLoader.resolveConfigPath({}), isNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/config_loader_test.dart 2>&1 | tail -10
```
Expected: FAIL — `config_loader.dart` does not exist.

- [ ] **Step 3: Implement** — create `lib/config/config_loader.dart`:

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'terminal_config.dart';

/// App-level glue that turns an on-disk TOML file into a [TerminalConfig].
/// The only component that knows the config path; a library consumer skips it
/// and builds [TerminalConfig] directly. All failures fall back to defaults.
class ConfigLoader {
  /// `$XDG_CONFIG_HOME/flutter_alacritty/flutter_alacritty.toml`, else
  /// `$HOME/.config/...`. Null when neither env var is set.
  static String? resolveConfigPath([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final xdg = e['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return '$xdg/flutter_alacritty/flutter_alacritty.toml';
    }
    final home = e['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home/.config/flutter_alacritty/flutter_alacritty.toml';
    }
    return null;
  }

  /// Read + parse [path]. Returns defaults if [path] is null, the file is
  /// absent, or parsing throws.
  static TerminalConfig loadFile(String? path) {
    if (path == null) return TerminalConfig.defaults();
    final file = File(path);
    if (!file.existsSync()) return TerminalConfig.defaults();
    try {
      return TerminalConfig.fromTomlString(file.readAsStringSync());
    } catch (e) {
      debugPrint('config: failed to load $path ($e); using defaults');
      return TerminalConfig.defaults();
    }
  }

  /// Resolve the default path and load it (used by main()).
  static TerminalConfig load() => loadFile(resolveConfigPath());
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
flutter test test/config_loader_test.dart 2>&1 | tail -12
```
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/config/config_loader.dart test/config_loader_test.dart
git commit -m "feat(config): ConfigLoader path resolution + file loading

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Wire config into the widget tree

**Files:**
- Modify: `lib/engine/engine_binding.dart:34-41` (`FrbEngineBinding` ctor)
- Modify: `lib/render/terminal_painter.dart:50-65,85-90` (`selectionColor` param)
- Modify: `lib/ui/terminal_screen.dart` (config field, factory param, replace constants)
- Modify: `lib/main.dart`
- Modify: `test/terminal_lifecycle_test.dart` (update 2 factory closures + add widget test)

- [ ] **Step 1: Write the failing widget test** — append to `test/terminal_lifecycle_test.dart`'s `main()` (it already has `_FakePty` and `_FakeBinding`). Add the import at the top of the file:

```dart
import 'package:flutter_alacritty/config/terminal_config.dart';
```

and the test:

```dart
  testWidgets('window background comes from config', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: title,
        config: TerminalConfig.defaults()
            .copyWith(colors: TerminalConfig.defaults().colors.copyWith(background: 0x102030)),
        ptyFactory: ({required rows, required columns}) => _FakePty(),
        engineFactory: ({
          required columns,
          required rows,
          required onPtyWrite,
          required onTitle,
          required onBell,
          required onClipboard,
          required engineConfig,
        }) => _FakeBinding(),
      ),
    ));
    await tester.pump();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, const Color(0xFF102030));
    title.dispose();
  });
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/terminal_lifecycle_test.dart 2>&1 | tail -15
```
Expected: FAIL — `TerminalScreen` has no `config` param; `engineFactory` signature lacks `engineConfig`.

- [ ] **Step 3: Add `engineConfig` to `FrbEngineBinding`** — `lib/engine/engine_binding.dart`. Add the import and change the constructor:

```dart
import '../src/rust/api/terminal.dart';
```
(already imported — confirm `EngineConfig` is exported from it.) Change ctor (lines 34-41):

```dart
  FrbEngineBinding({
    required int columns,
    required int rows,
    required this.onPtyWrite,
    required this.onTitle,
    required this.onBell,
    required this.onClipboard,
    required EngineConfig engineConfig,
  }) : _engine = engineNew(columns: columns, rows: rows, config: engineConfig);
```

- [ ] **Step 4: Add `selectionColor` to the painter** — `lib/render/terminal_painter.dart`. Add the field + constructor param (lines 50-65):

```dart
  TerminalPainter({
    required this.grid,
    required this.glyphs,
    required this.cellWidth,
    required this.cellHeight,
    required this.blinkOn,
    required this.selectionColor,
  })  : _paintGeneration = grid.generation,
        super(repaint: Listenable.merge([grid, blinkOn]));

  final MirrorGrid grid;
  final GlyphCache glyphs;
  final double cellWidth;
  final double cellHeight;
  final ValueListenable<bool> blinkOn;
  final int selectionColor;
  final int _paintGeneration;
```

and use it in Pass 1 (replace the hardcoded `const Color(0x553A6EA5)` at line ~88):

```dart
        if (isSelected(grid.flagsAt(row, col))) {
          canvas.drawRect(
            Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight),
            Paint()..color = Color(selectionColor),
          );
        }
```

- [ ] **Step 5: Add `config` + factory param + replace constants** — `lib/ui/terminal_screen.dart`.

Add the import:
```dart
import '../config/terminal_config.dart';
```

Extend `EngineFactory` (lines 26-33):
```dart
typedef EngineFactory = EngineBinding Function({
  required int columns,
  required int rows,
  required void Function(Uint8List) onPtyWrite,
  required void Function(String) onTitle,
  required void Function() onBell,
  required void Function(String) onClipboard,
  required EngineConfig engineConfig,
});
```
and add its import for `EngineConfig`:
```dart
import '../src/rust/api/terminal.dart' show EngineConfig;
```

Add the widget field (constructor lines 37-48) — keep it nullable so existing callers/tests need no change:
```dart
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    required this.title,
    this.ptyFactory,
    this.engineFactory,
    this.config,
    super.key,
  });

  final ValueNotifier<String> title;
  final PtyFactory? ptyFactory;
  final EngineFactory? engineFactory;
  final TerminalConfig? config;
```

In `_TerminalScreenState`, replace the `_style`/`_metrics`/`_glyphs` block (lines 54-61):
```dart
  late final TerminalConfig _config = widget.config ?? TerminalConfig.defaults();
  late final TextStyle _style = _config.textStyle;
  late final CellMetrics _metrics = CellMetrics.measure(_style);
  late final GlyphCache _glyphs = GlyphCache(
    fontFamily: _config.font.family,
    fontFamilyFallback: _config.font.fallback,
    fontSize: _config.font.size,
    cellWidth: _metrics.width,
  );
```

Blink timer (line 71):
```dart
    _blinkTimer = Timer.periodic(
        Duration(milliseconds: _config.cursor.blinkInterval), (_) {
      _blinkOn.value = !_blinkOn.value;
    });
```

Engine factory call in `_start` (lines 122-129) — add `engineConfig`:
```dart
      final binding = (widget.engineFactory ?? FrbEngineBinding.new)(
        columns: cols,
        rows: rows,
        onPtyWrite: pty.write,
        onTitle: (t) => widget.title.value = t,
        onBell: _flashBell,
        onClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
        engineConfig: _config.engineConfig,
      );
```

Double-click window (line 308):
```dart
                  _clickCount = (now.difference(_lastClick).inMilliseconds <
                          _config.mouse.doubleClickThreshold)
                      ? (_clickCount % 3) + 1
                      : 1;
```

Wheel scroll (line 366):
```dart
                _client?.scrollLines(
                    up ? _config.scrolling.multiplier : -_config.scrolling.multiplier);
```

Scaffold bg (line 285):
```dart
      backgroundColor: Color(0xFF000000 | _config.colors.background),
```

Painter construction (lines 372-378) — pass `selectionColor`:
```dart
                    painter: TerminalPainter(
                      grid: _grid,
                      glyphs: _glyphs,
                      cellWidth: _metrics.width,
                      cellHeight: _metrics.height,
                      blinkOn: _blinkOn,
                      selectionColor: _config.selectionOverlay,
                    ),
```

- [ ] **Step 6: Update the other existing factory closure** — `test/terminal_lifecycle_test.dart` has a second engineFactory at the named-function `engineFactory({...})` (≈ line 74) and one inline (≈ line 109). Add `required engineConfig,` to **both** parameter lists so they match the new typedef. Example for the named one:

```dart
    EngineBinding engineFactory({
      required columns,
      required rows,
      required onPtyWrite,
      required onTitle,
      required onBell,
      required onClipboard,
      required engineConfig,
    }) => _FakeBinding();
```

- [ ] **Step 7: Wire `main.dart`** — load config and pass it down:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_alacritty/config/config_loader.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';
import 'package:flutter_alacritty/ui/terminal_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(MyApp(config: ConfigLoader.load()));
}

class MyApp extends StatefulWidget {
  const MyApp({required this.config, super.key});
  final TerminalConfig config;

  @override
  State<MyApp> createState() => _MyAppState();
}
```

and pass `config` to `TerminalScreen` in `build` (the `child:` arg):
```dart
      child: TerminalScreen(title: _title, config: widget.config),
```

- [ ] **Step 8: Run the whole suite + analyze**

```bash
flutter analyze 2>&1 | tail -5
flutter test 2>&1 | tail -15
```
Expected: analyze clean; all tests pass (60 = prior 59 + the new window-background test; color_parse/terminal_config/config_loader add more — total should be 59 + 4 + 8 + 5 + 1 ≈ 77, just confirm zero failures).

- [ ] **Step 9: Commit**

```bash
git add lib/engine/engine_binding.dart lib/render/terminal_painter.dart lib/ui/terminal_screen.dart lib/main.dart test/terminal_lifecycle_test.dart
git commit -m "feat(config): thread TerminalConfig through widget tree

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Sample config + acceptance gate

**Files:**
- Create: `flutter_alacritty.toml.example`
- Create: `docs/superpowers/plans/2026-05-28-plan2f-findings.md`

- [ ] **Step 1: Write the documented sample config** — create `flutter_alacritty.toml.example` (every key = its default, commented for users):

```toml
# flutter_alacritty config — copy to:
#   $XDG_CONFIG_HOME/flutter_alacritty/flutter_alacritty.toml  (or ~/.config/...)
# Any missing key uses its built-in default; a malformed file falls back entirely.
# Colors: "#rrggbb", "#aarrggbb", or "0xrrggbb".

[colors.primary]
background = "#181818"
foreground = "#d8d8d8"

[colors.normal]   # ANSI 0-7
black = "#000000"
red = "#cc0000"
green = "#4e9a06"
yellow = "#c4a000"
blue = "#3465a4"
magenta = "#75507b"
cyan = "#06989a"
white = "#d3d7cf"

[colors.bright]   # ANSI 8-15
black = "#555753"
red = "#ef2929"
green = "#8ae234"
yellow = "#fce94f"
blue = "#729fcf"
magenta = "#ad7fa8"
cyan = "#34e2e2"
white = "#eeeeec"

[colors.selection]
background = "#3a6ea5"

[font]
family = "DejaVu Sans Mono"
fallback = ["Noto Sans Mono CJK SC", "WenQuanYi Zen Hei Mono", "monospace"]
size = 14.0
line_height = 1.2

[cursor]
blink_interval = 530   # ms

[scrolling]
history = 10000
multiplier = 3         # lines per wheel notch

[mouse]
double_click_threshold = 300   # ms
```

- [ ] **Step 2: Full acceptance run**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
(cd rust && cargo test 2>&1 | tail -8)
flutter analyze 2>&1 | tail -5
flutter test 2>&1 | tail -8
flutter build linux --debug 2>&1 | tail -5    # compile check (skip if no display toolchain)
```
Expected: cargo all-pass; analyze clean; flutter all-pass; build succeeds (or the build is skipped with a noted toolchain reason).

- [ ] **Step 3: Manual smoke checklist (record results in findings)** — on a machine with a display:
  - No config file → identical to v1 (dark bg, same font/colors).
  - Write a config with a distinct palette + `line_height = 1.6` + `blink_interval = 250` + `scrolling.multiplier = 5` → colors, line spacing, blink rate, wheel speed all change.
  - Malformed TOML → app still starts at defaults; `config: failed to load …` line in the log.

- [ ] **Step 4: Write findings** — create `docs/superpowers/plans/2026-05-28-plan2f-findings.md` summarizing: what shipped, the EngineConfig protocol addition, the Dart/Rust default-sync invariant (palette duplicated in `TerminalConfig.defaults()` + `EngineConfig::default_palette()`), manual results, and any deferred follow-ups.

- [ ] **Step 5: Commit**

```bash
git add flutter_alacritty.toml.example docs/superpowers/plans/2026-05-28-plan2f-findings.md
git commit -m "docs(config): sample config + Plan 2F acceptance findings

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Acceptance Criteria

- [ ] Rust `EngineConfig` injects palette (length-guarded) + scrollback; color resolution consults `self.palette`; 3 new Rust tests pass; existing Rust tests pass.
- [ ] `parseColor` handles `#rrggbb`/`#aarrggbb`/`0x..`, null on malformed.
- [ ] `TerminalConfig` is a programmatic value object (sections + `copyWith` + `defaults()` = v1 verbatim + `textStyle`/`engineConfig`/`selectionOverlay` getters); `fromTomlString` reads the alacritty-subset schema with per-field fallback.
- [ ] `ConfigLoader` resolves XDG/HOME path and loads with full fallback on missing/broken files; never throws.
- [ ] Font, line-height, blink, scroll multiplier, double-click, window bg, selection color, ANSI palette, default fg/bg, and scrollback are all config-driven; no remaining hardcoded values for these.
- [ ] `TerminalScreen.config` is optional (defaults to `.defaults()`); the prior 59 tests pass unchanged in behavior.
- [ ] `flutter analyze` clean; `cargo test` + `flutter test` green; `flutter build linux --debug` compiles.
- [ ] `flutter_alacritty.toml.example` documents the full schema.
- [ ] Library boundary intact: `TerminalConfig` usable with no file; `fromTomlString` decoupled from `ConfigLoader`.

---

## Self-Review

**Spec coverage:** §3 schema → Task 3 `fromTomlString` + Task 6 example. §4 data flow → Task 5. §5 Rust → Task 1. §6 files → Tasks 1-5. §7 error handling → Task 3 (per-field) + Task 4 (file). §8 tests → every task's tests + Task 6 manual. §9 risks: `scrolling_history` verified; `Vec<u32>` length-guarded; xterm256 low-16 routes through palette; default duplication covered by `default_palette_matches_v1_table` (Rust) + `defaults match v1` (Dart). §10 library boundary → Task 3 (pure value object/parser) + Task 4 (separate loader) + the copyWith/fromTomlString tests.

**Placeholder scan:** none — every code step has complete code; line numbers are anchors, the engineer matches surrounding context.

**Type consistency:** `EngineConfig{palette: Vec<u32>/List<int>, scrollback: u32/int}` consistent Rust↔Dart. `TerminalConfig.engineConfig` returns the FRB `EngineConfig`. `FrbEngineBinding`, `EngineFactory`, and the two test closures all carry `required engineConfig`. Painter `selectionColor: int` matches `TerminalConfig.selectionOverlay: int`. Section type names (`TerminalColors`/`FontConfig`/`CursorConfig`/`ScrollConfig`/`MouseConfig`) used identically in the value object and tests.
