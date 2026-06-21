# Rendering Performance — Findings & Optimization Plan

Status: **P1–P5 all implemented & verified** (2026-06-20). This document records
*why* the original pipeline was slower than native Alacritty, with evidence from
both this repo and the upstream Alacritty renderer, and the phased optimization
that closed the gap. Each item is backed by a measurement, not an assertion.

## Implemented (2026-06-20)

| Phase | Change | Verified by |
|-------|--------|-------------|
| **P1** | Cursor split to its own `CursorPainter` layer (+ `RepaintBoundary` on both grid and cursor layers, `isComplex`/`willChange`). Grid layer repaints on grid mutation only; the blink timer re-rasters one cell. | `test/grid_repaint_test.dart` "blink toggle repaints cursor layer only, not the grid"; full Dart suite (245) green |
| **P2** | Background pass skips default-bg cells (native `bg_alpha==0`) and run-length merges adjacent same-color spans into one `drawRect`. | `terminal_painter_test.dart`, `mirror_grid_test.dart`, lifecycle suite green |
| **P5** | `selPaint` / `decoPaint` hoisted out of the per-cell loops. | folded into P2 |
| **P3** | FFI `LineUpdate` is now columnar (`Vec<u32>`/`Vec<u16>`) instead of `Vec<CellData>`; FRB decodes straight to `Uint32List`/`Uint16List`; `engine_binding._lineCells` is a zero-copy passthrough; `MirrorGrid`/`LineCells` store `Uint32List`. No per-cell Dart object per update. | 89 Rust tests (`cargo test`); real-FFI `engine_bindings_test.dart`; full Dart suite green |
| **P4** | Grid glyphs go through a GPU glyph atlas (`GlyphAtlas`): each glyph is rasterized once as a white coverage mask; the painter submits a whole frame with one `Canvas.drawRawAtlas` (per-cell fg applied via the `colors` array + `BlendMode.modulate`) instead of `drawParagraph` per cell. DPR-aware (masks at physical res, `1/dpr` RSTransform). Box-drawing stays a direct vector draw; a not-yet-atlased glyph falls back to `drawParagraph`. Cursor layer keeps `GlyphCache`. **Bounded + incremental:** the atlas is capped at `maxTextureDimension` (4096px → ~3–4k glyph slots) so the single `ui.Image` never exceeds the GPU max texture size; glyphs past the cap fall back to `drawParagraph` permanently (no `hasPending` churn). Growth is incremental — `rebuildIfNeeded` blits the old image and rasterizes only the newly-assigned glyphs (O(new), not O(all)). | headless pixel-diff vs the `drawParagraph` render is identical bar ~1px AA (`test/visual_render_test.dart`, real DejaVu/CJK fonts, fractional metrics + 1.25× DPR, incl. dense 80×24); `test/glyph_atlas_test.dart` (request/rebuild/generation/**cap**); benchmark dense-text **1920 `drawParagraph` → 1 `drawRawAtlas`**, UI paint 428→164µs; verified crisp + correctly tinted in the running app |

Benchmark (`test/rendering_benchmark_test.dart`, 80×24, UI-thread paint µs +
draw-call counts):

| Scenario | drawRect | drawParagraph | drawRawAtlas | paint |
|----------|----------|---------------|--------------|-------|
| idle prompt | 0 (was 1920) | 20 | — | 105µs |
| dense text | 0 | 1920 | — | 429µs |
| dense text +atlas | 0 | **0** | **1** (1920 sprites) | **170µs** |
| worst-case | 1920 | 1920 | — | 898µs |
| worst-case +atlas | 1920 | **0** | **1** | **578µs** |

Files touched: `lib/render/terminal_painter.dart`, `lib/render/glyph_atlas.dart`
(new), `lib/render/mirror_grid.dart`, `lib/ui/terminal_view.dart`,
`lib/engine/engine_binding.dart`,
`packages/rust_lib_flutter_alacritty/rust/src/engine.rs` (+ regenerated
`lib/src/rust/*`, `src/frb_generated.rs`). The cdylib must be rebuilt
(`cargo build` / next `flutter build`) — a stale bundled `.so` decodes the new
columnar wire format wrong (RangeError in `sse_decode_list_prim_u_32_strict`).

**Release checklist** (the columnar FFI is the risky bit): (1) `cargo build` the
engine and bump the `rust_lib_flutter_alacritty` submodule pointer; (2) run the
real-FFI `test/engine_bindings_test.dart` (it self-builds the cdylib) — add it to
CI, since the default suite uses fakes and won't catch a wire-format drift;
(3) spot-check rendering on a fractional-DPR / fractional-cell-metric display
(the `visual`-tagged suite, gated on host fonts, covers this headlessly).

**Self-sufficiency:** the grid painter clears its layer to `defaultBg` at
`backgroundOpacity` (default 1.0 = opaque), so the widget does not depend on a
host-provided background even though P2 skips per-cell default-bg fills.

Original analysis (now historical) follows.

## TL;DR

We reuse Alacritty's *fast* grid/VTE half (`alacritty_terminal`) but replaced its
*fast* rendering half (GPU glyph atlas + instanced/batched draws) with a Dart
`Canvas` painter, and added an FFI hop in between. So a perceived "slower than
native" is **structural**, not a tuning gap. The pipeline is otherwise well
built (per-frame drain coalescing, partial damage, glyph LRU, per-frame build
budget, sub-cell scroll). Four hot-path costs are worth removing, in priority
order:

1. Cursor blink / any damage repaints the **whole** grid.
2. Background pass draws **one `drawRect` per cell**, including default-bg cells.
3. FFI materializes **one Dart object per cell** every update.
4. Each glyph is an individual `Canvas.drawParagraph` (no atlas / no batch).

## How native Alacritty renders (for contrast)

- **Glyph atlas + instanced batch.** Glyphs are rasterized into a texture atlas
  (`alacritty/src/renderer/text/atlas.rs`). `draw_cell` pushes an instance into a
  `Batch` (`text/mod.rs:108` `add_item`); the batch is flushed only when the
  texture changes or it fills (`text/mod.rs:121-129`). A frame's glyphs become a
  handful of instanced GPU draws, not N draw calls.
- **Background skipped when default.** `RenderableCell.bg_alpha` is computed in
  `display/content.rs:214` (`compute_bg_alpha`); a cell whose bg equals the
  default and isn't inverse gets `bg_alpha = 0`, so the shader draws no
  background quad and the window clear color shows through. Backgrounds that *do*
  draw ride the same instanced path.
- **No FFI.** Grid and renderer share a process and memory; there is no
  per-cell marshaling.

We can't fully match GPU instancing from a Dart `Canvas`, but we can close most
of the gap and, crucially, stop doing O(cells) work when O(damage) would do.

## Confirmed findings (with evidence)

### F1 — Whole-grid repaint on every change, including idle cursor blink

`TerminalPainter` repaints on `Listenable.merge([grid, blinkOn])`
(`lib/render/terminal_painter.dart:96`) and `paint()` always runs the full
`rows × cols` double loop — there is no dirty-row concept. Consequences:

- Partial damage to a single line bumps `MirrorGrid.generation`
  (`lib/render/mirror_grid.dart`), which repaints the entire grid.
- The cursor blink timer (`lib/ui/terminal_view.dart:320`) toggles `blinkOn`
  every interval, repainting the **entire grid on an idle terminal**.

There is **no `RepaintBoundary`** around the `CustomPaint`
(`lib/ui/terminal_view.dart:920`), and the embedding app doesn't add one either
(`teampilot/client/lib/widgets/workspace_terminal_panel.dart:340`), so the
repaint can also dirty/raster neighboring layers.

### F2 — One `drawRect` per cell for backgrounds, no default-bg skip

`lib/render/terminal_painter.dart:127-160`: the background pass issues
`canvas.drawRect` for **every** cell — including cells equal to `defaultBg`,
which native skips. No run-length merge of horizontally adjacent same-color
cells. At 80×24 that is ~1900 rects/frame floor; large terminals scale linearly.

### F3 — FFI materializes one Dart object per cell

Rust returns `RenderUpdate.lines: Vec<LineUpdate>`, each `cells: Vec<CellData>`
(`packages/rust_lib_flutter_alacritty/rust/src/engine.rs:41-57`). The generated
decoder allocates a Dart object per cell:

```dart
// lib/src/rust/frb_generated.dart:1207
List<CellData> dco_decode_list_cell_data(dynamic raw) =>
    (raw as List<dynamic>).map(dco_decode_cell_data).toList();
```

Then `lib/engine/engine_binding.dart:228` (`_lineCells`) loops those objects and
copies each field into `Int32List`s — a **double materialization**. FRB already
has a zero-copy fast path for primitive vectors right next door
(`dco_decode_list_prim_u_32_strict` → `Uint32List`,
`frb_generated.dart:1225`), which is what we want to switch onto.

### F4 — One `drawParagraph` per glyph, no atlas/batch

`lib/render/terminal_painter.dart` glyph pass calls `canvas.drawParagraph` per
visible cell. Layout itself is cached (`lib/render/glyph_cache.dart`, LRU +
per-frame build budget — good), but the *draw submission* is per-cell, far from
native's single instanced atlas draw.

### Non-issues (already good — don't regress these)

- **Drain coalescing:** `feed()` buffers and schedules one post-frame drain;
  the whole `_buf` is taken in a single `advanceAndTakeDamage` per frame
  (`lib/engine/terminal_engine_client.dart:80-117`). At most one FFI advance +
  repaint per frame.
- **Partial damage:** engine ships only changed rows when on the live edge
  (`engine.rs:906` `take_damage`).
- **Glyph LRU + per-frame build cap:** `glyph_cache.dart` (`maxBuildsPerFrame`)
  prevents first-paint layout storms.

## Optimization plan (phased)

Ordered by (impact ÷ risk). Land and measure one at a time; do not bundle.

### P1 — Split the cursor/blink into its own layer; add RepaintBoundary  *(low risk)*

- Wrap the grid `CustomPaint` in a `RepaintBoundary`; set `isComplex: true,
  willChange: true`.
- Move cursor drawing (including the blink) into a **second, overlaid**
  `CustomPaint` that repaints on `blinkOn` + cursor position only, painting a
  single cell. The main grid painter then repaints only on grid `generation`.
- Expected: idle terminal stops full-grid repainting on every blink; low-output
  typing no longer re-rasters the whole viewport.
- Risk: block-cursor inversion currently redraws the cell glyph in bg color
  (`terminal_painter.dart` Pass 3) — the overlay must reproduce that, reading
  the same `MirrorGrid` cell. Verify inverse/wide-cursor cases.
- **Measure:** DevTools timeline, idle terminal — raster + UI thread time per
  blink before/after; expect the per-blink frame to drop to ~cursor-cell cost.

### P2 — Background run-length merge + skip default bg  *(low risk)*

- In the background pass, skip cells where effective `bg == defaultBg` and not
  selected/inverse/match/hint (mirror native `bg_alpha == 0`). Fill the
  `CustomPaint` once with the default bg first (or rely on an opaque container).
- Coalesce horizontally adjacent same-color cells into one `drawRect`.
- Expected: typical text lines drop from `cols` rects to a few.
- Risk: correctness around selection/search/hyperlink/inverse overlays — keep
  those drawn per-cell on top; only the *base* bg pass is merged/skipped.
- **Measure:** count `drawRect` calls per frame (debug counter) on a full
  `htop`/`vim` screen; timeline raster time on `cat biglog`.

### P3 — Flat typed buffers across FFI (kill per-cell objects)  *(medium risk)*

- Change Rust `LineUpdate` to carry parallel primitive vectors instead of
  `Vec<CellData>`: `codepoints: Vec<u32>`, `fg: Vec<u32>`, `bg: Vec<u32>`,
  `flags: Vec<u16>`, `hyperlink_id: Vec<u32>` (or pack the whole `RenderUpdate`
  as a few big flat buffers with an offsets table to also cut per-*line* objects).
- FRB then decodes each as `Uint32List`/`Uint16List` (existing fast path); Dart
  `_lineCells` disappears — `MirrorGrid` `setRange`s the buffers directly.
- Expected: per-update allocation O(cells) → O(lines) (or O(1) if fully packed);
  major GC relief on full snapshots (resize, scrollback jumps, big output).
- Risk: touches the FFI contract + regenerates bridge; needs a `flutter_rust_bridge_codegen`
  run and careful endianness/width review. Land behind tests in
  `engine.rs` + `engine_binding` fakes.
- **Measure:** DevTools memory — allocations/GC during `cat 50MB`; wall-clock of
  `advanceAndTakeDamage` for a full snapshot.

### P4 — Glyph atlas + `drawAtlas` (or per-line Paragraph fallback)  *(high risk)*

- Full version: rasterize glyphs into a `ui.Image` atlas keyed like the current
  `GlyphCache`, and submit a frame's glyphs via one `Canvas.drawRawAtlas`
  (transforms + source rects + colors). This is the closest Dart analog to
  native instanced atlas rendering.
- Cheaper interim: build **one multi-span `Paragraph` per line** instead of one
  per cell — a single layout/draw per row rather than per glyph.
- Expected: scroll / heavy-redraw is the real ceiling here; biggest win but
  biggest change.
- Risk: color-per-glyph in `drawRawAtlas`, fallback fonts, CJK/wide cells, box
  drawing (currently special-cased in `box_drawing.dart`) all need handling.
  Prototype against `example/example_app.dart` first.
- **Measure:** sustained scroll FPS (`yes`/`seq` flood) before/after.

### P5 — Hoist `Paint` allocations out of the loops  *(trivial)*

- Selection `Paint` (`terminal_painter.dart:152`) and `decoPaint` are allocated
  per matching cell. Reuse single instances, mutate `.color`.
- **Measure:** marginal; bundle into P2's frame.

## Benchmark harness (build before P1)

Before optimizing, stand up a repeatable baseline so each phase is judged on
numbers, not feel:

- Scenarios in `example/example_app.dart` (or an integration test): (a) idle with
  blinking cursor, (b) steady typing, (c) `cat`/flood of a large file,
  (d) sustained scroll.
- Capture: Flutter DevTools timeline (UI + raster thread ms/frame), and a debug
  `drawRect` / `drawParagraph` counter in `TerminalPainter`.
- Record baseline numbers in this doc, then a row per phase.

## Open questions / still to research

- Does `--profile` show the bottleneck on the **raster** thread (draw-call
  bound, favors P2/P4) or the **UI** thread (favors P1/P3)? Decides whether to
  reorder P2 vs P3.
- Is `drawRawAtlas` per-glyph color cheaper than per-line `Paragraph` in
  practice for our typical content? Prototype both before committing P4.
- Can the engine emit *column-range* damage (not just per-row) so the painter
  repaints sub-row spans? Larger engine change; revisit after P1–P3.
