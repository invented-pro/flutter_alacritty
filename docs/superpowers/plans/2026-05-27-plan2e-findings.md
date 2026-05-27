# Plan 2E — Acceptance Findings

**Date:** 2026-05-27  
**Branch:** `feature/e-robustness`  
**Worktree:** `.worktrees/plan2e-robustness`  
**Commits:** `443af00` (E.1), `6c7c41e` + `e654eef` (E.2), overlay polish + this doc (E.3)

## flutter_pty `exitCode` API

Confirmed in `package:flutter_pty` (`lib/flutter_pty.dart`):

```dart
Future<int> get exitCode => _exitCodeCompleter.future;
```

`FlutterPtyBackend` forwards with `Future<int> get exitCode => _pty.exitCode;` — no adapter needed.

## Automated verification

| Check | Result |
|-------|--------|
| `flutter analyze lib test` | Pass — no issues |
| `flutter test` | Pass — 59 tests (incl. 2 lifecycle widget tests) |
| `cargo build` (rust/) | Pass |
| Widget: `exitCode(0)` → overlay → tap restart → 2nd PTY | Pass |
| Widget: throwing `ptyFactory` → `failed to start` overlay | Pass |

## Manual acceptance (Linux desktop)

Run: `flutter run -d linux` from the worktree (or merged branch).

| Checklist item | Status | Notes |
|----------------|--------|-------|
| `exit` / Ctrl-D → `process exited (0) — press any key to restart`; key → fresh prompt | **Pending** | Requires interactive GUI session |
| `exit 3` → overlay shows `(3)` | **Pending** | |
| `SHELL=/nonexistent flutter run -d linux` → `failed to start: …`; key → retry | **Pending** | Widget test covers throw path; env path equivalent |
| After restart: typing / scrollback / selection work | **Pending** | No stale-session issues observed in widget restart test |

> Manual rows were not executed in the agent environment (no display session). Re-run locally and tick boxes when verified.

## Implementation notes / edge cases

1. **`_exitIfCurrent` dedupe:** `identical(_pty, p)` plus `_status != running` prevents double-handling of `exitCode` and `output.onDone` in the same session; stale futures from a prior session are ignored after restart replaces `_pty`.

2. **Spawn-failure loop:** `_ensureStarted` skips `_start` while `_status == error` and `_client == null` so layout frames do not respawn; user retry uses `_restart()` → `_start`.

3. **Overlay:** `IgnorePointer` on the banner so pointer events reach the `Listener` for restart; `Stack` keeps the last grid painted under the banner.

4. **Rapid exit→restart:** Widget test completes exit + tap restart in one flow; no race observed. If manual testing shows flicker, consider debouncing `_restart`.

## Spec coverage

- E.1: `PtyBackend.exitCode` ✅  
- E.2: status machine, factories, overlay, gates, tests ✅  
- E.3: this document + build/test gate ✅ (manual GUI pending)
