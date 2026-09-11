// Regression tests for the preedit (IME composing string) placement.
//
// Bug (Windows, 2026-09): PreeditOverlay was positioned at
// `cursorRect.bottom + 2` — immediately BELOW the cursor row. The OS IME
// anchors its candidate window at the caret/composing rect we report via
// `ImeSession.setImeGeometry` (setComposingRect/setCaretRect), i.e. in the
// same spot below the caret. The candidate pane is an always-on-top OS-owned
// HWND, so it painted over the Flutter-drawn preedit — the pinyin letters
// were invisible whenever candidates were shown. (On Windows the engine also
// strips ISC_SHOWUICOMPOSITIONWINDOW, so the app MUST render the composing
// string itself — there is no OS fallback.) Additionally, with the prompt on
// the last row, `bottom + 2` fell outside the Stack and was clipped.
//
// Fix: render the preedit INLINE on the cursor's own row (Windows Terminal /
// Alacritty convention) and stop the Stack from clipping it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';
import 'package:flutter_alacritty/ui/preedit_overlay.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';
import 'package:flutter_alacritty/example/example_app.dart';

import 'fake_binding.dart';

class _FakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int rows, int columns) {}
  @override
  void kill() {}
  @override
  void close() {}
}

void main() {
  testWidgets('PreeditOverlay renders inline on the cursor row, not below it',
      (tester) async {
    // Cursor cell on a bottom row of a 400px-tall stack: the old
    // `bottom + 2` placement (382) would already be outside the stack.
    const cell = Rect.fromLTWH(96, 360, 10, 20);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: Stack(
            children: [
              PreeditOverlay(
                text: 'nihao',
                cursorRect: cell,
                bg: 0x282828,
                fg: 0xD8D8D8,
                underline: true,
                textStyle: const TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    ));
    final overlay = tester.getRect(find.byType(PreeditOverlay));
    expect(overlay.left, cell.left,
        reason: 'preedit starts at the cursor column');
    expect(overlay.top, cell.top,
        reason: 'preedit must sit ON the cursor row. Placing it below '
            '(cursorRect.bottom + 2) puts it exactly under the OS candidate '
            'pane, which always paints over app content — the Windows '
            '"invisible letters" bug.');
    expect(overlay.top, lessThan(cell.bottom));
    expect(overlay.height, cell.height,
        reason: 'preedit occupies exactly one cell row so it reads as inline '
            'composition text');
  });

  testWidgets('composing preedit lands on the cursor row in the live tree',
      (tester) async {
    final title = ValueNotifier('t');
    final pty = _FakePty();
    final binding = FakeBinding();
    await tester.pumpWidget(MaterialApp(home: ExampleTerminalApp(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns,
        required rows,
        required onPtyWrite,
        required onTitle,
        required onBell,
        required onClipboard,
        required onClipboardLoad,
        required void Function(String) onWorkingDir,
        required void Function(String) onNotify,
        required engineConfig,
      }) =>
          binding,
    )));
    await tester.pump();
    final state = tester.state(find.byType(TerminalView));
    final ime = (state as dynamic).imeForTest as TextInputClient;
    ime.updateEditingValue(const TextEditingValue(
        text: 'ni', composing: TextRange(start: 0, end: 2)));
    await tester.pump();
    expect(find.byType(PreeditOverlay), findsOneWidget);

    // The grid area (== the terminal Stack) and the cell metrics.
    final termRect = tester.getRect(find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is TerminalPainter));
    TerminalPainter cellPainter() => tester
        .widgetList<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is TerminalPainter))
        .map((w) => w.painter!)
        .cast<TerminalPainter>()
        .first;
    final cellHeight = cellPainter().cellHeight;

    final overlay = tester.getRect(find.byType(PreeditOverlay));
    // FakeBinding's blank grid has the cursor at row 0 — the preedit must
    // overlay that row, not the row below it.
    expect(overlay.top, greaterThanOrEqualTo(termRect.top));
    expect(overlay.top, lessThan(termRect.top + cellHeight),
        reason: 'preedit must be on the cursor row; below it the OS '
            'candidate pane covers it');
    title.dispose();
  });

  testWidgets('the terminal Stack does not clip the preedit', (tester) async {
    final title = ValueNotifier('t');
    final pty = _FakePty();
    await tester.pumpWidget(MaterialApp(home: ExampleTerminalApp(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns,
        required rows,
        required onPtyWrite,
        required onTitle,
        required onBell,
        required onClipboard,
        required onClipboardLoad,
        required void Function(String) onWorkingDir,
        required void Function(String) onNotify,
        required engineConfig,
      }) =>
          FakeBinding(),
    )));
    await tester.pump();
    final state = tester.state(find.byType(TerminalView));
    final ime = (state as dynamic).imeForTest as TextInputClient;
    ime.updateEditingValue(const TextEditingValue(
        text: 'ni', composing: TextRange(start: 0, end: 2)));
    await tester.pump();

    final ctx = tester.element(find.byType(PreeditOverlay));
    final stack = ctx.findAncestorWidgetOfExactType<Stack>();
    expect(stack, isNotNull);
    expect(stack!.clipBehavior, Clip.none,
        reason: 'a long preedit starting near the right edge (or on the last '
            'row) must paint outside the grid bounds; a clipped Stack makes '
            'it invisible');
    title.dispose();
  });
}
