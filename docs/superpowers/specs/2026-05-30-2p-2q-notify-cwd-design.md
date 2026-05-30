## Design: OSC 7 / OSC 9 / OSC 777 — Desktop Notifications + CWD Reporting

**Date:** 2026-05-30
**Branch:** main
**Base commit:** 01bc2f8

### Motivation

vte forwards 13 OSC codes to the `Handler` trait but sends everything else (including
OSC 7, 9, 777) to `unhandled()`, which only logs. These sequences need a pre-parser:

- **OSC 7** (`ESC ] 7 ; file://host/path ST`): Shells emit this to tell the terminal
  the current working directory. Required for title-bar cwd display, "open new tab here",
  and future tabs feature.
- **OSC 9** (`ESC ] 9 ; <message> ST`): iTerm2 desktop notification. Used by build
  tools, Claude Code, etc. to notify the user.
- **OSC 777** (`ESC ] 777 ; notify; <title>; <body> ST`): iTerm2 notification with
  separate title and body.

### Approach

**Byte-stream pre-parser in Rust `advance()`** — scan incoming PTY bytes for OSC
7/9/777 before the vte parser sees them, strip matched sequences, and emit new
`EngineEvent` variants.

Why Rust (not Dart):
- Keeps OSC handling in the same layer as existing OSC 4/10/11/12/52/8 processing
- Avoids duplicating byte-scanning logic on the Dart side
- Events flow naturally through the existing EventQueue alongside clipboard/color results

### Data flow

```
PTY bytes → [osc_preparse::extract_osc_events] → filtered bytes → vte parser
                         ↓
            EngineEvent::WorkingDir / Notify
                         ↓
               EventQueue → engine_take_events()
                         ↓
           FrbEngineBinding.pumpEvents()
                         ↓
        TerminalEngine._onWorkingDir / _onNotify
                         ↓
          ValueNotifier<String> workingDir   (OSC 7)
          Stream<String>      notify         (OSC 9/777)
```

### Rust changes

1. **`event_proxy.rs`**: Two new `EngineEvent` variants:
   - `WorkingDir(String)` — OSC 7 payload
   - `Notify(String)` — OSC 9 body, or OSC 777 `"title\0body"`

2. **`osc_preparse.rs`** (new module): `extract_osc_events(bytes: &[u8]) -> (Vec<u8>, Vec<EngineEvent>)`
   - Walks bytes once looking for `ESC ] Ps ; Pt ST`
   - Extracts OSC 7/9/777, emits events, strips from output
   - Unknown OSC params (0/2/4/8/10/11/12/22/50/52/104/110/111/112) pass through untouched
   - Malformed sequences (missing terminator, non-numeric param, no semicolon, >4 KiB payload) pass through untouched
   - Bounds-checked at every step; no unsafe code

3. **`engine.rs::advance()`**: Calls `extract_osc_events()` before `parser.advance()`

4. **`lib.rs`**: `pub mod osc_preparse` (public for integration testing)

### Dart changes

1. **`EngineFactory` typedef**: Two new required callbacks: `onWorkingDir`, `onNotify`
2. **`FrbEngineBinding`**: Accepts + dispatches the two new callbacks in `pumpEvents()`
3. **`FrbEngineBinding`**: Accepts + dispatches the two new callbacks in `pumpEvents()`
3. **`RewireableEngineBinding`**: Setter for `onWorkingDir`, `onNotify`
4. **`TerminalEngine`**: Public API:
   - `ValueListenable<String> workingDir` — updated each time OSC 7 fires
   - `Stream<String> notify` — one event per OSC 9/777 notification
5. **`FakeBinding` + test fakes**: Updated to implement new methods

### OSC 777 payload format

OSC 777 uses the iTerm2 convention: `notify; <title>; <body>`. The pre-parser
combines these into a single string `"title\0body"` (null-separated) so the Dart
side can split cheaply. If the payload doesn't start with `notify`, it's treated
as a bare notification body.

### Config

No new config options. OSC 7 is always active (it's a passive status report).
OSC 9/777 are always forwarded — consumer apps decide whether to show notifications.
Future: add `[notifications]` section if a gating mechanism is desired.

### Testing

- **Rust unit tests** (17 in `osc_preparse.rs`): OSC 7/9/777 extraction, BEL/ST
  termination, multiple sequences, passthrough of unknown OSCs, malformed handling,
  payload length limits, interleaved OSC+text
- **Dart tests**: All 204 existing tests pass unmodified; FakeBinding updated to
  support new event kinds for future widget tests

### Files changed

| File | Change |
|---|---|
| `packages/rust_lib_flutter_alacritty/rust/src/event_proxy.rs` | +2 enum variants |
| `packages/rust_lib_flutter_alacritty/rust/src/osc_preparse.rs` | New: 438 lines (257 code + 181 test) |
| `packages/rust_lib_flutter_alacritty/rust/src/engine.rs` | +1 import, +5 lines in `advance()` |
| `packages/rust_lib_flutter_alacritty/rust/src/lib.rs` | +1 mod declaration |
| `lib/src/rust/event_proxy.dart` | FRB codegen: +2 freezed variants |
| `lib/engine/engine_binding.dart` | +2 callbacks in FrbEngineBinding, Rewireable, pumpEvents |
| `lib/engine/terminal_engine.dart` | +2 streams/notifiers, +2 callbacks, +EngineFactory params |
| `test/fake_binding.dart` | +2 setters, +2 pumpEvents cases |
| `test/*.dart` (3 files) | +2 params per EngineFactory lambda |
