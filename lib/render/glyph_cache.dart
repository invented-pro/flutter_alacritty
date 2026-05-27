import 'dart:collection';
import 'dart:ui' as ui;

/// Caches pre-laid-out single-glyph paragraphs keyed by (codepoint, fg) so the
/// painter never re-runs text layout on the hot path. LRU-capped.
class GlyphCache {
  GlyphCache({
    required this.fontFamily,
    required this.fontSize,
    required this.cellWidth,
    this.maxEntries = 4096,
    this.maxBuildsPerFrame = 128,
  });

  final String fontFamily;
  final double fontSize;
  final double cellWidth;
  final int maxEntries;
  /// Caps synchronous paragraph layout per frame so first paint cannot freeze the UI.
  final int maxBuildsPerFrame;

  final LinkedHashMap<int, ui.Paragraph> _cache = LinkedHashMap();
  int _buildsThisFrame = 0;

  int get length => _cache.length;

  void beginFrame() => _buildsThisFrame = 0;

  /// Returns a cached paragraph, or builds one if under the per-frame budget.
  ui.Paragraph? tryGet(int codepoint, int fg) {
    final key = (codepoint << 24) ^ (fg & 0xFFFFFF);
    final existing = _cache.remove(key);
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }
    if (_buildsThisFrame >= maxBuildsPerFrame) return null;
    _buildsThisFrame++;
    final p = _build(codepoint, fg);
    _cache[key] = p;
    if (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return p;
  }

  ui.Paragraph get(int codepoint, int fg) {
    final key = (codepoint << 24) ^ (fg & 0xFFFFFF);
    final existing = _cache.remove(key); // remove+reinsert = LRU touch
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }
    final p = _build(codepoint, fg);
    _cache[key] = p;
    if (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first); // evict eldest
    }
    return p;
  }

  ui.Paragraph _build(int codepoint, int fg) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
    ))
      ..pushStyle(ui.TextStyle(
        color: ui.Color(0xFF000000 | (fg & 0xFFFFFF)),
        fontFamily: fontFamily,
        fontSize: fontSize,
      ))
      ..addText(String.fromCharCode(codepoint));
    final p = builder.build()..layout(ui.ParagraphConstraints(width: cellWidth));
    return p;
  }
}
