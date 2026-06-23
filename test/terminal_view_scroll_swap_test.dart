// Engine swap on a reused TerminalView must rebind scroll gestures to the
// swapped-in engine — not the disposed predecessor.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('engine swap routes TUI wheel scroll to the new engine',
      (tester) async {
    final binding1 = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final binding2 = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final captured1 = <List<int>>[];
    final captured2 = <List<int>>[];
    final engine1 = TerminalEngine.fromBinding(
      binding1,
      config: TerminalConfig.defaults(),
    );
    final engine2 = TerminalEngine.fromBinding(
      binding2,
      config: TerminalConfig.defaults(),
    );
    addTearDown(() {
      engine1.dispose();
      engine2.dispose();
    });
    engine1.output.listen((b) => captured1.add(b.toList()));
    engine2.output.listen((b) => captured2.add(b.toList()));

    final engineNotifier = ValueNotifier<TerminalEngine>(engine1);
    addTearDown(engineNotifier.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<TerminalEngine>(
          valueListenable: engineNotifier,
          builder: (context, engine, _) => TerminalView(engine),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    engine1.refreshView();

    engineNotifier.value = engine2;
    await tester.pump();
    engine2.refreshView();

    final center = tester.getCenter(find.byType(CustomPaint).first);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, -40),
      ),
    );
    await tester.pump();
    await Future<void>.value();

    expect(captured1, isEmpty);
    expect(captured2, isNotEmpty);
  });
}
