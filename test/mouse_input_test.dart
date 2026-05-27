import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/mouse_input.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

Uint8List u(List<int> x) => Uint8List.fromList(x);

void main() {
  test('no output when mouse reporting is off', () {
    expect(encodeMouse(0, MouseAction.down, 3, 4, modeFlags: 0), isNull);
  });

  test('SGR left press/release', () {
    final m = kModeMouseClick | kModeSgrMouse;
    expect(encodeMouse(0, MouseAction.down, 3, 4, modeFlags: m),
        u('\x1b[<0;3;4M'.codeUnits)); // press
    expect(encodeMouse(0, MouseAction.up, 3, 4, modeFlags: m),
        u('\x1b[<0;3;4m'.codeUnits)); // release
  });

  test('X10 left press encodes 32-offset bytes', () {
    final m = kModeMouseClick;
    expect(encodeMouse(0, MouseAction.down, 3, 4, modeFlags: m),
        u([0x1b, 0x5b, 0x4d, 32, 35, 36])); // ESC[M + 32, 32+3, 32+4
  });

  test('wheel up is button 64 (SGR)', () {
    final m = kModeMouseClick | kModeSgrMouse;
    expect(encodeMouse(0, MouseAction.scrollUp, 1, 1, modeFlags: m),
        u('\x1b[<64;1;1M'.codeUnits));
  });

  test('drag (move) only reported when DRAG/MOTION is set', () {
    expect(encodeMouse(0, MouseAction.move, 2, 2, modeFlags: kModeMouseClick), isNull);
    final m = kModeMouseClick | kModeMouseDrag | kModeSgrMouse;
    expect(encodeMouse(0, MouseAction.move, 2, 2, modeFlags: m),
        u('\x1b[<32;2;2M'.codeUnits)); // motion bit (+32) on left button
  });

  test('modifiers add to the button code (SGR ctrl+left)', () {
    final m = kModeMouseClick | kModeSgrMouse;
    expect(encodeMouse(0, MouseAction.down, 1, 1, ctrl: true, modeFlags: m),
        u('\x1b[<16;1;1M'.codeUnits)); // 0 + ctrl(16)
  });

  test('buttonless motion under MOTION uses no-button code 3 (+32)', () {
    final m = kModeMouseMotion | kModeSgrMouse;
    expect(encodeMouse(3, MouseAction.move, 2, 2, modeFlags: m),
        u('\x1b[<35;2;2M'.codeUnits)); // 3 (no button) + 32 (motion)
  });
}
