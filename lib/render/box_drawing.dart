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
