import 'dart:convert';

import 'package:flutter/services.dart';

/// Tracer-bullet key encoder. Default (non-application) cursor mode only.
/// Plan 2 makes this mode-aware via the engine's mode flags.
Uint8List? encodeKey(LogicalKeyboardKey key, String? character,
    {required bool ctrl}) {
  // Control combos: Ctrl+A..Z -> 0x01..0x1a.
  if (ctrl && character != null && character.length == 1) {
    final c = character.toLowerCase().codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7a) {
      return Uint8List.fromList([c - 0x60]);
    }
  }

  switch (key) {
    case LogicalKeyboardKey.enter:
    case LogicalKeyboardKey.numpadEnter:
      return Uint8List.fromList([0x0d]);
    case LogicalKeyboardKey.backspace:
      return Uint8List.fromList([0x7f]);
    case LogicalKeyboardKey.tab:
      return Uint8List.fromList([0x09]);
    case LogicalKeyboardKey.escape:
      return Uint8List.fromList([0x1b]);
    case LogicalKeyboardKey.arrowUp:
      return Uint8List.fromList([0x1b, 0x5b, 0x41]);
    case LogicalKeyboardKey.arrowDown:
      return Uint8List.fromList([0x1b, 0x5b, 0x42]);
    case LogicalKeyboardKey.arrowRight:
      return Uint8List.fromList([0x1b, 0x5b, 0x43]);
    case LogicalKeyboardKey.arrowLeft:
      return Uint8List.fromList([0x1b, 0x5b, 0x44]);
  }

  // Printable character.
  if (character != null && character.isNotEmpty) {
    return Uint8List.fromList(utf8.encode(character));
  }
  return null;
}
