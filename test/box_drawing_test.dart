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
}
