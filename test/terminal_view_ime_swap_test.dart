// Tests that an engine swap on a reused TerminalView abandons any in-flight
// IME composition. Before the fix, the composition was never cleared on swap
// because focus does not change (same FocusNode, view reused), so the stale
// preedit could commit into the newly swapped-in engine.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'engine swap clears in-flight IME composition (preedit must not '
      'commit into the swapped-in engine)', (tester) async {
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

    // Drive a composing value directly through the ImeSession — this is the
    // standard unit-test path used by the existing ime_session_test.dart tests
    // (no platform channel needed; updateEditingValue is a pure-Dart callback).
    // This sets isComposing=true and updates _preedit via _onPreeditChanged.
    state.imeForTest.updateEditingValue(
      const TextEditingValue(
          text: 'ni', composing: TextRange(start: 0, end: 2)),
    );
    // _onPreeditChanged calls setState; pump one frame to flush it.
    await tester.pump();

    // Preconditions: composition is active before the swap.
    expect(state.imeForTest.isComposing, isTrue,
        reason: 'precondition: ImeSession should be composing after updateEditingValue');
    expect(state.preeditForTest, 'ni',
        reason: 'precondition: _preedit should be set before the swap');

    // --- SWAP THE ENGINE ---
    // This triggers TerminalViewState.didUpdateWidget with a different engine.
    // Without the fix: isComposing stays true and _preedit stays 'ni'.
    // With the fix: both are cleared.
    engineNotifier.value = engine2;
    await tester.pump();

    expect(state.imeForTest.isComposing, isFalse,
        reason: 'engine swap must clear IME composing state so the stale '
            'preedit cannot commit into the swapped-in engine');
    expect(state.preeditForTest, isNull,
        reason: 'engine swap must clear _preedit directly (no setState during '
            'didUpdateWidget) so build() reflects the cleared state');
  });
}
