import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('same key returns the identical cached paragraph', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 4);
    final a = cache.tryGet('A'.codeUnitAt(0), 0xFFFFFF);
    final b = cache.tryGet('A'.codeUnitAt(0), 0xFFFFFF);
    expect(a, isNotNull);
    expect(identical(a, b), isTrue);
  });

  test('evicts beyond capacity', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 2);
    cache.tryGet(0x41, 0xFFFFFF);
    cache.tryGet(0x42, 0xFFFFFF);
    cache.tryGet(0x43, 0xFFFFFF); // evicts 0x41
    expect(cache.length, 2);
  });

  test('wide and narrow keys are distinct', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 4);
    const cp = 0x4E2D; // 中
    final narrow = cache.tryGet(cp, 0xFFFFFF, wide: false);
    final wide = cache.tryGet(cp, 0xFFFFFF, wide: true);
    expect(narrow, isNotNull);
    expect(wide, isNotNull);
    expect(identical(narrow, wide), isFalse);
  });

  test('returns null past the per-frame build budget', () {
    final cache = GlyphCache(
        fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxBuildsPerFrame: 1);
    expect(cache.tryGet(0x41, 0xFFFFFF), isNotNull); // 1st build allowed
    expect(cache.tryGet(0x42, 0xFFFFFF), isNull); // budget exhausted this frame
    cache.beginFrame();
    expect(cache.tryGet(0x42, 0xFFFFFF), isNotNull); // budget reset
  });
}
