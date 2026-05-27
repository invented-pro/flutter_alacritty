import 'dart:ui';

/// A primitive draw op for a box-drawing/block glyph. Pure data so geometry is
/// unit-testable independent of a Canvas.
sealed class BoxOp {}

class LineOp extends BoxOp {
  LineOp(this.a, this.b, this.width);
  final Offset a;
  final Offset b;
  final double width;
}

class RectOp extends BoxOp {
  RectOp(this.rect, this.alpha);
  final Rect rect;
  final double alpha; // multiplier on the fg alpha (shades < 1)
}

class ArcOp extends BoxOp {
  ArcOp(this.bounds, this.startAngle, this.sweepAngle, this.width);
  final Rect bounds;
  final double startAngle;
  final double sweepAngle;
  final double width;
}

bool isBoxDrawing(int cp) => cp >= 0x2500 && cp <= 0x259F;

// Arm weights: 0 none, 1 light, 2 heavy, 3 double. Order: [up, down, left, right].
// Covers the high-frequency lines/corners/junctions (light/heavy/double).
const Map<int, List<int>> _arms = {
  0x2500: [0, 0, 1, 1], 0x2501: [0, 0, 2, 2], // ─ ━
  0x2502: [1, 1, 0, 0], 0x2503: [2, 2, 0, 0], // │ ┃
  0x250C: [0, 1, 0, 1], 0x2510: [0, 1, 1, 0], // ┌ ┐
  0x2514: [1, 0, 0, 1], 0x2518: [1, 0, 1, 0], // └ ┘
  0x251C: [1, 1, 0, 1], 0x2524: [1, 1, 1, 0], // ├ ┤
  0x252C: [0, 1, 1, 1], 0x2534: [1, 0, 1, 1], // ┬ ┴
  0x253C: [1, 1, 1, 1], // ┼
  0x2550: [0, 0, 3, 3], 0x2551: [3, 3, 0, 0], // ═ ║
  0x2554: [0, 3, 0, 3], 0x2557: [0, 3, 3, 0], // ╔ ╗
  0x255A: [3, 0, 0, 3], 0x255D: [3, 0, 3, 0], // ╚ ╝
  0x2560: [3, 3, 0, 3], 0x2563: [3, 3, 3, 0], // ╠ ╣
  0x2566: [0, 3, 3, 3], 0x2569: [3, 0, 3, 3], // ╦ ╩
  0x256C: [3, 3, 3, 3], // ╬
};

double _w(int weight, double lineWidth) => weight == 2 ? lineWidth * 1.8 : lineWidth;

/// Returns the draw ops for [cp] within [cell]. Empty if [cp] is not handled
/// programmatically (caller falls back to the font glyph).
List<BoxOp> boxOps(int cp, Rect cell, double lineWidth) {
  final arms = _arms[cp];
  if (arms != null) return _armOps(arms, cell, lineWidth);
  if (cp >= 0x256D && cp <= 0x2570) return _roundedOps(cp, cell, lineWidth);
  if (cp >= 0x2571 && cp <= 0x2573) return _diagonalOps(cp, cell, lineWidth);
  if (cp >= 0x2580 && cp <= 0x259F) return _blockOps(cp, cell);
  return const [];
}

List<BoxOp> _roundedOps(int cp, Rect cell, double lineWidth) {
  final cx = cell.center.dx, cy = cell.center.dy;
  final r = (cell.width < cell.height ? cell.width : cell.height) / 2;
  switch (cp) {
    case 0x256D: // ╭
      return [
        ArcOp(
          Rect.fromCircle(center: Offset(cx + r, cy + r), radius: r),
          3.1415926,
          1.5707963,
          lineWidth,
        ),
      ];
    case 0x256E: // ╮
      return [
        ArcOp(
          Rect.fromCircle(center: Offset(cx - r, cy + r), radius: r),
          4.7123889,
          1.5707963,
          lineWidth,
        ),
      ];
    case 0x256F: // ╯
      return [
        ArcOp(
          Rect.fromCircle(center: Offset(cx - r, cy - r), radius: r),
          0,
          1.5707963,
          lineWidth,
        ),
      ];
    case 0x2570: // ╰
      return [
        ArcOp(
          Rect.fromCircle(center: Offset(cx + r, cy - r), radius: r),
          1.5707963,
          1.5707963,
          lineWidth,
        ),
      ];
  }
  return const [];
}

List<BoxOp> _diagonalOps(int cp, Rect cell, double lineWidth) {
  final ops = <BoxOp>[];
  if (cp == 0x2571 || cp == 0x2573) {
    ops.add(LineOp(cell.bottomLeft, cell.topRight, lineWidth)); // ╱
  }
  if (cp == 0x2572 || cp == 0x2573) {
    ops.add(LineOp(cell.topLeft, cell.bottomRight, lineWidth)); // ╲
  }
  return ops;
}

List<BoxOp> _blockOps(int cp, Rect cell) {
  final l = cell.left, t = cell.top, r = cell.right, b = cell.bottom;
  final cx = cell.center.dx, cy = cell.center.dy;
  Rect q(double l0, double t0, double r0, double b0) =>
      Rect.fromLTRB(l0, t0, r0, b0);
  switch (cp) {
    case 0x2588:
      return [RectOp(cell, 1.0)]; // █
    case 0x2580:
      return [RectOp(q(l, t, r, cy), 1.0)]; // ▀ upper half
    case 0x2584:
      return [RectOp(q(l, cy, r, b), 1.0)]; // ▄ lower half
    case 0x258C:
      return [RectOp(q(l, t, cx, b), 1.0)]; // ▌ left half
    case 0x2590:
      return [RectOp(q(cx, t, r, b), 1.0)]; // ▐ right half
    case 0x2591:
      return [RectOp(cell, 0.25)]; // ░
    case 0x2592:
      return [RectOp(cell, 0.5)]; // ▒
    case 0x2593:
      return [RectOp(cell, 0.75)]; // ▓
    case 0x2596:
      return [RectOp(q(l, cy, cx, b), 1.0)]; // ▖ BL
    case 0x2597:
      return [RectOp(q(cx, cy, r, b), 1.0)]; // ▗ BR
    case 0x2598:
      return [RectOp(q(l, t, cx, cy), 1.0)]; // ▘ TL
    case 0x259D:
      return [RectOp(q(cx, t, r, cy), 1.0)]; // ▝ TR
    case 0x259A:
      return [
        RectOp(q(l, t, cx, cy), 1.0),
        RectOp(q(cx, cy, r, b), 1.0),
      ]; // ▚ TL+BR
    case 0x259E:
      return [
        RectOp(q(cx, t, r, cy), 1.0),
        RectOp(q(l, cy, cx, b), 1.0),
      ]; // ▞ TR+BL
    case 0x2599:
      return [
        RectOp(q(l, t, cx, b), 1.0),
        RectOp(q(cx, cy, r, b), 1.0),
      ]; // ▙
    case 0x259B:
      return [
        RectOp(q(l, t, r, cy), 1.0),
        RectOp(q(l, cy, cx, b), 1.0),
      ]; // ▛
    case 0x259C:
      return [
        RectOp(q(l, t, r, cy), 1.0),
        RectOp(q(cx, cy, r, b), 1.0),
      ]; // ▜
    case 0x259F:
      return [
        RectOp(q(cx, t, r, b), 1.0),
        RectOp(q(l, cy, cx, b), 1.0),
      ]; // ▟
  }
  return const [];
}

List<BoxOp> _armOps(List<int> arms, Rect cell, double lineWidth) {
  final cx = cell.center.dx, cy = cell.center.dy;
  final ops = <BoxOp>[];
  // For a double arm, draw two parallel strokes offset by `d`.
  final d = lineWidth;
  void arm(int weight, Offset end, bool vertical) {
    if (weight == 0) return;
    if (weight == 3) {
      final o = vertical ? Offset(d, 0) : Offset(0, d);
      ops.add(LineOp(Offset(cx, cy) - o, end - o, lineWidth));
      ops.add(LineOp(Offset(cx, cy) + o, end + o, lineWidth));
    } else {
      ops.add(LineOp(Offset(cx, cy), end, _w(weight, lineWidth)));
    }
  }
  // Straight-through optimisation for plain lines keeps a single full-span LineOp.
  if (arms[0] == 0 && arms[1] == 0 && arms[2] == arms[3] && arms[2] != 0) {
    final wt = arms[2];
    if (wt == 3) {
      return [
        LineOp(Offset(cell.left, cy - d), Offset(cell.right, cy - d), lineWidth),
        LineOp(Offset(cell.left, cy + d), Offset(cell.right, cy + d), lineWidth),
      ];
    }
    return [LineOp(Offset(cell.left, cy), Offset(cell.right, cy), _w(wt, lineWidth))];
  }
  if (arms[2] == 0 && arms[3] == 0 && arms[0] == arms[1] && arms[0] != 0) {
    final wt = arms[0];
    if (wt == 3) {
      return [
        LineOp(Offset(cx - d, cell.top), Offset(cx - d, cell.bottom), lineWidth),
        LineOp(Offset(cx + d, cell.top), Offset(cx + d, cell.bottom), lineWidth),
      ];
    }
    return [LineOp(Offset(cx, cell.top), Offset(cx, cell.bottom), _w(wt, lineWidth))];
  }
  arm(arms[0], Offset(cx, cell.top), true); // up
  arm(arms[1], Offset(cx, cell.bottom), true); // down
  arm(arms[2], Offset(cell.left, cy), false); // left
  arm(arms[3], Offset(cell.right, cy), false); // right
  return ops;
}
