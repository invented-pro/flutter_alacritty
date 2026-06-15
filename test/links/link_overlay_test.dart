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

  test('multiple ranges on one row — second range reached, half-open boundaries hold', () {
    final o = LinkOverlay({
      0: const [LinkCellRange(start: 2, end: 4), LinkCellRange(start: 7, end: 10)],
    });
    // First range [2, 4)
    expect(o.isLinkCell(0, 2), isTrue);
    // Second range [7, 10)
    expect(o.isLinkCell(0, 8), isTrue);
    // Gap between ranges
    expect(o.isLinkCell(0, 5), isFalse);
    // End of first range (half-open: 4 is excluded)
    expect(o.isLinkCell(0, 4), isFalse);
    // End of second range (half-open: 10 is excluded)
    expect(o.isLinkCell(0, 10), isFalse);
  });

  test('value equality: equal-content overlays compare == with equal hashCode; distinct content compares !=', () {
    final a = LinkOverlay({
      0: const [LinkCellRange(start: 1, end: 3)],
      2: const [LinkCellRange(start: 5, end: 8)],
    });
    final b = LinkOverlay({
      0: const [LinkCellRange(start: 1, end: 3)],
      2: const [LinkCellRange(start: 5, end: 8)],
    });
    final c = LinkOverlay({
      0: const [LinkCellRange(start: 1, end: 4)], // different end
      2: const [LinkCellRange(start: 5, end: 8)],
    });

    // Equal overlays
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    // Different overlay
    expect(a, isNot(equals(c)));

    // LinkCellRange value equality
    expect(const LinkCellRange(start: 2, end: 4), equals(const LinkCellRange(start: 2, end: 4)));
    expect(const LinkCellRange(start: 2, end: 4), isNot(equals(const LinkCellRange(start: 2, end: 5))));
  });
}
