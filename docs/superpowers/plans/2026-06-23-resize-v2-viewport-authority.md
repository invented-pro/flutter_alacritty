# Terminal Resize v2 — Viewport Authority Architecture

> **Status:** Proposal (greenfield; no backward compatibility)  
> **Supersedes:** Orca-style `StableFrameCommitPolicy` deferral; extends the atomic engine→PTY commit from `2026-06-23-resize-architecture.md`  
> **Goal:** Eliminate the “top line + huge blank + bottom UI” resize glitch by making **one object** the sole authority for pixel layout, cell grid, engine state, and PTY dimensions — matching Alacritty’s `SizeInfo` model, not Orca’s deferred fit observer.

---

## 1. Executive summary

The resize screenshot is not a painter bug alone. It is a **three-authority desync**:

| Authority | What it tracks | When it updates |
|-----------|----------------|-----------------|
| Flutter `LayoutBuilder` constraints | Parent pixel box | Every layout frame, immediately |
| `TerminalResizeController._current` | Proposed cols×rows | Every layout frame |
| `MirrorGrid` + committed PTY | Actual cols×rows | After 2-frame stability / 150 ms settle / drain ends |

Between authorities, `TerminalPainter` clears the **full parent pixel rect** but draws only **`grid.rows` lines** → a band of “fake empty terminal” that is really **uncommitted viewport slack**.

**v2 fix:** Port Alacritty’s `SizeInfo` into Dart as `TerminalViewport`. On every layout pass where cols/rows change, **synchronously** resize engine → mirror snapshot → SIGWINCH in the same call stack. Fractional leftover pixels become **dynamic padding** (letterboxing), not extra terminal rows. Delete `StableFrameCommitPolicy` entirely; cell-boundary quantization is the only throttle.

---

## 2. Deep root-cause analysis

### 2.1 What the screenshot actually is

Observed layout:

1. **Top:** stale line (pre-resize content)
2. **Middle:** default-bg void (no cells — either unpainted slack or empty reflowed rows)
3. **Bottom:** TUI chrome (diff block, `>` prompt)
4. **Below widget:** host chrome (`? for shortcuts`)

This is consistent with **at least one frame** where:

- Parent allocated **more pixels** than `committedRows × cellHeight`
- Engine/PTY/TUI still reflect an **older or partially reflowed** grid
- TUI (full-screen redraw apps) has not yet repainted the middle after `SIGWINCH`

### 2.2 Already fixed (v1 plan) — necessary but insufficient

`TerminalEngineClient._flushPendingResize` now does:

```
binding.resize → refreshView (full snapshot) → onPtyResize
```

PTY never leads engine. Good.

**Still broken:** `_commitPty` is gated by `StableFrameCommitPolicy` in a **post-frame callback**, so mirror can lag layout by 2 frames + 150 ms + an in-flight `_drain`.

### 2.3 Structural defects unique to Flutter embedding

| Defect | Location | Alacritty | gnome-terminal | Orca |
|--------|----------|-----------|----------------|------|
| Propose vs commit split | `terminal_resize_controller.dart` | None — `SizeInfo` updates in draw prep | GTK allocation → `vte_terminal_set_size` sync | Deferred fit (multi-pane / Win scrollbar wobble) |
| Painter clears parent, draws grid | `terminal_painter.dart:183–214` | GPU clear = window; quads only inside `SizeInfo` cell area | VTE surface = cell grid | xterm canvas sized to `terminal.rows` |
| `CustomPaint(size: infinite)` | `terminal_view.dart:922` | N/A | N/A | xterm container explicit |
| Resize deferred during drain | `terminal_engine_client.dart:140–148` | Resize in event loop before next PTY read | VTE internal | xterm + IPC (less FFI async) |
| No dynamic padding | `viewport_geometry.dart` | `SizeInfo::new` + `dynamic_padding` | VTE letterbox | fitAddon |

### 2.4 Why Orca’s policy is the wrong default here

`StableFrameCommitPolicy` was ported from `pane-fit-resize-observer.ts` to stop:

- Windows one-column scrollbar wobble
- Multi-pane `safeFit` cascade corrupting background-tab PTYs

flutter_alacritty is **single-pane embedded widget** with **synchronous Rust `engine_resize`**. The cost of deferral (visible void) exceeds the cost of extra `SIGWINCH` at **cell boundaries** — which Alacritty already does without a 150 ms timer.

Orca’s `pane-pty-resize-hold` (transaction bracket) remains useful for **host layout animations**; stability gating does not.

### 2.5 Alacritty’s correct invariant (target)

From `alacritty/src/display/mod.rs`:

```text
Window pixels
  → SizeInfo { width, height, cell_w, cell_h, padding_x/y, columns, screen_lines }
  → if columns/screen_lines changed:
        pty.on_resize(SizeInfo)      // SIGWINCH
        terminal.resize(SizeInfo)      // grid reflow
        damage_tracker.resize(...)
  → render only inside padded cell grid
```

**One struct, one commit, same tick.** No “proposed” vs “committed” grid.

---

## 3. Design goals (non-negotiable)

1. **Single source of truth:** `TerminalViewport` owns pixels + cells + padding + DPR.
2. **Synchronous commit:** Any change to `columns` or `screenLines` applies engine + mirror + PTY before `build` returns (or before paint phase — never post-frame settle).
3. **Cell-boundary throttle only:** `floor(available / cell)` — if cols/rows unchanged across frames, do nothing. No 2-frame / 150 ms gates.
4. **Letterbox, don’t lie:** Leftover pixels are padding around the cell grid, not phantom terminal rows.
5. **Resize preempts ingest:** Pending or in-flight PTY drain must not block resize; resize runs first, then bytes replay at new width.
6. **Paint clip = grid clip:** Painter never clears outside `columns × cellWidth` by `screenLines × cellHeight` (plus padding).
7. **Host transactions:** Sidebar/tab animations bracket PTY SIGWINCH, **not** engine grid (see §6.4).

---

## 4. Core model: `TerminalViewport`

Dart port of `SizeInfo<f32>` + `WindowSize`:

```dart
@immutable
final class TerminalViewport {
  const TerminalViewport({
    required this.windowWidth,
    required this.windowHeight,
    required this.cellWidth,
    required this.cellHeight,
    required this.paddingX,
    required this.paddingY,
    required this.columns,
    required this.screenLines,
    required this.devicePixelRatio,
  });

  final double windowWidth;   // LayoutBuilder constraints (after host padding)
  final double windowHeight;
  final double cellWidth;
  final double cellHeight;
  final double paddingX;      // dynamic remainder, both sides sum to 2*paddingX
  final double paddingY;
  final int columns;
  final int screenLines;
  final double devicePixelRatio;

  /// Pixel rect that actually contains cells — painter + hit-test bounds.
  Rect get cellRect => Rect.fromLTWH(
        paddingX,
        paddingY,
        columns * cellWidth,
        screenLines * cellHeight,
      );

  /// For ioctl: cols, rows, cell pixel dims (see alacritty ToWinsize).
  WindowSize get ptyWindowSize => WindowSize(
        numCols: columns,
        numLines: screenLines,
        cellWidth: cellWidth.round().clamp(1, 0xFFFF),
        cellHeight: cellHeight.round().clamp(1, 0xFFFF),
      );

  bool sameGrid(TerminalViewport other) =>
      columns == other.columns && screenLines == other.screenLines;

  bool sameCellMetrics(TerminalViewport other) =>
      cellWidth == other.cellWidth && cellHeight == other.cellHeight;
}
```

### 4.1 `ViewportResolver` (replaces `ViewportGeometryResolver`)

Pure function; **always** returns a `TerminalViewport`, never `null`.

```dart
TerminalViewport resolve(ViewportQuery query, {bool dynamicPadding = true}) {
  // 1. Usable floor: MIN_COLS/MIN_ROWS/MIN_PX (keep existing constants)
  // 2. If below floor → clamp to floor with centered padding (transition frame
  //    still produces ONE consistent grid; never “hold old PTY, grow widget”)
  // 3. columns  = floor((width  - 2*basePadX) / cellWidth)
  // 4. lines    = floor((height - 2*basePadY) / cellHeight)
  // 5. if dynamicPadding:
  //      paddingX = (width  - columns  * cellWidth)  / 2
  //      paddingY = (height - screenLines * cellHeight) / 2
  //    (Alacritty dynamic_padding formula)
}
```

**Delete** the `null` return path. Returning `null` preserved old grid while parent grew — direct cause of void band.

---

## 5. Resize pipeline (single path)

Replace `TerminalResizeController` + `ResizeCommitPolicy` with **`TerminalViewportController`**.

```text
LayoutBuilder
  └─ viewport = resolver.resolve(query)
  └─ controller.apply(viewport)   // SYNC
        ├─ if !viewport.sameGrid(committed):
        │     engine.resizeSync(cols, rows)   // NEW: see §7
        │     mirror ← fullSnapshot (inside resizeSync)
        │     if !ptyHold: onPtyResize(cols, rows)
        │     committed = viewport
        ├─ else if !viewport.sameCellMetrics(committed):
        │     engine.setCellPixels(...)       // winsize pixel fields only
        └─ notifyListeners() → markNeedsPaint
```

### 5.1 `apply` is synchronous

Called directly inside `LayoutBuilder.builder`. **No** `addPostFrameCallback` for grid commits.

Rationale: Flutter layout already runs before paint in the same frame. Alacritty resizes during `display.update` before `draw`. Matching that phase eliminates the void frame.

### 5.2 Cell metrics change (font zoom)

```dart
void onCellMetricsChanged(CellMetrics m) {
  final vp = resolver.resolve(lastQuery.copyWith(cell: m));
  apply(vp); // same sync path; cols/rows likely change → full resize
}
```

Delete `_commitAfterMetricsChange` post-frame `commitNow()`.

### 5.3 First boot

First `apply` with valid viewport:

1. `engine.resizeSync` (creates binding at correct size — no 80×24 bootstrap)
2. `onPtyResize` → host spawns PTY at exact size
3. No `TerminalGrid.sentinel` hack

---

## 6. PTY policy

### 6.1 When to SIGWINCH

Only when `columns` or `screenLines` changes. Dragging within the same cell grid → **zero** PTY traffic (natural throttle — better than 150 ms debounce).

### 6.2 Engine/PTY lock-step (keep v1)

Order preserved:

```text
engine_resize (sync FFI)
  → term.resize + TermDamage::Full
  → fullSnapshot → MirrorGrid
  → onPtyResize → PtyBackend.resize
```

### 6.3 `setCellPixels` without grid change

When only sub-pixel cell metrics drift (DPR / font layout) but floor(cols/rows) unchanged:

- Update `engine.setCellPixels(w, h)` for correct `scroll_pixels` / winsize pixel fields
- **Do not** call `term.resize` or SIGWINCH

### 6.4 Host layout transactions (Orca hold, simplified)

Keep bracket API for **PTY only**:

```dart
controller.beginPtyHold();  // queue SIGWINCH
// ... animate sidebar ...
controller.endPtyHold(flush: true);  // one SIGWINCH at final grid
```

**Critical difference from today:** `beginPtyHold` does **not** block `engine.resizeSync`. Mirror always matches visible viewport during animation; only the shell is spared SIGWINCH spam.

Optional: `reportGeometry(cols, rows)` to host for restore targets (Orca `pty:reportGeometry` pattern) — no resize side effect.

---

## 7. Engine layer changes

### 7.1 `resizeSync` replaces deferred client resize

```dart
// TerminalEngine
void resizeSync({required int columns, required int rows}) {
  _bindWithSize(columns: columns, rows: rows);
  if (columns == _lastColumns && rows == _lastRows) return;
  _lastColumns = columns;
  _lastRows = rows;
  _client!.resizeSync(columns, rows);  // never deferred
}
```

```dart
// TerminalEngineClient
void resizeSync(int columns, int rows) {
  if (_advancing) {
    // Preempt: finish or cancel current advance slice — see §7.2
    _preemptDrainForResize();
  }
  _binding.resize(columns, rows);
  refreshView();
  onPtyResize?.call(columns, rows);
}
```

**Delete:** `_pendingColumns`, `_pendingRows`, post-frame deferral in `resize()`.

### 7.2 Drain preemption

Today `_drain` holds `_advancing` across `await advanceAndTakeDamage`, blocking resize.

**v2 options (pick A — simplest correct):**

**A. Sync advance path for resize frames**

- Split `engine_advance_and_take_damage` into:
  - `engine_advance_sync(bytes)` — parse on UI thread, no await
  - OR keep async but **cancel** the in-flight future on resize; re-queue unconsumed bytes
- On resize: sync resize + snapshot, then re-drain buffer at new width

**B. Rust-side resize during advance (Alacritty-style)**

- `TerminalEngine` in Rust checks a `pending_resize` before processing each escape chunk
- Matches how `alacritty_terminal::event_loop` handles `Msg::Resize` between PTY reads

Recommendation: **B** long-term (one process, one loop); **A** acceptable first step with existing FRB.

### 7.3 Remove mirror/engine width race band-aid

`MirrorGrid.apply` partial-line fallback to full snapshot (`mirror_grid.dart:267–268`) becomes rare. Keep as assert-level safety, not primary path.

### 7.4 Rust: expose `reported_dimensions`

After `engine_resize`, expose `engine_columns` / `engine_rows` for tests and host assertions.

---

## 8. Rendering layer changes

### 8.1 Widget tree

```dart
LayoutBuilder(
  builder: (context, constraints) {
    final viewport = resolver.resolve(...);
    controller.apply(viewport);

    return Padding(
      padding: EdgeInsets.only(
        left: viewport.paddingX,
        top: viewport.paddingY,
        right: viewport.windowWidth - viewport.paddingX - viewport.columns * viewport.cellWidth,
        bottom: viewport.windowHeight - viewport.paddingY - viewport.screenLines * viewport.cellHeight,
      ),
      child: SizedBox(
        width: viewport.columns * viewport.cellWidth,
        height: viewport.screenLines * viewport.cellHeight,
        child: Stack(
          children: [
            CustomPaint(
              size: Size(viewport.columns * viewport.cellWidth,
                         viewport.screenLines * viewport.cellHeight),
              painter: TerminalPainter(...),
            ),
            // cursor, bell, preedit — same explicit size
          ],
        ),
      ),
    );
  },
)
```

**Delete:** `CustomPaint(size: Size.infinite)`.

### 8.2 Painter

- `paint()` clears only `size` (= cell grid), not parent constraints
- `_pushScrollShift` clip rect stays `rows * cellHeight` — equals `size.height` now
- Host background shows through **padding**, not through fake terminal void

### 8.3 Hit-testing / mouse / selection

All coordinate transforms add `(paddingX, paddingY)` offset; use `viewport.cellRect` for bounds checks.

### 8.4 Optional: window resize increments

For standalone `flutter run` window (not embedded):

- `Window.setResizeIncrement(Size(cellWidth, cellHeight))` on Linux/Win32 where supported
- Embedded hosts (Cursor, Orca pane) skip — parent controls pixel box

---

## 9. Delete list (breaking)

| Remove | Reason |
|--------|--------|
| `resize_commit_policy.dart` entirely | Replaced by cell-boundary idempotency |
| `StableFrameCommitPolicy`, `ImmediateCommitPolicy` | — |
| `TerminalResizeController` | → `TerminalViewportController` |
| `TerminalGrid.sentinel` | No propose/commit split |
| `_current` vs `_committedPty` dual state | Single `committed: TerminalViewport` |
| Post-frame resize callbacks in controller | Sync `apply` |
| `propose()` name | → `apply()` |
| `commitNow()` public API | Host calls `apply` with forced viewport or `flushPtyHold` |
| `ViewportGeometryResolver` null return | Always resolve with floor + padding |
| Tests for 150 ms settle / 2-frame stability | Replace with cell-boundary + sync commit tests |

---

## 10. Host / public API (v2)

```dart
TerminalView(
  engine,
  onPtyResize: (cols, rows) { ... },           // unchanged semantics
  onViewportChanged: (TerminalViewport vp) { }, // optional: scrollbar, pane chrome
  padding: ...,                                 // host chrome inset; resolver subtracts
)
```

`TerminalEngine`:

- `resizeSync({columns, rows})` — primary; document that `resize` alias is removed
- `onPtyResize` — still fired only after mirror snapshot
- `TerminalViewport? get viewport` — read-only committed viewport

No `onViewportResize`, no injectable `resizeController`, no policy injection.

---

## 11. Comparison after v2

| | Alacritty | gnome-terminal | Orca | flutter_alacritty v2 |
|--|-----------|----------------|------|----------------------|
| Authority | `SizeInfo` | VTE grid + allocation | xterm cols/rows + fitAddon | `TerminalViewport` |
| PTY throttle | Cell boundary | Cell boundary | 2-frame + 150 ms + hold | Cell boundary + optional hold |
| Pixel slack | `dynamic_padding` | VTE letterbox | CSS box | `paddingX/Y` |
| Engine/PTY order | PTY then term (same function) | VTE internal | xterm then IPC | engine→mirror→PTY sync |
| Resize vs output | Same event loop turn | Same allocation | Async IPC | **Preempt drain, sync resize** |
| Void band risk | None | None | Low | **None by construction** |

---

## 12. Test matrix

### Unit

| Test | Assert |
|------|--------|
| `viewport_resolver_dynamic_padding` | `2*paddingX + cols*cellW == windowWidth` |
| `viewport_resolver_floor` | Below-min constraint → floor grid + centered pad, not null |
| `viewport_controller_sync_commit` | `apply(vp)` → same stack: binding.resize, grid.cols, pty callback |
| `viewport_controller_same_grid_skip` | Two applies, same cols/rows → one PTY call |
| `viewport_controller_cell_boundary_drag` | 50 pixel steps within one column → 0 PTY calls |
| `resize_preempts_drain` | feed + slow advance + resizeSync → resize before next applyUpdate |
| `pty_hold` | hold bracket → engine resizes N times, PTY once |
| `metrics_change_recompute` | font zoom changes cols → one resizeSync |

### Widget

| Test | Assert |
|------|--------|
| `terminal_view_no_void_paint` | Resize harness: CustomPaint.height == grid.rows * cellHeight |
| `terminal_view_resize_while_yes` | No duplicate lines; no permanent blank band |
| `scrollbar_geometry` | Uses `viewport.cellRect` + `displayOffset` |

### Rust

| Test | Assert |
|------|--------|
| `resize_during_advance` | Bytes before resize parsed at old width; after at new |
| `resize_forces_full_damage` | existing — keep |

---

## 13. Implementation phases

### Phase 1 — Viewport model + resolver

- Add `terminal_viewport.dart`, `viewport_resolver.dart`
- Tests for padding math and floors

### Phase 2 — `TerminalViewportController` + sync `apply`

- Wire into `TerminalView` `LayoutBuilder`
- Delete `resize_commit_policy.dart`, old controller

### Phase 3 — Engine `resizeSync` + drain preemption

- Rust/Dart preempt path
- Remove pending resize fields

### Phase 4 — Render clip + input coordinate fix

- Explicit `SizedBox` + padding wrapper
- Update pointer/selection/IME paths

### Phase 5 — Host transaction + docs

- `beginPtyHold` / `endPtyHold`
- Rewrite `library-api.md`
- Delete obsolete tests

---

## 14. Manual verification

1. **Continuous resize** with `yes` running — no duplicate lines, no void band.
2. **Maximize / restore** — single SIGWINCH at new grid; full TUI redraw within one frame.
3. **Sidebar animate** (Orca embed) — mirror tracks live; PTY fires once at end if hold used.
4. **Font zoom** — grid + PTY match after one layout.
5. **Heavy output + resize** — no narrow-line tail corruption; no stuck deferral.
6. **Fractional DPR** — padding absorbs remainder; no cell seam in void area.

---

## 15. Why this is optimal (not incremental)

Incremental fixes (clip painter only, shorten 150 ms to 50 ms, paint placeholder rows) preserve **three authorities** and fight symptoms.

**Viewport authority** collapses the model to Alacritty’s proven invariant:

```text
pixels → SizeInfo → {term, pty, damage, render} — same tuple, same time
```

Orca’s deferred fit solves **multi-pane desktop compositor** problems flutter_alacritty does not have in the same form. Adopting Alacritty’s geometry model and gnome-terminal’s synchronous allocation semantics fits a single embedded `TerminalView` widget correctly.

No backward compatibility burden: delete the policy layer, rename APIs, require hosts to use `onPtyResize` only.

---

## 16. Open decisions (resolved by this doc)

| Question | Decision |
|----------|----------|
| Keep `StableFrameCommitPolicy`? | **No** — cell boundary only |
| Keep `MirrorGrid`? | **Yes** — render cache; always synced via `resizeSync` |
| Post-frame commit ever? | **No** for grid; optional post-frame for IME caret only |
| PTY before engine? | **Never** |
| Block engine during sidebar animation? | **Never**; `PtyHold` only |
| `null` from resolver on tiny layout? | **Never**; floor + pad |
