import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/program_scroll_encoder.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

void main() {
  test('alternate scroll encodes SS3 arrows', () {
    final bytes = encodeAlternateScrollLines(lines: 2, up: true);
    expect(bytes, [0x1b, 0x4f, 0x41, 0x1b, 0x4f, 0x41]);
  });

  test('mouse wheel batches SGR reports', () {
    final bytes = encodeMouseWheelLines(
      lines: 1,
      up: false,
      col: 5,
      row: 3,
      modeFlags: kModeSgrMouse | kModeMouseClick,
    );
    expect(bytes, isNotEmpty);
    expect(bytes.first, 0x1b);
  });
}
