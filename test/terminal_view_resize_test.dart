import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

TerminalEngine _engine() => TerminalEngine.fromBinding(
      FakeBinding(),
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );

Finder gridPaintFinder() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is TerminalPainter,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CustomPaint size matches mirror grid after layout', (tester) async {
    final engine = _engine();
    addTearDown(engine.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: TerminalView(engine),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final grid = engine.gridForView;
    final vp = state.viewport!;
    final paintFinder = gridPaintFinder();
    final paint = tester.widget<CustomPaint>(paintFinder);

    expect(paint.size!.width, closeTo(grid.columns * vp.cellWidth, 0.01));
    expect(paint.size!.height, closeTo(grid.rows * vp.cellHeight, 0.01));
  });

  testWidgets('resize updates paint size to match new grid', (tester) async {
    final engine = _engine();
    addTearDown(engine.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: TerminalView(engine),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 900,
          child: TerminalView(engine),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final grid = engine.gridForView;
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final vp = state.viewport!;
    final paintFinder = gridPaintFinder();
    final paint = tester.widget<CustomPaint>(paintFinder);

    expect(paint.size!.width, closeTo(grid.columns * vp.cellWidth, 0.01));
    expect(paint.size!.height, closeTo(grid.rows * vp.cellHeight, 0.01));
    expect(grid.columns, greaterThan(40));
    expect(grid.rows, greaterThan(15));
  });

  testWidgets('beginPtyHold suppresses onPtyResize until endPtyHold', (tester) async {
    final engine = _engine();
    addTearDown(engine.dispose);
    final commits = <(int, int)>[];

    final key = GlobalKey<TerminalViewState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: TerminalView(
            engine,
            key: key,
            onPtyResize: (c, r) => commits.add((c, r)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    commits.clear();

    key.currentState!.beginPtyHold();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: TerminalView(
            engine,
            key: key,
            onPtyResize: (c, r) => commits.add((c, r)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(commits, isEmpty);

    key.currentState!.endPtyHold();
    await tester.pump();
    expect(commits, isNotEmpty);
  });
}
