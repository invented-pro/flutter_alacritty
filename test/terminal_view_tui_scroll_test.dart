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

  testWidgets('TUI wheel batches to single PTY write', (tester) async {
    final binding = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final captured = <List<int>>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
    );
    addTearDown(engine.dispose);
    engine.output.listen((b) => captured.add(b.toList()));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TerminalView(engine)),
    ));
    await tester.pumpAndSettle();
    engine.refreshView();

    final center = tester.getCenter(find.byType(CustomPaint).first);
    for (var i = 0; i < 4; i++) {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0, 15),
        ),
      );
    }
    await tester.pump();
    await Future<void>.value();

    expect(captured.length, 1);
    expect(captured.single.length, greaterThan(0));
  });
}
