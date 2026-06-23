import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('multiple wheel events in one frame coalesce to one scrollLines',
      (tester) async {
    final binding = FakeBinding()
      ..displayOffsetSim = 50
      ..historySizeSim = 100;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TerminalView(engine)),
    ));
    await tester.pumpAndSettle();
    engine.refreshView();

    final center = tester.getCenter(find.byType(CustomPaint).first);
    for (var i = 0; i < 5; i++) {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0, 120),
        ),
      );
    }
    // Five wheel ticks coalesce net lines into one awaited scrollLines batch.
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollCalls, 1);
    expect(binding.scrollLinesArgs.single, lessThan(0));
    expect(binding.scrollPixelsArgs, isEmpty);
  });
}
