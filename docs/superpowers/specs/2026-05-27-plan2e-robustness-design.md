# flutter_alacritty Plan 2E — Robustness & Lifecycle

**Date:** 2026-05-27
**Status:** Design approved, pending spec review
**Branch:** `feature/e-robustness` (off `main` with A + C + B + D merged @ ac97b5d)

The final v1 sub-project: handle shell exit and spawn failure gracefully, keep the
existing FFI-panic guard, and make the lifecycle testable. **One spec, not staged**
(it's a focused robustness bucket, ~4 tasks).

---

## 1. Goal & Non-Goals

**Goal.** When the shell process exits (or fails to start), the terminal shows a clear
overlay and restarts on a keypress/click instead of silently freezing or crashing.

**In scope:**
- Detect shell exit (PTY `exitCode`) → "process exited" overlay → restart on input.
- Catch PTY **spawn failure** → error overlay (same mechanism).
- Restart tears down the old PTY/engine/client and spawns fresh.
- Injectable PTY + engine factories so exit/restart is widget-testable without the native lib.
- Resize while not running is a no-op.

**Non-goals:**
- App background/suspend lifecycle (desktop N/A; revisit for mobile/touch project).
- Multi-session / tabs, a configurable `hold`/exit policy (later).
- Surfacing FFI parser panics in the UI — the existing `catch_unwind` already keeps the app
  alive and logs; no overlay for it.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Exit detection | `PtyBackend` exposes `Future<int> get exitCode` (flutter_pty's `Pty.exitCode`); the screen also treats `output.onDone` as a fallback signal |
| UX | A status machine (`running`/`exited`/`error`) drives a `Stack` overlay over the `CustomPaint`; any key/click while not `running` triggers restart |
| Spawn failure | The PTY/engine factory call is wrapped in try/catch in `_start` → `error` status with the message |
| Testability | `TerminalScreen` takes optional `ptyFactory` + `engineFactory` (default the real ones) so a widget test can inject fakes and drive exit → overlay → restart |
| Staging | Single spec, not staged |

## 3. Components & data flow

**`PtyBackend` / `FlutterPtyBackend`:**
```dart
abstract class PtyBackend {
  // … existing output/write/resize/kill …
  Future<int> get exitCode;
}
// FlutterPtyBackend: Future<int> get exitCode => _pty.exitCode;
```

**`TerminalScreen`:**
- `enum TermStatus { running, exited, error }`; fields `_status`, `int? _exitCode`, `String? _errorMessage`.
- Optional injected factories (default to real impls):
  ```dart
  final PtyBackend Function({required int rows, required int columns})? ptyFactory;
  final EngineBinding Function({
    required int columns, required int rows,
    required void Function(Uint8List) onPtyWrite,
    required void Function(String) onTitle,
    required void Function() onBell,
    required void Function(String) onClipboard,
  })? engineFactory;
  ```
- `_start(cols, rows)` (extracted from the first-run path of `_ensureStarted`):
  ```
  try {
    pty = (ptyFactory ?? FlutterPtyBackend.new)(rows, columns);
    binding = (engineFactory ?? FrbEngineBinding.new)(...callbacks...);
    client = TerminalEngineClient(binding, grid);
    grid.initializeEmpty(rows, cols);
    outputSub = pty.output.listen(client.feed, onDone: () => _exitIfCurrent(pty, null));
    pty.exitCode.then((code) => _exitIfCurrent(pty, code));
    _status = running;
  } catch (e) {
    _status = error; _errorMessage = '$e';
  }
  setState(())  // reflect status in the overlay
  ```
- `_exitIfCurrent(PtyBackend p, int? code)`: **`if (!identical(_pty, p)) return;`** (the old
  session's `exitCode`/`onDone` must not flip a fresh one after restart), then
  `if (_status != running) return;` (dedupe `exitCode` vs `onDone` within a session); finally
  set `_status = exited`, `_exitCode = code`, `setState`. (Does **not** auto-restart.)
- `_restart()`: `_outputSub.cancel(); _pty.kill(); _client.dispose();` then `_start(_cols, _rows)`.
- Input gates: in `_onKey` and `onPointerDown`, if `_status != running` → `_restart()` and
  return (swallow the input that triggered restart). Resize branch: if `_status != running`,
  skip engine/pty resize.

**Overlay (build):** wrap the `CustomPaint` in a `Stack`; when `_status != running`, add a
centered translucent banner:
- `exited`: `process exited${code != null ? ' ($code)' : ''} — press any key to restart`
- `error`: `failed to start: $_errorMessage — press any key to retry`
The banner uses `GestureDetector`/the existing `Listener` so a tap also restarts.

## 4. Error handling

- **Double exit signal:** `exitCode` future and `output.onDone` can both fire; `_onExit`
  dedupes via the `_status != running` guard.
- **Restart safety:** teardown cancels the old subscription before killing, so no late
  `feed`/`exitCode` callback flips a freshly-started session (the new `pty.exitCode` is a new
  future; the old one's `.then` still fires but `_onExit` ignores it since status is `running`
  only for the new session — guard also checks identity is unnecessary because teardown
  precedes the new `_start` and the stale future resolves to the old code; the `running`
  guard plus the fact that we only enter `exited` once per session covers it).
- **Spawn failure:** caught in `_start`; if `FlutterPtyBackend` throws synchronously
  (`Pty.start`) or the child exits instantly, either the catch or `_onExit` shows an overlay.
- **FFI panic:** unchanged — `catch_unwind` in `engine_advance`/`take_damage` logs and returns
  safely; no crash, no overlay.

## 5. Testing & acceptance

**Widget (with injected fakes — no native lib):**
- Inject a fake `PtyBackend` (controllable `exitCode` `Completer`) + the existing fake
  `EngineBinding`. Pump `TerminalScreen`: complete `exitCode(0)` → the "process exited (0)"
  overlay appears; send a key → a new PTY is created (restart) and the overlay clears.
- Inject a `ptyFactory` that throws → the "failed to start" overlay appears.

**Manual (Linux):**
- [ ] Type `exit` (or Ctrl-D) → overlay "process exited (0) — press any key to restart";
      press a key → a fresh shell prompt returns.
- [ ] Run a command that exits non-zero then `exit 3` → overlay shows `(3)`.
- [ ] Point the shell env at a missing binary (or inject a bad shell) → "failed to start" overlay.
- [ ] After restart, scrollback/selection/input all work (no stale state from the dead session).

## 6. Risks & open questions

- **flutter_pty `exitCode`:** assumed `Future<int> get exitCode`; if the API differs, fall
  back to `output.onDone` (no code shown). Confirm during implementation.
- **Factory injection surface:** the `engineFactory` signature is wide (callbacks); keep it to
  exactly what `_start` needs. Defaults preserve current behavior.
- **Grid reuse on restart:** the existing `MirrorGrid` is reused and `initializeEmpty`-d; verify
  no leftover selection/scroll/mode state leaks across a restart (clear via fresh engine + grid reinit).
- **Open:** a configurable exit policy (`hold` / close-on-exit) is deferred; the overlay+restart
  default is fixed for now.
