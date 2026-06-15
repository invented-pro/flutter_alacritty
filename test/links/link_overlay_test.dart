import 'package:flutter_alacritty/links/link_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('overlay reports enabled cells per row, half-open ranges', () {
    final o = LinkOverlay({
      0: const [LinkCellRange(start: 4, end: 9)],
    });
    expect(o.isLinkCell(0, 4), isTrue);
    expect(o.isLinkCell(0, 8), isTrue);
    expect(o.isLinkCell(0, 9), isFalse);
    expect(o.isLinkCell(0, 3), isFalse);
    expect(o.isLinkCell(1, 5), isFalse);
  });

  test('empty overlay is a const sentinel', () {
    expect(LinkOverlay.empty.isLinkCell(0, 0), isFalse);
  });
}
