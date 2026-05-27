import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

void main() {
  test('inverse swaps fg and bg', () {
    final c = effectiveColors(kFlagInverse, 0xAABBCC, 0x111111);
    expect(c.fg, 0x111111);
    expect(c.bg, 0xAABBCC);
  });

  test('dim darkens fg by ~0.66 and leaves bg', () {
    final c = effectiveColors(kFlagDim, 0x969696, 0x111111);
    expect(c.fg, 0x636363); // 0x96=150 -> 150*0.66=99=0x63
    expect(c.bg, 0x111111);
  });

  test('plain cell passes colors through', () {
    final c = effectiveColors(0, 0xD8D8D8, 0x181818);
    expect(c.fg, 0xD8D8D8);
    expect(c.bg, 0x181818);
  });
}
