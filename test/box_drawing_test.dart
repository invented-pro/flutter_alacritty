import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/box_drawing.dart';

const cell = Rect.fromLTWH(0, 0, 10, 20);
const lw = 2.0;

void main() {
  test('isBoxDrawing covers U+2500..U+259F only', () {
    expect(isBoxDrawing(0x24FF), isFalse);
    expect(isBoxDrawing(0x2500), isTrue);
    expect(isBoxDrawing(0x259F), isTrue);
    expect(isBoxDrawing(0x25A0), isFalse);
  });

  test('vertical line is one centered full-height LineOp', () {
    final ops = boxOps(0x2502, cell, lw); // │
    final lines = ops.whereType<LineOp>().toList();
    expect(lines.length, 1);
    expect(lines.first.a.dx, cell.center.dx);
    expect(lines.first.b.dx, cell.center.dx);
    expect(lines.first.a.dy, cell.top);
    expect(lines.first.b.dy, cell.bottom);
  });

  test('horizontal line spans full width at vertical center', () {
    final ops = boxOps(0x2500, cell, lw); // ─
    final l = ops.whereType<LineOp>().single;
    expect(l.a.dy, cell.center.dy);
    expect(l.a.dx, cell.left);
    expect(l.b.dx, cell.right);
  });

  test('top-left corner draws down + right arms (2 lines)', () {
    final ops = boxOps(0x250C, cell, lw); // ┌
    expect(ops.whereType<LineOp>().length, 2);
  });

  test('cross draws four arms', () {
    final ops = boxOps(0x253C, cell, lw); // ┼
    expect(ops.whereType<LineOp>().length, 4);
  });

  test('double horizontal draws two parallel lines', () {
    final ops = boxOps(0x2550, cell, lw); // ═
    expect(ops.whereType<LineOp>().length, 2);
  });

  test('rounded corner emits an arc', () {
    expect(boxOps(0x256D, cell, lw).whereType<ArcOp>().length, 1); // ╭
  });

  test('rounded corner arms reach the cell edges (no gap to adjacent lines)', () {
    bool touchesY(List<LineOp> ls, double y) =>
        ls.any((l) => l.a.dy == y || l.b.dy == y);
    bool touchesX(List<LineOp> ls, double x) =>
        ls.any((l) => l.a.dx == x || l.b.dx == x);

    final dr = boxOps(0x256D, cell, lw).whereType<LineOp>().toList(); // ╭ down+right
    expect(touchesY(dr, cell.bottom), isTrue, reason: '╭ must reach the bottom edge');
    expect(touchesX(dr, cell.right), isTrue, reason: '╭ must reach the right edge');

    final ul = boxOps(0x256F, cell, lw).whereType<LineOp>().toList(); // ╯ up+left
    expect(touchesY(ul, cell.top), isTrue, reason: '╯ must reach the top edge');
    expect(touchesX(ul, cell.left), isTrue, reason: '╯ must reach the left edge');
  });

  test('diagonal cross emits two lines', () {
    expect(boxOps(0x2573, cell, lw).whereType<LineOp>().length, 2); // ╳
  });

  test('full block is a full-cell opaque rect', () {
    final r = boxOps(0x2588, cell, lw).whereType<RectOp>().single; // █
    expect(r.rect, cell);
    expect(r.alpha, 1.0);
  });

  test('upper half block fills the top half', () {
    final r = boxOps(0x2580, cell, lw).whereType<RectOp>().single; // ▀
    expect(r.rect.height, cell.height / 2);
    expect(r.rect.top, cell.top);
  });

  test('medium shade is a full-cell rect at 0.5 alpha', () {
    final r = boxOps(0x2592, cell, lw).whereType<RectOp>().single; // ▒
    expect(r.rect, cell);
    expect(r.alpha, closeTo(0.5, 1e-9));
  });

  test('lower-right quadrant fills the bottom-right rect', () {
    final r = boxOps(0x2597, cell, lw).whereType<RectOp>().single; // ▗
    expect(
      r.rect,
      Rect.fromLTRB(cell.center.dx, cell.center.dy, cell.right, cell.bottom),
    );
  });

  test('mixed light/heavy tee has a heavy arm and light arms', () {
    // ┝ U+251D: up light, down light, right heavy (left none).
    final ops = boxOps(0x251D, const Rect.fromLTWH(0, 0, 10, 20), 1.0);
    final lines = ops.whereType<LineOp>().toList();
    expect(lines.length, greaterThanOrEqualTo(3));
    // The right arm is heavy (width 1.8), the vertical arms are light (1.0).
    expect(lines.any((l) => l.width == 1.8), isTrue);
    expect(lines.any((l) => l.width == 1.0), isTrue);
  });

  test('single/double mixed corner emits a light and a double arm', () {
    // ╒ U+2552: down single (light), right double.
    final ops = boxOps(0x2552, const Rect.fromLTWH(0, 0, 10, 20), 1.0);
    final lines = ops.whereType<LineOp>().toList();
    // double arm = two parallel strokes → at least 3 line ops total.
    expect(lines.length, greaterThanOrEqualTo(3));
  });

  test('light triple dash horizontal emits a 3-segment DashOp', () {
    final ops = boxOps(0x2504, const Rect.fromLTWH(0, 0, 12, 20), 1.0); // ┄
    final dash = ops.whereType<DashOp>().single;
    expect(dash.segments, 3);
    expect(dash.a.dy, dash.b.dy); // horizontal
  });

  test('heavy quadruple dash vertical is a 4-segment heavy DashOp', () {
    final ops = boxOps(0x250B, const Rect.fromLTWH(0, 0, 12, 20), 1.0); // ┋
    final dash = ops.whereType<DashOp>().single;
    expect(dash.segments, 4);
    expect(dash.a.dx, dash.b.dx); // vertical
    expect(dash.width, 1.8); // heavy
  });
}
