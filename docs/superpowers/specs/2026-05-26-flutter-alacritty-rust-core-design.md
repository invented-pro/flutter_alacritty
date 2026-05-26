# flutter_alacritty — Flutter Terminal Emulator on Alacritty's Rust Core

**Date:** 2026-05-26
**Status:** Design approved, pending spec review
**Scope of this doc:** v1 milestone (working local shell) + post-v1 roadmap

---

## 1. Goal & Non-Goals

**Goal.** A cross-platform terminal emulator built in Flutter whose *engine* is
Alacritty's `alacritty_terminal` Rust crate, wrapped via `flutter_rust_bridge`.
The Rust core owns the authoritative terminal state (VTE parsing + grid). Flutter
owns PTY I/O, rendering, and input.

**v1 milestone:** a working local shell — single window, single terminal. Type
commands, see correct output; vim/htop/colors all work.

**Non-goals for v1** (deferred to roadmap, §9): tabs/splits, config file, key-binding
customization, vi mode, search, theme UI, copy/paste polish, iOS/web, ligatures.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Engine | `alacritty_terminal` 0.26.x: `Term<T>` + `vte::ansi::Processor`, used **headless** (no `tty`, no `event_loop`) |
| Rust↔Dart boundary | **Approach 1** — headless core + Dart mirror buffer. Contract: "bytes in / damage out + event stream" |
| PTY | `flutter_pty` (Dart) behind a `PtyBackend` interface |
| Rendering | xterm.dart (user's fork, `github.com/hhoao/xterm.dart`) behind a `TerminalRenderer` interface; custom `CustomPainter` renderer is the planned successor |
| Platforms (v1 local-shell) | Desktop (Linux/macOS/Windows) + Android; **verified on Linux**. iOS/web are post-v1 (remote `DataSource` + WASM core) |
| De-risking | Tracer-bullet spike before building out (§5, Step 0) |
| Defaults | Reference Alacritty: shell `$SHELL || /bin/bash`, initial 80×24 then fit, Alacritty default palette, scrollback 10000 lines |

**Working principle.** The Rust core is the stable center; `flutter_pty` and
xterm.dart are *replaceable peripherals* behind interfaces we own. Swapping either
is local surgery, not a rewrite.

## 3. Architecture

```
┌──────────────────────────── Flutter (Dart) ────────────────────────────┐
│  TerminalScreen (Widget)                                                 │
│    │ key/mouse events       ▲ repaint                                    │
│    ▼                        │                                            │
│  InputEncoder ──bytes──┐    │   TerminalRenderer  «interface»            │
│  (reuse xterm input)   │    │     └─ XtermRenderer (v1) ──reads──┐       │
│                        │    │        (CustomPainter later)        │       │
│                        │    └── MirrorBuffer ◄──apply damage──────┘       │
│                        ▼         (xterm-compatible cells)    ▲            │
│  PtyBackend «interface»          TerminalEngineClient ───────┘            │
│   └─ FlutterPtyBackend          (owns engine handle)                      │
│        │ output bytes ───────────────► engine_advance(bytes)              │
│        ▲ write(bytes) ◄── PtyWrite ──── EngineEvent stream                │
└────────┼──────────────────────────────────┼────────────────────────────┘
         │ flutter_pty (FFI)                 │ flutter_rust_bridge (FFI)
┌────────▼──────────┐          ┌─────────────▼────────────────────────────┐
│  local shell PTY  │          │            Rust core crate                │
│ (forkpty/ConPTY)  │          │  TerminalEngine = Term<EventProxy>        │
└───────────────────┘          │                 + vte::ansi::Processor    │
                               │  EventProxy: EventListener → StreamSink   │
                               └───────────────────────────────────────────┘
```

### Components

**Rust core crate** (`rust/`):
- `TerminalEngine` — wraps `Term<EventProxy>` + `vte::ansi::Processor`; Mutex-guarded.
- `EventProxy` — implements `alacritty_terminal::event::EventListener`; forwards
  `Event`s into an FRB `StreamSink<EngineEvent>`.

**Dart side** (`lib/`):
- `PtyBackend` «interface» + `FlutterPtyBackend` — spawn shell; `Stream<Uint8List> output`,
  `write(Uint8List)`, `resize(rows, cols)`, `kill()`.
- `TerminalEngineClient` — owns the FRB engine handle; feeds PTY output into
  `engine_advance`; consumes `EngineEvent`s; routes `PtyWrite` back to `pty.write`.
- `MirrorBuffer` — Dart-side grid in xterm-compatible cell format; applies `LineUpdate`
  damage from Rust.
- `TerminalRenderer` «interface» + `XtermRenderer` — adapts `MirrorBuffer` to xterm.dart's
  render path.
- `InputEncoder` — key/mouse → bytes (reuse xterm.dart `input_map`), mode-aware via
  `engine_mode_flags`.
- `TerminalScreen` — widget wiring everything + resize observer (LayoutBuilder + char
  metrics → cols/rows).

### Seams (risk isolation)
- `PtyBackend` — flutter_pty is the v1 impl. Fallbacks: fork it / ~50-line dart:ffi PTY /
  move PTY into Rust `tty`.
- `TerminalRenderer` — XtermRenderer is the v1 impl. Fallback: custom `CustomPainter`
  (brought forward).
- `DataSource` — **not built in v1** (YAGNI). Future extension point above `PtyBackend`
  so SSH (iOS) / remote (web) byte sources can slot in.

## 4. Data flow & FRB boundary contract

**Output (render) path** — batched per frame to avoid FFI thrash:
1. flutter_pty emits a `Uint8List` chunk; `TerminalEngineClient` coalesces available
   bytes within a frame.
2. `engine_advance(handle, bytes)` (FRB async, runs on Rust worker thread, off the UI
   isolate) → `processor.advance(&mut term, bytes)` mutates the grid; damage accumulates.
3. `engine_take_damage(handle)` → only changed lines:
   `RenderUpdate { lines: Vec<LineUpdate{ line, cells }>, cursor, scrollback_len }`.
4. Dart applies `LineUpdate`s to `MirrorBuffer`, marks dirty → exactly one repaint per frame.

**Input path:** key → `InputEncoder.encode(event, modeFlags)` → `pty.write(bytes)`.
`modeFlags` (e.g. application-cursor-keys) come from `engine_mode_flags(handle)` so
encoding matches the terminal's current mode.

**Event back-channel:** `EventProxy.send_event` → FRB `StreamSink<EngineEvent>` → Dart
dispatch: `PtyWrite`→`pty.write` (e.g. DSR responses), `Title`→window title, `Bell`→
notify, `ClipboardStore`→clipboard.

**Resize:** LayoutBuilder + char metrics compute (cols, rows) → `engine_resize` **first**,
then `pty.resize(rows, cols)` (PTY resize sends SIGWINCH; the engine must already be sized).

### FRB API surface (initial)
```
engine_new(cols, rows) -> EngineHandle
engine_advance(handle, bytes: Vec<u8>)
engine_take_damage(handle) -> RenderUpdate
engine_resize(handle, cols, rows)
engine_mode_flags(handle) -> u32
engine_scroll(handle, delta_lines)
engine_dispose(handle)
engine_events(handle) -> Stream<EngineEvent>   // FRB StreamSink
```
**Types:** `CellData { codepoint: u32, fg: u32, bg: u32, flags: u16 }` (flags =
bold/italic/underline/inverse/wide/…); `LineUpdate { line: u32, cells: Vec<CellData> }`;
`RenderUpdate`; `CursorState { line, col, style, visible }`; `EngineEvent`
(PtyWrite/Title/Bell/ClipboardStore/…).

**Threading:** single `Term` guarded by a Mutex; `advance`/`take_damage` serialized;
parser work off the UI thread; `catch_unwind` at the FFI boundary so a parser panic
surfaces as an error event instead of crashing the app.

## 5. v1 scope & acceptance

**Step 0 — tracer-bullet spike (gate).** Minimal end-to-end: shell → flutter_pty →
`engine_advance` → `take_damage` → draw text. Success = type `ls` and see colored output.
This validates flutter_pty *and* xterm.dart integration before building out. If either
proves painful, take the documented fallback (§3 seams); the Rust core does not change.

**Defaults (per Alacritty):** shell `$SHELL || /bin/bash`; initial 80×24 then fit;
Alacritty default 16/256 palette; scrollback 10000 lines.

**Acceptance checklist (manual, on Linux):**
- [ ] echo/ls render correct text and colors (16 / 256 / truecolor)
- [ ] vim opens, renders, and edits correctly
- [ ] htop renders (box-drawing, live refresh, colors)
- [ ] window resize reflows content
- [ ] Ctrl-C / Ctrl-D / Ctrl-Z, arrow keys (application-cursor mode), backspace correct
- [ ] shell exit is handled (shows "process exited", restartable)

## 6. Error handling
- **Shell exit:** event stream closes → "process exited" state, restartable.
- **FFI panic:** Rust returns `Result`; `catch_unwind` at the boundary → error event, app survives.
- **Disposed handle:** calls after `engine_dispose` are guarded/no-op.
- **PTY spawn failure:** surfaced in the UI.
- **Output flood / backpressure:** per-frame coalescing + a max-bytes-per-advance cap so
  heavy output (`cat bigfile`) stays responsive.

## 7. Testing
- **Rust unit:** feed known escape sequences → assert grid state (lean on Alacritty's
  existing test corpus); cover our wrapper API (advance/damage/resize/mode_flags).
- **Rust snapshot:** feed a representative sequence, snapshot the grid.
- **Dart unit:** `MirrorBuffer` damage-application; `InputEncoder` (key + mode → bytes).
- **Dart integration:** `FakePtyBackend` replays recorded shell output; widget test pumps
  frames and asserts rendered content.
- **Manual:** the §5 acceptance checklist on Linux.

## 8. Proposed repo layout
```
flutter_alacritty/
  rust/                       # cargo crate + flutter_rust_bridge
    src/lib.rs                # FRB api: engine_* + types
    src/engine.rs             # TerminalEngine (Term + Processor, Mutex)
    src/event_proxy.rs        # EventProxy: EventListener -> StreamSink
  lib/
    engine/                   # terminal_engine_client.dart, mirror_buffer.dart, frb bindings
    pty/                      # pty_backend.dart, flutter_pty_backend.dart
    render/                   # terminal_renderer.dart, xterm_renderer.dart
    input/                    # input_encoder.dart
    ui/                       # terminal_screen.dart
    main.dart
  docs/superpowers/specs/     # this doc
```

## 9. Roadmap (post-v1)
copy/paste polish → themes + config file → scrollback search → tabs/splits →
custom `CustomPainter` renderer → vi mode → SSH `DataSource` (iOS) → WASM core (web) →
ligatures.

## 10. Risks & open questions
- **xterm.dart render coupling** (likely the main pain): its render path assumes it owns
  the parser/buffer; feeding an external grid may fight it. *Mitigated:* it's the user's
  fork (patchable) + `TerminalRenderer` seam + Step-0 spike; fallback is the custom renderer.
- **FFI throughput on heavy output.** *Mitigated:* damage-only transfer + per-frame batching.
- **Wide-char/emoji width consistency** between Rust unicode-width and xterm.dart rendering.
- **Scrollback semantics** mapping Rust grid history → MirrorBuffer + scroll offset.

**Open questions for planning:** exact `mode_flags` subset needed for v1 input encoding;
whether `take_damage` returns viewport-relative or absolute line indices; how scrollback
is represented in `MirrorBuffer`.
