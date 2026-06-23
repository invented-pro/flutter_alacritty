import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('invokes onPtyResize after engine resize on first layout',
      (tester) async {
    final binding = FakeBinding();
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    addTearDown(engine.dispose);

    final ptySizes = <(int, int)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TerminalView(
          engine,
          onPtyResize: (c, r) => ptySizes.add((c, r)),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(ptySizes, isNotEmpty);
    expect(binding.resizeCalls, greaterThan(0));
    expect(ptySizes.last.$1, binding.lastResizeCols);
    expect(ptySizes.last.$2, binding.lastResizeRows);
  });

  testWidgets('engine swap onPtyResize matches viewport not default 80x24',
      (tester) async {
    final binding1 = FakeBinding();
    final engine1 = TerminalEngine.fromBinding(
      binding1,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    final binding2 = FakeBinding();
    final engine2 = TerminalEngine.fromBinding(
      binding2,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    addTearDown(() {
      engine1.dispose();
      engine2.dispose();
    });

    final ptySizes = <(int, int)>[];
    final engineNotifier = ValueNotifier<TerminalEngine>(engine1);
    addTearDown(engineNotifier.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 600,
          child: ValueListenableBuilder<TerminalEngine>(
            valueListenable: engineNotifier,
            builder: (context, engine, _) => TerminalView(
              engine,
              onPtyResize: (c, r) => ptySizes.add((c, r)),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(binding1.resizeCalls, greaterThan(0));
    final committedCols = binding1.lastResizeCols;
    final committedRows = binding1.lastResizeRows;
    expect((committedCols, committedRows), isNot((80, 24)));
    final countBeforeSwap = ptySizes.length;

    engineNotifier.value = engine2;
    await tester.pump();
    await tester.pump();

    expect(binding2.resizeCalls, greaterThan(0));
    expect(binding2.lastResizeCols, committedCols);
    expect(binding2.lastResizeRows, committedRows);

    final swapSizes = ptySizes.skip(countBeforeSwap);
    expect(swapSizes, isNotEmpty);
    for (final (cols, rows) in swapSizes) {
      expect((cols, rows), isNot((80, 24)));
      expect(cols, committedCols);
      expect(rows, committedRows);
    }
  });
}
