import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// A GPU glyph atlas: each distinct glyph (codepoint × bold × italic × wide) is
/// rasterized ONCE as a white coverage mask into a single [ui.Image], so the
/// painter can submit a whole frame's glyphs with one `Canvas.drawRawAtlas`
/// instead of one `drawParagraph` per cell. Per-cell foreground color is applied
/// at draw time via the atlas `colors` array with `BlendMode.modulate`
/// (white_mask × color = tinted glyph), so the atlas never duplicates a glyph
/// per color — mirroring native Alacritty's atlas + instanced text shader.
///
/// Masks are stored at PHYSICAL resolution (logical × devicePixelRatio); the
/// painter draws them back with an RSTransform scale of `1/dpr`, so on a logical
/// canvas composited at `dpr` the sprite maps 1:1 to screen pixels (crisp).
///
/// Every slot is sized for a WIDE (2-cell) glyph so narrow and wide glyphs share
/// one uniform grid; a narrow glyph simply leaves the right half transparent,
/// and italic/overhang ink that spills past the cell is still captured.
class GlyphAtlas {
  GlyphAtlas({
    required this.fontFamily,
    required this.fontSize,
    required this.cellWidth,
    required this.cellHeight,
    required this.devicePixelRatio,
    this.fontFamilyFallback = const [],
    this.boldFamily,
    this.italicFamily,
    this.boldItalicFamily,
    this.lineHeight = 1.0,
    this.columns = 32,
  })  : _slotPhysW = (cellWidth * 2 * devicePixelRatio).ceil(),
        _slotPhysH = (cellHeight * devicePixelRatio).ceil();

  final String fontFamily;
  final String? boldFamily;
  final String? italicFamily;
  final String? boldItalicFamily;
  final List<String> fontFamilyFallback;
  final double fontSize;
  final double cellWidth;
  final double cellHeight;
  final double devicePixelRatio;
  final double lineHeight;

  /// Slots per atlas row.
  final int columns;

  final int _slotPhysW;
  final int _slotPhysH;

  ui.Image? _image;
  final Map<int, int> _slotIndex = {}; // key -> slot ordinal
  final Set<int> _pending = {};
  int _generation = 0;

  // Reusable per-frame batch scratch (avoids allocating ~30KB/frame). 4 floats
  // per sprite for the RSTransform and source rect, 1 int for the tint color.
  Float32List _xforms = Float32List(0);
  Float32List _rects = Float32List(0);
  Int32List _colors = Int32List(0);
  int _count = 0;

  /// The current atlas image, or null before the first build.
  ui.Image? get image => _image;

  /// Bumps whenever [_image] is replaced — lets the painter invalidate any
  /// cached source-rect arrays keyed on the atlas identity.
  int get generation => _generation;

  /// Same key packing as GlyphCache, minus color (the atlas is color-agnostic).
  static int keyFor(int codepoint,
      {bool bold = false, bool italic = false, bool wide = false}) {
    return (codepoint << 3) |
        ((bold ? 1 : 0) << 2) |
        ((italic ? 1 : 0) << 1) |
        (wide ? 1 : 0);
  }

  /// True if [key] already has a slot the painter can draw from this frame.
  bool has(int key) => _slotIndex.containsKey(key);

  /// Records that [key] is needed; it gets a slot on the next [rebuildIfNeeded].
  /// Returns false if the glyph isn't available yet (painter should fall back).
  bool request(int key) {
    if (_slotIndex.containsKey(key)) return true;
    _pending.add(key);
    return false;
  }

  bool get hasPending => _pending.isNotEmpty;

  // --- Per-frame batch API -------------------------------------------------
  // The painter calls beginBatch once, addSprite per glyph that [has] a slot,
  // then drawBatch to emit the whole frame's glyphs in one drawRawAtlas.

  /// Resets the batch and ensures scratch capacity for up to [maxGlyphs].
  void beginBatch(int maxGlyphs) {
    if (_xforms.length < maxGlyphs * 4) {
      _xforms = Float32List(maxGlyphs * 4);
      _rects = Float32List(maxGlyphs * 4);
      _colors = Int32List(maxGlyphs);
    }
    _count = 0;
  }

  /// Appends one glyph at logical cell origin ([tx], [ty]) tinted [color]
  /// (0xAARRGGBB). [key] must already [has] a slot.
  void addSprite(int key, double tx, double ty, int color) {
    final slot = _slotIndex[key]!;
    final col = slot % columns;
    final row = slot ~/ columns;
    final l = (col * _slotPhysW).toDouble();
    final t = (row * _slotPhysH).toDouble();
    final o = _count * 4;
    // RSTransform: scale = 1/dpr (physical sprite -> logical), no rotation.
    _xforms[o] = 1.0 / devicePixelRatio;
    _xforms[o + 1] = 0.0;
    _xforms[o + 2] = tx;
    _xforms[o + 3] = ty;
    _rects[o] = l;
    _rects[o + 1] = t;
    _rects[o + 2] = l + _slotPhysW;
    _rects[o + 3] = t + _slotPhysH;
    _colors[_count] = color;
    _count++;
  }

  /// Emits the accumulated glyphs in one call. No-op if empty or not yet built.
  void drawBatch(ui.Canvas canvas, ui.Paint paint) {
    final img = _image;
    if (img == null || _count == 0) return;
    canvas.drawRawAtlas(
      img,
      Float32List.sublistView(_xforms, 0, _count * 4),
      Float32List.sublistView(_rects, 0, _count * 4),
      Int32List.sublistView(_colors, 0, _count),
      ui.BlendMode.modulate,
      null,
      paint,
    );
  }

  /// Rebuilds the atlas image if new glyphs were [request]ed. Synchronous
  /// (`toImageSync`); cheap because it only runs when the glyph set grows.
  /// Returns true if a rebuild happened (painter should repaint).
  bool rebuildIfNeeded() {
    if (_pending.isEmpty) return false;
    // Assign slots to all pending keys after the existing ones.
    final keys = <int>[];
    for (final k in _pending) {
      if (!_slotIndex.containsKey(k)) {
        _slotIndex[k] = _slotIndex.length;
        keys.add(k);
      }
    }
    _pending.clear();
    if (keys.isEmpty && _image != null) return false;

    final total = _slotIndex.length;
    final rows = (total / columns).ceil();
    final physW = columns * _slotPhysW;
    final physH = rows * _slotPhysH;

    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    // Re-render every known glyph (the old image is discarded). The glyph set is
    // small (a few hundred for a terminal), so a full redraw on growth is fine.
    //
    // Each glyph is translated to its INTEGER physical slot origin and then
    // scaled by dpr — NOT a single global scale with logical offsets. Otherwise,
    // when `slotW*dpr` isn't an integer (fractional cell metrics / fractional
    // DPR), the glyph's rendered position (col*slotLogicalW*dpr) drifts from the
    // source rect the painter samples (col*ceil(slotW*dpr)), and the drift grows
    // per column/row — glyphs get sampled from neighboring slots and render as
    // garbage. Anchoring to the integer slot origin makes them match exactly.
    _slotIndex.forEach((key, slot) {
      final col = slot % columns;
      final row = slot ~/ columns;
      canvas.save();
      canvas.translate((col * _slotPhysW).toDouble(), (row * _slotPhysH).toDouble());
      canvas.scale(devicePixelRatio);
      _paintGlyph(canvas, key, 0, 0);
      canvas.restore();
    });
    final pic = rec.endRecording();
    final img = pic.toImageSync(math.max(physW, 1), math.max(physH, 1));
    pic.dispose();
    _image?.dispose();
    _image = img;
    _generation++;
    return true;
  }

  void _paintGlyph(ui.Canvas canvas, int key, double dx, double dy) {
    final codepoint = key >> 3;
    final bold = (key & 4) != 0;
    final italic = (key & 2) != 0;
    final wide = (key & 1) != 0;
    final family = _familyForStyle(bold: bold, italic: italic);
    final hasDedicated = (bold && italic && boldItalicFamily != null) ||
        (bold && !italic && boldFamily != null) ||
        (!bold && italic && italicFamily != null);
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: family,
      fontSize: fontSize,
      height: lineHeight,
      strutStyle: ui.StrutStyle(
        fontFamily: family,
        fontSize: fontSize,
        height: lineHeight,
        forceStrutHeight: true,
      ),
    ))
      ..pushStyle(ui.TextStyle(
        color: const ui.Color(0xFFFFFFFF), // white mask — tinted at draw time
        fontFamily: family,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: fontSize,
        fontWeight: bold && !hasDedicated ? ui.FontWeight.bold : ui.FontWeight.normal,
        fontStyle: italic && !hasDedicated ? ui.FontStyle.italic : ui.FontStyle.normal,
      ))
      ..addText(String.fromCharCode(codepoint));
    final layoutW = wide ? cellWidth * 2 : cellWidth;
    final p = builder.build()..layout(ui.ParagraphConstraints(width: layoutW));
    canvas.drawParagraph(p, ui.Offset(dx, dy));
    p.dispose();
  }

  String _familyForStyle({required bool bold, required bool italic}) {
    if (bold && italic) return boldItalicFamily ?? fontFamily;
    if (bold) return boldFamily ?? fontFamily;
    if (italic) return italicFamily ?? fontFamily;
    return fontFamily;
  }

  void dispose() {
    _image?.dispose();
    _image = null;
    _slotIndex.clear();
    _pending.clear();
  }
}
