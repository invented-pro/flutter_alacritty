import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

void main() {
  test('cursorInk falls back to inverse fg when unset', () {
    final ink = cursorInk(kCursorColorUnset, 0x00D8D8D8);
    expect(ink, const Color(0xFFD8D8D8));
  });

  test('cursorInk uses the OSC 12 color when set', () {
    final ink = cursorInk(0x0000FF00, 0x00D8D8D8);
    expect(ink, const Color(0xFF00FF00));
  });

  group('resolveCursorColor (OSC 12 > host default > inverse video)', () {
    test('program OSC 12 color wins over the host default', () {
      expect(resolveCursorColor(0x0000FFAA, 0x00FF0000), 0x0000FFAA);
    });
    test('host default is used when OSC 12 is unset', () {
      expect(resolveCursorColor(kCursorColorUnset, 0x00FF0000), 0x00FF0000);
    });
    test('unset + no host default => inverse-video sentinel', () {
      expect(resolveCursorColor(kCursorColorUnset, null), kCursorColorUnset);
    });
  });
}
