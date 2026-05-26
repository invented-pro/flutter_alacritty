import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/input/key_input.dart';

void main() {
  test('enter encodes CR', () {
    expect(
      encodeKey(LogicalKeyboardKey.enter, null, ctrl: false),
      Uint8List.fromList([0x0d]),
    );
  });
  test('backspace encodes DEL', () {
    expect(
      encodeKey(LogicalKeyboardKey.backspace, null, ctrl: false),
      Uint8List.fromList([0x7f]),
    );
  });
  test('ctrl+c encodes 0x03', () {
    expect(
      encodeKey(LogicalKeyboardKey.keyC, 'c', ctrl: true),
      Uint8List.fromList([0x03]),
    );
  });
  test('arrow up encodes ESC [ A', () {
    expect(
      encodeKey(LogicalKeyboardKey.arrowUp, null, ctrl: false),
      Uint8List.fromList([0x1b, 0x5b, 0x41]),
    );
  });
  test('printable char encodes its utf8', () {
    expect(
      encodeKey(LogicalKeyboardKey.keyA, 'a', ctrl: false),
      Uint8List.fromList([0x61]),
    );
  });
}
