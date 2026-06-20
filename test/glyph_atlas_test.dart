import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_atlas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GlyphAtlas make({int maxTextureDimension = 4096}) => GlyphAtlas(
        fontFamily: 'monospace',
        fontSize: 14,
        cellWidth: 8,
        cellHeight: 16,
        devicePixelRatio: 2.0,
        maxTextureDimension: maxTextureDimension,
      );

  test('request queues a glyph (false) until rebuild, then has a slot (true)', () {
    final atlas = make();
    final k = GlyphAtlas.keyFor('A'.codeUnitAt(0));
    expect(atlas.request(k), isFalse, reason: 'not yet built → fall back');
    expect(atlas.hasPending, isTrue);
    expect(atlas.image, isNull);

    expect(atlas.rebuildIfNeeded(), isTrue);
    expect(atlas.hasPending, isFalse);
    expect(atlas.image, isNotNull);
    expect(atlas.request(k), isTrue, reason: 'now has a slot');
    expect(atlas.has(k), isTrue);
    atlas.dispose();
  });

  test('generation bumps on each rebuild; no-op rebuild returns false', () {
    final atlas = make();
    atlas.request(GlyphAtlas.keyFor(65));
    expect(atlas.rebuildIfNeeded(), isTrue);
    final g1 = atlas.generation;
    expect(atlas.rebuildIfNeeded(), isFalse, reason: 'nothing pending');
    expect(atlas.generation, g1);

    atlas.request(GlyphAtlas.keyFor(66));
    expect(atlas.rebuildIfNeeded(), isTrue);
    expect(atlas.generation, greaterThan(g1));
    atlas.dispose();
  });

  test('style bits produce distinct keys/slots', () {
    final atlas = make();
    final plain = GlyphAtlas.keyFor(65);
    final bold = GlyphAtlas.keyFor(65, bold: true);
    final italic = GlyphAtlas.keyFor(65, italic: true);
    final wide = GlyphAtlas.keyFor(65, wide: true);
    expect({plain, bold, italic, wide}.length, 4);
    for (final k in [plain, bold, italic, wide]) {
      atlas.request(k);
    }
    atlas.rebuildIfNeeded();
    for (final k in [plain, bold, italic, wide]) {
      expect(atlas.has(k), isTrue);
    }
    atlas.dispose();
  });

  test('caps at capacity — overflow glyphs are not queued (permanent fallback)', () {
    // Tiny texture budget → small capacity, so we can exhaust it cheaply.
    // cellHeight 16 × dpr 2 = 32px slots; 64px budget → 2 rows × 32 cols = 64 slots.
    final atlas = make(maxTextureDimension: 64);
    expect(atlas.capacity, 64);

    // Fill exactly to capacity with distinct codepoints.
    for (var i = 0; i < atlas.capacity; i++) {
      expect(atlas.request(0x100 + i), isFalse); // queued
    }
    // One more distinct glyph: must NOT queue (cap reached) and must keep
    // hasPending honest so the painter doesn't spin scheduling frames.
    final overflow = 0x100 + atlas.capacity;
    expect(atlas.request(overflow), isFalse);

    atlas.rebuildIfNeeded();
    // The capacity glyphs got slots; the overflow one never did.
    expect(atlas.has(0x100), isTrue);
    expect(atlas.has(0x100 + atlas.capacity - 1), isTrue);
    expect(atlas.has(overflow), isFalse);
    // Re-requesting the overflow glyph still won't queue it (no pending churn).
    expect(atlas.request(overflow), isFalse);
    expect(atlas.hasPending, isFalse,
        reason: 'capped glyph must not keep hasPending true (no scheduleFrame spin)');
    atlas.dispose();
  });
}
