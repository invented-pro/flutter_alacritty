# Terminal Resize Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate resize corruption (duplicate lines, missing text, jank) by making Engine + PTY resize atomic, adopting `TerminalResizeController` as the only path, and removing the legacy throttle/`onViewportResize` API.

**Architecture:** `TerminalEngineClient` becomes the single authority for resize commits: Rust `engine_resize` + `fullSnapshot` complete first; only then does `onPtyResize` fire (never while `_advancing`). `TerminalView` always owns an internal `TerminalResizeController` and exposes one host hook: `onPtyResize`. The controller gates *when* to resize (orca-style stability policy); the client gates *how* resize is applied (engine before PTY). No backward compatibility.

**Tech Stack:** Dart/Flutter, `flutter_alacritty` engine layer (`TerminalEngine`, `TerminalEngineClient`, `MirrorGrid`), existing `StableFrameCommitPolicy`, `flutter test`.

**Root cause addressed (evidence):** During `_drain`, `resize()` defers `_flushPendingResize` while legacy `TerminalView` called `onViewportResize` synchronously → PTY SIGWINCH ahead of Engine → shell redraw parsed at stale column width.

---

## File map

| File | Responsibility after change |
|------|----------------------------|
| `lib/engine/terminal_engine_client.dart` | Atomic resize: `onPtyResize` only inside `_flushPendingResize` |
| `lib/engine/terminal_engine.dart` | Public `onPtyResize` setter wired to client |
| `lib/ui/terminal_resize_controller.dart` | Commit timing only; calls `engine.resize`; orca same-size skip |
| `lib/ui/terminal_view.dart` | Owns controller; `onPtyResize` host hook; delete legacy path |
| `lib/ui/terminal_view_pointer.dart` | Delete `_syncViewportToHost` / throttle helpers |
| `lib/render/mirror_grid.dart` | Partial line apply clears trailing columns |
| `lib/example/example_app.dart` | Lazy PTY spawn on first `onPtyResize`; single measurement source |
| `test/engine_client_resize_test.dart` | **Create:** drain-during-resize regression |
| `test/terminal_resize_controller_test.dart` | Remove `controller.onPtyResize`; use `engine.onPtyResize` |
| `test/mirror_grid_test.dart` | Partial narrow-line tail regression |
| `docs/library-api.md` | Update quick start + resize section |

---

### Task 1: Atomic resize in `TerminalEngineClient`

**Files:**
- Create: `test/engine_client_resize_test.dart`
- Modify: `lib/engine/terminal_engine_client.dart`

- [ ] **Step 1: Write the failing test**

Create `test/engine_client_resize_test.dart`:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/src/rust/engine.dart';

class _SlowBinding implements EngineBinding {
  final release = Completer<void>();
  int resizeCalls = 0;
  int lastCols = 0;
  int lastRows = 0;

  GridUpdate _empty({bool full = false}) => GridUpdate(
        full: full,
        rows: lastRows,
        columns: lastCols,
        lines: const [],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
      );

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async {
    await release.future;
    return _empty();
  }

  @override
  void resize(int columns, int rows) {
    resizeCalls++;
    lastCols = columns;
    lastRows = rows;
  }

  @override
  GridUpdate fullSnapshot() => _empty(full: true);

  @override
  Future<void> advance(Uint8List b) async {}
  @override
  Future<GridUpdate> takeDamage() async => _empty();
  @override
  void pumpEvents() {}
  @override
  bool searchIsActive() => false;
  @override
  Future<GridUpdate> scrollLines(int d) async => _empty();
  @override
  Future<GridUpdate> scrollPixels(double d) async => _empty();
  @override
  Future<GridUpdate> scrollToBottom() async => _empty();
  @override
  void clearHistory() {}
  @override
  void reconfigure(EngineConfig c) {}
  @override
  void respondClipboardLoad(String t) {}
  @override
  void setCellPixels(int w, int h) {}
  @override
  void selectionStart(int r, int c, bool rh, int k) {}
  @override
  void selectionUpdate(int r, int c, bool rh) {}
  @override
  void selectionClear() {}
  @override
  String? selectionText() => null;
  @override
  bool searchSet(String p) => false;
  @override
  bool searchNext() => false;
  @override
  bool searchPrev() => false;
  @override
  void searchClear() {}
  @override
  GridUpdate fullSnapshotSearched() => _empty(full: true);
  @override
  String? resolveHyperlink(int id) => null;
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resize during in-flight drain defers engine and pty until drain ends',
      () async {
    final binding = _SlowBinding();
    final grid = MirrorGrid()..initializeEmpty(24, 80);
    late void Function() drain;
    var ptyResizeCount = 0;

    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => drain = cb,
    );
    client.onPtyResize = (_, __) => ptyResizeCount++;

    client.feed(Uint8List.fromList([1]));
    drain();

    client.resize(120, 40);

    expect(binding.resizeCalls, 0);
    expect(ptyResizeCount, 0);
    expect(grid.columns, 80);

    binding.release.complete();
    await Future<void>.delayed(Duration.zero);

    expect(binding.resizeCalls, 1);
    expect(binding.lastCols, 120);
    expect(ptyResizeCount, 1);
    expect(grid.columns, 120);
  });

  test('pty resize never fires without engine flush on immediate resize', () {
    final binding = _SlowBinding();
    final grid = MirrorGrid()..initializeEmpty(24, 80);
    var ptyResizeCount = 0;

    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => cb(),
    );
    client.onPtyResize = (_, __) => ptyResizeCount++;

    client.resize(100, 30);

    expect(binding.resizeCalls, 1);
    expect(ptyResizeCount, 1);
    expect(grid.columns, 100);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/hhoa/git/hhoa/flutter_alacritty && flutter test test/engine_client_resize_test.dart`

Expected: FAIL — `onPtyResize` getter undefined and/or `ptyResizeCount` is 1 while drain in flight (legacy behavior if test called external callback).

- [ ] **Step 3: Implement atomic resize on client**

Modify `lib/engine/terminal_engine_client.dart`:

1. Add field and callback:

```dart
  /// Fired only from [_flushPendingResize], after the engine reflow and mirror
  /// snapshot complete. Host wires this to `PtyBackend.resize`.
  void Function(int columns, int rows)? onPtyResize;
```

2. In `_flushPendingResize`, after `refreshView()`:

```dart
    onPtyResize?.call(columns, rows);
```

3. Do **not** add any PTY callback anywhere else in this file.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/engine_client_resize_test.dart`

Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add test/engine_client_resize_test.dart lib/engine/terminal_engine_client.dart
git commit -m "fix(engine): fire onPtyResize only after engine resize flush"
```

---

### Task 2: Expose `onPtyResize` on `TerminalEngine`

**Files:**
- Modify: `lib/engine/terminal_engine.dart`
- Test: `test/terminal_engine_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/terminal_engine_test.dart` (new group at file end):

```dart
  test('onPtyResize forwards to client after resize flush', () {
    final binding = FakeBinding();
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => cb(),
    );
    var ptyCalls = 0;
    engine.onPtyResize = (_, __) => ptyCalls++;

    engine.resize(columns: 80, rows: 24);

    expect(binding.resizeCalls, greaterThan(0));
    expect(ptyCalls, 1);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/terminal_engine_test.dart --name "onPtyResize forwards"`

Expected: FAIL — `onPtyResize` not defined on `TerminalEngine`

- [ ] **Step 3: Implement forwarding**

In `lib/engine/terminal_engine.dart`:

```dart
  void Function(int columns, int rows)? _onPtyResize;

  /// Host transport hook. Invoked only after the native engine and mirror grid
  /// have adopted [columns]×[rows]. Wire to `PtyBackend.resize(rows, columns)`.
  void Function(int columns, int rows)? get onPtyResize => _onPtyResize;
  set onPtyResize(void Function(int columns, int rows)? cb) {
    _onPtyResize = cb;
    _client?.onPtyResize = cb;
  }
```

In `_bindEager`, after creating `_client`:

```dart
    _client!.onPtyResize = _onPtyResize;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/terminal_engine_test.dart --name "onPtyResize forwards"`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engine/terminal_engine.dart test/terminal_engine_test.dart
git commit -m "feat(engine): expose onPtyResize wired through client flush"
```

---

### Task 3: Simplify `TerminalResizeController` (timing only)

**Files:**
- Modify: `lib/ui/terminal_resize_controller.dart`
- Modify: `test/terminal_resize_controller_test.dart`

- [ ] **Step 1: Update controller tests first (they will fail until controller changes)**

In `test/terminal_resize_controller_test.dart`:

- Remove `ptyCommits` list and `controller.onPtyResize = ...` from both `setUp` blocks.
- Add `late List<({int cols, int rows})> ptyCommits` and in `setUp`:

```dart
      ptyCommits = [];
      engine.onPtyResize = (cols, rows) {
        ptyCommits.add((cols: cols, rows: rows));
      };
```

- Add test in `StableFrameCommitPolicy` group:

```dart
    test('skips commit when proposal matches committed grid (orca parity)', () {
      for (var i = 0; i < 2; i++) {
        controller.propose(query(100, 30));
        frameScheduler.flushOne();
      }
      expect(ptyCommits.length, 1);

      controller.propose(query(100, 30));
      frameScheduler.flushOne();
      expect(ptyCommits.length, 1);
    });
```

- [ ] **Step 2: Run tests to verify failure**

Run: `flutter test test/terminal_resize_controller_test.dart`

Expected: FAIL on new skip test (second commit fires) and/or `engine.onPtyResize` wiring

- [ ] **Step 3: Implement controller changes**

In `lib/ui/terminal_resize_controller.dart`:

1. Delete field `onPtyResize` and `onPtyResize = null` in `dispose`.
2. Replace `_commitPty`:

```dart
  void _commitPty(int cols, int rows) {
    if (_committedPty != null &&
        _committedPty!.cols == cols &&
        _committedPty!.rows == rows) {
      return;
    }
    _committedPty = TerminalGrid(cols, rows);
    _engine.resize(columns: cols, rows: rows);
  }
```

3. Replace first-init block in `propose`:

```dart
    if (!_initialized && proposed != null) {
      _initialized = true;
      _commitPty(proposed.cols, proposed.rows);
      _engine.initializeEmpty(proposed.rows, proposed.cols);
    }
```

4. Update class doc: remove references to controller `onPtyResize`; document that host sets `engine.onPtyResize`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/terminal_resize_controller_test.dart`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/terminal_resize_controller.dart test/terminal_resize_controller_test.dart
git commit -m "refactor(ui): resize controller commits via engine.onPtyResize only"
```

---

### Task 4: Fix partial line tail in `MirrorGrid`

**Files:**
- Modify: `test/mirror_grid_test.dart`
- Modify: `lib/render/mirror_grid.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/mirror_grid_test.dart`:

```dart
  test('partial line narrower than grid clears trailing columns', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true,
      rows: 1,
      columns: 10,
      lines: [row(0, '0123456789')],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
    ));
    g.apply(GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      lines: [row(0, 'ABC')],
      cursorRow: 0,
      cursorCol: 3,
      cursorVisible: true,
    ));
    expect(g.codepointAt(0, 2), 'C'.codeUnitAt(0));
    expect(g.codepointAt(0, 3), 32);
    expect(g.codepointAt(0, 9), 32);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/mirror_grid_test.dart --name "partial line narrower"`

Expected: FAIL — col 3 is `'3'`, not space

- [ ] **Step 3: Implement tail clear**

In `lib/render/mirror_grid.dart`, inside the `for (final l in u.lines)` loop, after computing `copy`:

```dart
      if (copy < _columns) {
        _codepoints[l.line].fillRange(copy, _columns, 32);
        _fg[l.line].fillRange(copy, _columns, _defaultFg);
        _bg[l.line].fillRange(copy, _columns, _defaultBg);
        _flags[l.line].fillRange(copy, _columns, 0);
        _hyperlinkId[l.line].fillRange(copy, _columns, 0);
      }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/mirror_grid_test.dart --name "partial line narrower"`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add test/mirror_grid_test.dart lib/render/mirror_grid.dart
git commit -m "fix(render): clear mirror row tail on partial narrow updates"
```

---

### Task 5: `TerminalView` — internal controller, delete legacy resize

**Files:**
- Modify: `lib/ui/terminal_view.dart`
- Modify: `lib/ui/terminal_view_pointer.dart`

- [ ] **Step 1: Write failing widget test**

Add to `test/terminal_view_callback_test.dart` (or new `test/terminal_view_resize_test.dart`):

```dart
  testWidgets('invokes onPtyResize after engine resize, not before drain',
      (tester) async {
    final binding = FakeBinding();
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
    );
    final ptySizes = <(int, int)>[];

    await tester.pumpWidget(MaterialApp(
      home: TerminalView(
        engine,
        onPtyResize: (c, r) => ptySizes.add((c, r)),
        engineFactory: ({required columns, required rows, ...}) => binding,
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(ptySizes, isNotEmpty);
    expect(binding.resizeCalls, greaterThan(0));
  });
```

Adjust imports/`engineFactory` — if `TerminalView` no longer takes `engineFactory`, wire `engine.onPtyResize` only and use pre-built engine as above.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/terminal_view_resize_test.dart` (or named test)

Expected: FAIL — `onPtyResize` not on `TerminalView` / legacy path still used

- [ ] **Step 3: Implement `TerminalView` changes**

In `lib/ui/terminal_view.dart`:

1. **Remove** constructor params: `onViewportResize`, `resizeController`.
2. **Add** `final void Function(int columns, int rows)? onPtyResize;`
3. In `TerminalViewState`, add:

```dart
  late final TerminalResizeController _resizeController;
```

4. In `initState`:

```dart
    _resizeController = TerminalResizeController(engine: widget.engine);
    _syncPtyResizeHook();
```

5. Add helpers:

```dart
  void _syncPtyResizeHook() {
    widget.engine.onPtyResize = widget.onPtyResize;
  }

  @visibleForTesting
  TerminalResizeController get resizeControllerForTest => _resizeController;
```

6. In `didUpdateWidget`:
   - On `onPtyResize` change or engine swap: `_syncPtyResizeHook()`.
   - On engine swap: dispose old controller, create new one, `commitNow()`.
   - Remove `_syncViewportToHost` branch.

7. In `dispose`: `_resizeController.dispose();`

8. Remove fields: `_resizeThrottle`, `_pendingResizeCols`, `_pendingResizeRows`, `_resizeWindow`, `_cols`, `_rows`.

9. In `build` `LayoutBuilder`, replace if/else with:

```dart
        final query = ViewportQuery(
          available: Size(availW, availH),
          cell: _metrics,
        );
        _resizeController.propose(query);
```

10. `_commitAfterMetricsChange`:

```dart
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resizeController.commitNow();
    });
```

In `lib/ui/terminal_view_pointer.dart`:

- Delete `_syncViewportToHost`, `_applyViewportResize`, `__pointerEnsureSizing` entirely.
- Remove references to `_cols`, `_rows`, `_resizeThrottle` in comments.

- [ ] **Step 4: Run widget test + existing suite**

Run: `flutter test test/terminal_view_resize_test.dart test/terminal_view_callback_test.dart`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/terminal_view.dart lib/ui/terminal_view_pointer.dart test/terminal_view_resize_test.dart
git commit -m "refactor(ui): TerminalView owns resize controller; drop legacy path"
```

---

### Task 6: Refactor `ExampleTerminalApp` (single measurement source)

**Files:**
- Modify: `lib/example/example_app.dart`

- [ ] **Step 1: No new test required** (covered by `terminal_lifecycle_test.dart`); run lifecycle tests after edit to catch regressions.

- [ ] **Step 2: Implement example changes**

1. Remove outer `LayoutBuilder` cols/rows calculation and `_ensureStarted` post-frame callback.
2. Replace `_onViewportResize` with:

```dart
  void _onPtyResize(int cols, int rows) {
    if (_status != TermStatus.running) return;
    _cols = cols;
    _rows = rows;
    if (_pty == null) {
      _startSession(cols, rows);
      return;
    }
    _pty!.resize(rows, cols);
  }
```

3. Split `_start` into:
   - `_ensureEngine()` — creates `TerminalEngine` + subscriptions once (no PTY, no `engine.resize`).
   - `_startSession(int cols, int rows)` — creates PTY at `(cols, rows)`, wires streams.

4. In `initState` or first `build`: call `_ensureEngine()` when `_status == running`.

5. `TerminalView` wiring:

```dart
  onPtyResize: _onPtyResize,
```

Remove `onViewportResize`.

6. `_restart()`: call `_startSession(_cols, _rows)` only if `_cols > 0`; else rely on view `commitNow` after rebuild.

7. Remove duplicate `engine.resize` / `initializeEmpty` from session start — first `propose()` + `_commitPty` handles it.

- [ ] **Step 3: Run example-related tests**

Run: `flutter test test/terminal_lifecycle_test.dart`

Expected: PASS (may need to update zoom test timing — still `pump(150ms)` after `commitNow` on zoom)

- [ ] **Step 4: Commit**

```bash
git add lib/example/example_app.dart
git commit -m "refactor(example): lazy PTY spawn via TerminalView onPtyResize"
```

---

### Task 7: Update remaining tests and API docs

**Files:**
- Modify: `test/engine_client_test.dart` (no behavior change expected)
- Modify: `test/terminal_lifecycle_test.dart` (if `onViewportResize` referenced)
- Modify: `docs/library-api.md`

- [ ] **Step 1: Grep for removed symbols**

Run: `rg "onViewportResize|resizeController" /home/hhoa/git/hhoa/flutter_alacritty --glob '*.dart'`

Fix every hit.

- [ ] **Step 2: Update `docs/library-api.md`**

Replace quick-start PTY wiring:

```dart
late final _engine = TerminalEngine(config: _config);
late final PtyBackend? _pty; // created on first onPtyResize

// In build:
TerminalView(
  _engine,
  controller: _controller,
  onPtyResize: (cols, rows) {
    _pty ??= FlutterPtyBackend(rows: rows, columns: cols);
    _pty!.resize(rows, cols);
  },
)
```

Update `TerminalEngine` table row for `resize`:

> Cell-grid resize. Does **not** resize the PTY — set `engine.onPtyResize` or use `TerminalView(onPtyResize: ...)`.

Document breaking change: `onViewportResize` and `resizeController` removed.

- [ ] **Step 3: Run full test suite**

Run: `cd /home/hhoa/git/hhoa/flutter_alacritty && flutter test`

Expected: all green

- [ ] **Step 4: Run analyzer**

Run: `flutter analyze lib test`

Expected: no issues

- [ ] **Step 5: Commit**

```bash
git add docs/library-api.md test/
git commit -m "docs: resize API breaking change; fix test references"
```

---

### Task 8: Optional hardening — drain-start resize flush

**Files:**
- Modify: `lib/engine/terminal_engine_client.dart`
- Modify: `test/engine_client_resize_test.dart`

Only do this if Task 1 tests pass but manual resize-during-heavy-output still glitches.

- [ ] **Step 1: Add test** — resize queued, then new `feed` in same frame after prior drain ended; verify order.

- [ ] **Step 2: At top of `_drain` try block**, before `_applyPendingScroll`:

```dart
      if (_pendingColumns != null || _pendingRows != null) {
        _flushPendingResize();
      }
```

This is idempotent when pending was already flushed.

- [ ] **Step 3: Run full suite and commit if added**

```bash
git commit -m "fix(engine): flush pending resize before ingesting PTY batch"
```

---

## Self-review

| Spec requirement | Task |
|------------------|------|
| Engine before PTY (atomic commit) | Task 1, 2 |
| Remove legacy throttle path | Task 5 |
| `TerminalResizeController` production default | Task 5 |
| Orca same-size skip | Task 3 |
| Mirror partial tail fix | Task 4 |
| Example single measurement source | Task 6 |
| Regression test drain+resize | Task 1 |
| API docs | Task 7 |

No placeholders remain. Type names consistent: `onPtyResize(int columns, int rows)` throughout.

---

## Verification checklist (manual, after all tasks)

1. `flutter run` example app — resize window continuously while `yes` running: no duplicate lines.
2. Toggle sidebar / maximize — grid settles within ~150ms, no permanent blank columns.
3. Ctrl+= / Ctrl+0 zoom — PTY and grid match after one frame + settle.
4. Restart after exit — PTY respawns at view-measured size.

---

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-23-resize-architecture.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
