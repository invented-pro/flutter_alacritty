# flutter_alacritty Plan 2F — Config File & Theme

**Date:** 2026-05-28
**Status:** Design approved, pending spec review
**Branch:** `feature/f-config-theme` (off `main` @ a3da11b)

First sub-project of the post-v1 polish pipeline (**2F config → 2G search → 2J box-drawing
long-tail → 2H touch input**). 2F is the foundation: it pulls every hardcoded look-and-feel
constant into one immutable `TerminalConfig`, loaded from an alacritty-style TOML file, so the
later sub-projects (and "line-spacing polish") become config changes rather than code edits.

---

## 1. Goal & Non-Goals

**Goal.** Centralize all hardcoded presentation constants into a single immutable `TerminalConfig`
value object with built-in defaults, loaded once at startup from an alacritty-style TOML file
(`$XDG_CONFIG_HOME/flutter_alacritty/flutter_alacritty.toml`, falling back to
`$HOME/.config/...`). A missing or malformed file falls back to the built-in defaults without
crashing. The configurable surface covers: the 16-color ANSI palette + default fg/bg, font
(family/fallback/size/line-height), selection color, cursor blink interval, scrollback history
size, wheel scroll multiplier, and the double-click threshold. **Line-spacing polish is folded
into this plan** as the `[font] line_height` field.

**Non-goals (explicitly deferred):**
- Hot reload / file watching (config is read once at startup).
- OSC 4/10/11/12 runtime palette changes (the palette is static, injected at engine creation).
- Configurable cursor *color* (the cursor stays true-inverse — which is alacritty's default
  "inherit from cell" behavior — so no cursor-color key is needed).
- Key-binding / keymap configuration.
- Reading alacritty's own `alacritty.toml`, or Windows config paths.
- A settings UI. The file is the only interface.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Color resolution | Stays **in Rust**. Cells already arrive packed to `0x00RRGGBB`, so keeping resolution in Rust means **zero render-protocol change**. The hardcoded `ansi16` table + `DEFAULT_FG`/`DEFAULT_BG` consts become a per-`TerminalEngine` palette injected at `engine_new`. This mirrors alacritty's own core (it owns the palette). |
| Config split | The 18-color palette + scrollback are the only fields that cross into Rust (via `EngineConfig`). Everything else (font, blink, scroll multiplier, selection color, window bg, double-click) is consumed Dart-side. |
| Loading | Read once in `main()` before `runApp`. `TerminalConfig` flows down as a constructor arg to `TerminalScreen` (default `TerminalConfig.defaults()` so existing widget tests need no change). |
| Error policy | File absent → silent defaults (normal first run). Parse error / wrong-typed field → whole-config fallback to defaults + `debugPrint`. A single bad color string → that one field defaults, the rest load. Never crash, never block, never modal. |
| TOML library | `toml: ^0.16` (pub.dev, the standard Dart TOML parser). |
| Color format | `"#rrggbb"`, `"#aarrggbb"`, or `"0xrrggbb"`. Parsed to a packed int; alpha (if present) is preserved only for the selection overlay, stripped to RGB for palette entries. |

## 3. Config schema (alacritty subset)

```toml
[colors.primary]
background = "#181818"
foreground = "#d8d8d8"

[colors.normal]    # ANSI 0-7
black   = "#000000"
red     = "#cc0000"
green   = "#4e9a06"
yellow  = "#c4a000"
blue    = "#3465a4"
magenta = "#75507b"
cyan    = "#06989a"
white   = "#d3d7cf"

[colors.bright]    # ANSI 8-15
black   = "#555753"
red     = "#ef2929"
green   = "#8ae234"
yellow  = "#fce94f"
blue    = "#729fcf"
magenta = "#ad7fa8"
cyan    = "#34e2e2"
white   = "#eeeeec"

[colors.selection]
background = "#3a6ea5"     # Dart applies a 0x55 alpha overlay

[font]
family      = "DejaVu Sans Mono"
fallback    = ["Noto Sans Mono CJK SC", "WenQuanYi Zen Hei Mono", "monospace"]
size        = 14.0
line_height = 1.2          # multiplier; maps to TextStyle.height (line-spacing polish)

[cursor]
blink_interval = 530       # ms

[scrolling]
history    = 10000         # Rust Config.scrolling_history
multiplier = 3             # lines per wheel notch (Dart)

[mouse]
double_click_threshold = 300   # ms
```

The defaults above are the *current* v1 values verbatim (palette from `engine.rs:67-68`,
fg/bg `#d8d8d8`/`#181818`, selection `#3a6ea5`, font from `terminal_painter.dart:11-17`,
blink 530, scroll 3, double-click 300, history = alacritty default 10000).

## 4. Data flow

```
main()
  └─ TerminalConfig cfg = ConfigLoader.load()      // sync file read + parse, defaults on any failure
        │
        ├─ cfg.engineConfig  (palette[18] + scrollback) ──► FrbEngineBinding(..., engineConfig)
        │                                                      └─ engineNew(cols, rows, config) → Rust palette
        └─ cfg (whole)  ──► TerminalScreen(config: cfg)
                              ├─ window backgroundColor = cfg.colors.background
                              ├─ blink Timer period      = cfg.cursor.blinkInterval
                              ├─ scroll multiplier        = cfg.scrolling.multiplier
                              ├─ double-click window      = cfg.mouse.doubleClickThreshold
                              ├─ TerminalPainter(textStyle: cfg.textStyle, selectionColor: cfg.colors.selectionOverlay)
                              └─ GlyphCache(family/fallback/size from cfg.font)
```

`TerminalConfig.engineConfig` produces a Dart `EngineConfig(palette: List<int> /*len 18*/,
scrollback: int)` where `palette[0..15]` = ANSI, `palette[16]` = default fg, `palette[17]` =
default bg. The `EngineFactory` typedef gains an `EngineConfig engineConfig` parameter; the
default `FrbEngineBinding.new` forwards it to `engineNew`.

## 5. Rust changes (`engine.rs` + `api/terminal.rs`)

**`api/terminal.rs`:** new FRB struct + changed signature.
```rust
pub struct EngineConfig {
    pub palette: Vec<u32>,   // len 18: [0..15]=ANSI, [16]=default fg, [17]=default bg (packed 0x00RRGGBB)
    pub scrollback: u32,
}

#[frb(sync)]
pub fn engine_new(columns: u16, rows: u16, config: EngineConfig) -> TerminalEngine {
    TerminalEngine::new(columns, rows, config)
}
```

**`engine.rs`:**
- `TerminalEngine` gains `palette: [u32; 18]`.
- `TerminalEngine::new(columns, rows, config: EngineConfig)`:
  - copies `config.palette` into `[u32; 18]` (length-guarded: if `!= 18`, fall back to the
    existing hardcoded table — defensive, never panics);
  - builds `Config { scrolling_history: config.scrollback as usize, ..Default::default() }` and
    passes it to `Term::new` (instead of `Config::default()`).
- The free fns `ansi16`/`resolve_named`/`resolve_color`/`cell_data` become **methods** consulting
  `self.palette`: `ansi16(i)` → `self.palette[i]`; `Foreground/BrightForeground/Cursor/DimForeground`
  → `self.palette[16]`; `Background` → `self.palette[17]`. `xterm256(0..=15)` routes through
  `self.palette`; `16..=255` keep the computed cube/grayscale (alacritty does the same — only the
  low 16 are themeable). The dim variants keep mapping to their normal palette entry.
- The standalone-`new()` test constructor and any callers pass a default `EngineConfig`
  (helper `EngineConfig::default_palette()` returns the current hardcoded values).

The `catch_unwind` panic isolation in `api/terminal.rs` is unchanged.

## 6. Dart changes

```
NEW  lib/config/color_parse.dart        parseColor("#rrggbb"/"#aarrggbb"/"0x..") -> int? (null on bad)
NEW  lib/config/terminal_config.dart    immutable TerminalConfig + nested value types + .defaults()
                                          + .textStyle getter + .engineConfig getter + selectionOverlay
NEW  lib/config/config_loader.dart       resolveConfigPath() + load() (read+parse+per-section fallback)
MOD  pubspec.yaml                        + toml: ^0.16
MOD  lib/src/rust/api/terminal.dart      (regen) engineNew gains config; EngineConfig type
MOD  lib/engine/engine_binding.dart      FrbEngineBinding ctor takes EngineConfig, forwards to engineNew
MOD  lib/ui/terminal_screen.dart         TerminalScreen.config field (default .defaults());
                                          EngineFactory typedef + default forward engineConfig;
                                          replace 530/0xFF181818/300/3 with cfg fields;
                                          pass textStyle+selectionColor to painter, font to glyph cache
MOD  lib/render/terminal_painter.dart    TerminalPainter takes TextStyle textStyle + int selectionColor;
                                          kTerminalTextStyle kept ONLY as the source of defaults in
                                          TerminalConfig.defaults() (no longer read directly by painter)
MOD  lib/render/glyph_cache.dart         unchanged API (already parameterized); fed from cfg
MOD  lib/main.dart                        cfg = ConfigLoader.load(); pass to TerminalScreen + binding
```

`CellMetrics.measure` already derives cell height from the `TextStyle` (which now carries the
configured `height`/`fontSize`), so `line_height` flows through with no metrics change.

## 7. Error handling

| Situation | Behavior |
|-----------|----------|
| File missing | Use `TerminalConfig.defaults()` silently (expected on first run). |
| Unreadable / IO error | Defaults + `debugPrint('config: <err>; using defaults')`. |
| TOML syntax error | Defaults (whole config) + `debugPrint`. |
| Section present, one field wrong type | That field → its default; rest of the config loads. |
| Bad color string | That color → its default; `debugPrint` once for that key. |
| Palette reaches Rust wrong length | Rust falls back to its hardcoded table (belt-and-suspenders; Dart always sends 18). |

Loading is **synchronous** (`File.readAsStringSync`) so `main()` has the config before
`runApp` — no async fl: no flash-of-default-theme.

## 8. Testing & acceptance

**Rust (`engine.rs` tests):**
- Construct `TerminalEngine::new(cols, rows, EngineConfig{ palette: <custom, red=0x112233>, ... })`;
  advance bytes that emit a `NamedColor::Red` cell; `full_snapshot` shows that cell's `fg == 0x112233`
  (proves resolution consults the injected palette, not the const table).
- Custom `scrollback` is honored: advance > rows lines, `scroll_lines` reaches the configured depth.

**Dart unit:**
- `color_parse`: `#181818`→`0x181818`, `#80ffffff`→`0x80ffffff`, `0xcc0000`→`0xcc0000`,
  `"nope"`/`"#xyz"`/`""`→`null`.
- `config_loader`: a complete temp TOML → every field matches; a TOML missing `[font]` →
  font defaults, other sections honored; a syntactically broken TOML → full defaults;
  one bad color string → that field defaults, siblings load; nonexistent path → defaults.
- `TerminalConfig.engineConfig`: palette list is length 18 in the documented order;
  `selectionOverlay` carries the `0x55` alpha over the configured selection RGB.

**Dart widget:**
- `TerminalScreen(config: <bg #102030>)` with the existing fake binding → the `Scaffold`
  `backgroundColor` == `Color(0xFF102030)` (no native lib needed).
- Regression: the existing 59 tests run unchanged (default `config` constructor arg).

**Manual (Linux):**
- No config file → looks identical to v1.
- Write a config with a distinct palette (e.g. Solarized), `line_height = 1.6`, `blink_interval = 250`,
  `scrolling.multiplier = 5` → colors, line spacing, blink rate, and wheel speed all change.
- Malformed TOML → app still starts with the default look; warning in the log.

## 9. Risks & open questions

- **`Config` field name:** confirm `alacritty_terminal::term::Config` exposes `scrolling_history`
  (the git-pinned rev). If the field name differs, adapt in the one construction site; the rest of
  the design is unaffected. *(Verify in Task 1 before wiring.)*
- **FRB `Vec<u32>` marshaling:** `EngineConfig.palette` as `Vec<u32>` is a plain FRB-supported
  type; length is validated Rust-side.
- **`xterm256` low-16 routing:** indices 0..15 must go through the palette so themes affect the
  256-color path too; 16..255 stay computed (matches alacritty).
- **Default duplication:** the defaults live once in `TerminalConfig.defaults()` (Dart) and once in
  `EngineConfig::default_palette()` (Rust, only for the test constructor / length-guard fallback).
  These two must stay in sync; a Rust test asserts the fallback table equals the documented values.
- **`kTerminalTextStyle`:** retained only as the literal source for `TerminalConfig.defaults()`
  so the default font definition stays in one obvious place; the painter no longer reads it directly.
