// Tests that an engine swap on a reused TerminalView stops any in-flight
// kinetic fling. Before the fix, the fling ticker kept running after the swap,
// so remaining fling frames would call _engine.scrollByPixels on the
// swapped-in engine's scrollback rather than the engine that started the fling.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'engine swap stops a coasting kinetic fling '
      '(fling must not bleed into the swapped-in engine)', (tester) async {
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

    final state =
        tester.state<TerminalViewState>(find.byType(TerminalView));

    // Start a fling via the test hook — this calls _startFling() directly
    // with a velocity well above _kFlingStartVelocity (80 px/s), so the
    // ticker is created and started regardless of gesture recogniser state
    // in the test environment.
    state.startFlingForTest(500.0);

    // Pump one frame so the ticker is truly running (Ticker.start() schedules
    // the first callback on the next vsync).
    await tester.pump();

    // Precondition: the fling ticker must be active before the swap.
    expect(state.isFlingingForTest, isTrue,
        reason: 'precondition: fling ticker must be running after startFlingForTest');

    // --- SWAP THE ENGINE ---
    // This triggers TerminalViewState.didUpdateWidget with a different engine.
    // Without the fix: _flingTicker keeps running (_stopFling not called).
    // With the fix: _stopFling() is called and the ticker is disposed/nulled.
    engineNotifier.value = engine2;
    await tester.pump();

    expect(state.isFlingingForTest, isFalse,
        reason: 'engine swap must stop the in-flight fling so remaining frames '
            'do not scroll the swapped-in engine\'s scrollback');
  });
}
