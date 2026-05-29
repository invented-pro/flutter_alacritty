import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_shortcuts.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

/// FakeBinding variant that returns a fixed selection string for the Copy
/// path (the base class returns null).
class _SelectingBinding extends FakeBinding {
  _SelectingBinding(this._text);
  final String _text;
  @override
  String? selectionText() => _text;
}

Future<void> _pumpView(
  WidgetTester tester, {
  required TerminalEngine engine,
  Map<ShortcutActivator, Intent>? shortcuts,
  Map<Type, Action<Intent>>? actions,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TerminalView(
        engine,
        shortcuts: shortcuts,
        actions: actions,
      ),
    ),
  ));
  // Settle autofocus + first paint.
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'default Ctrl+Shift+C copies the engine selection to the clipboard',
      (tester) async {
    final binding = _SelectingBinding('hello');
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    addTearDown(engine.dispose);

    // Capture clipboard writes via the platform channel mock so we don't
    // depend on any real clipboard implementation.
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await _pumpView(tester, engine: engine);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(clipboardText, 'hello');
  });

  testWidgets('custom shortcuts override defaults; default chord is silent',
      (tester) async {
    final binding = _SelectingBinding('SHOULD-NOT-COPY');
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    addTearDown(engine.dispose);

    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    var pasteHits = 0;
    await _pumpView(
      tester,
      engine: engine,
      // Map Ctrl+K → PasteIntent; nothing else. Default Ctrl+Shift+C is
      // explicitly absent → the chord must not copy.
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            PasteIntent(),
      },
      actions: <Type, Action<Intent>>{
        PasteIntent: CallbackAction<PasteIntent>(onInvoke: (_) {
          pasteHits++;
          return null;
        }),
      },
    );

    // Custom chord triggers paste.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(pasteHits, 1);

    // Default chord must NOT copy (it's not in the supplied shortcut map).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(clipboardText, isNull,
        reason: 'overridden shortcut map dropped the Ctrl+Shift+C entry');
  });

  testWidgets('empty shortcuts map disables every default chord',
      (tester) async {
    final binding = _SelectingBinding('SHOULD-NOT-COPY');
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    addTearDown(engine.dispose);

    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await _pumpView(
      tester,
      engine: engine,
      shortcuts: const {},
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(clipboardText, isNull,
        reason: 'shortcuts: const {} should disable every hotkey');
  });
}
