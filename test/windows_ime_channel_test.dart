// End-to-end test of the Windows IME message chain: replays the exact
// 'flutter/textinput' messages the Windows embedder (text_input_plugin.cc)
// sends when a user types pinyin with Microsoft Pinyin, against the REAL
// framework TextInput plumbing — no direct ImeSession calls.
//
// The Windows engine keeps a two-space sentinel baseline in the model
// (ImeSession pushes kImeDeleteDetectionBaseline via setEditingState), so
// composing ranges arrive offset by 2. This test pins that the framework
// decodes TextInputClient.updateEditingState and routes it to the attached
// client with the composing range intact, that PreeditOverlay mounts, and
// that the committed text reaches the PTY.
import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';
import 'package:flutter_alacritty/ui/preedit_overlay.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';
import 'package:flutter_alacritty/example/example_app.dart';

import 'fake_binding.dart';

class _FakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  final writes = <Uint8List>[];
  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void write(Uint8List data) => writes.add(data);
  @override
  void resize(int rows, int columns) {}
  @override
  void kill() {}
  @override
  void close() {}
}

void main() {
  testWidgets('Windows engine message sequence shows preedit + commits',
      (tester) async {
    final title = ValueNotifier('t');
    final pty = _FakePty();

    // Capture outgoing TextInput.* calls (need the client id the framework
    // assigns so the fake engine replies carry the right id).
    final outgoing = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        outgoing.add(call);
        return null;
      },
    );

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
    await tester.pump();

    // Focus the terminal → _handleImeFocusChange → _ime.attach().
    await tester.tap(find.byType(TerminalView));
    await tester.pump();

    final setClient =
        outgoing.where((c) => c.method == 'TextInput.setClient').toList();
    expect(setClient, isNotEmpty, reason: 'attach() must have run');
    final clientId = (setClient.last.arguments as List)[0] as int;
    expect(
      outgoing.any((c) =>
          c.method == 'TextInput.setEditingState' &&
          (c.arguments as Map)['text'] == '  '),
      isTrue,
      reason: 'ImeSession must sync kImeDeleteDetectionBaseline on attach',
    );

    // Deliver engine→framework messages exactly as the Windows embedder does.
    Future<void> engineState({
      required String text,
      required int selBase,
      required int selExtent,
      required int compBase,
      required int compExtent,
    }) async {
      final args = <dynamic>[
        clientId,
        <String, dynamic>{
          'selectionAffinity': 'TextAffinity.downstream',
          'selectionBase': selBase,
          'selectionExtent': selExtent,
          'selectionIsDirectional': false,
          'composingBase': compBase,
          'composingExtent': compExtent,
          'text': text,
        },
      ];
      final data = SystemChannels.textInput.codec.encodeMethodCall(
          MethodCall('TextInputClient.updateEditingState', args));
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/textinput',
        data,
        (ByteData? _) {},
      );
    }

    // 1. WM_IME_STARTCOMPOSITION → ComposeBeginHook → SendStateUpdate
    //    (composing range collapsed at cursor 2).
    await engineState(
        text: '  ', selBase: 2, selExtent: 2, compBase: 2, compExtent: 2);
    await tester.pump();
    expect(find.byType(PreeditOverlay), findsNothing);

    // 2. WM_IME_COMPOSITION (GCS_COMPSTR "n") → ComposeChangeHook.
    await engineState(
        text: '  n', selBase: 3, selExtent: 3, compBase: 2, compExtent: 3);
    await tester.pump();
    expect(find.byType(PreeditOverlay), findsOneWidget,
        reason: 'pinyin "n" must be visible as preedit');
    expect(
        tester.widget<PreeditOverlay>(find.byType(PreeditOverlay)).text, 'n');

    // 3. GCS_COMPSTR grows to "ni".
    await engineState(
        text: '  ni', selBase: 4, selExtent: 4, compBase: 2, compExtent: 4);
    await tester.pump();
    expect(
        tester.widget<PreeditOverlay>(find.byType(PreeditOverlay)).text, 'ni');

    // 4. Commit: GCS_RESULTSTR "你" arrives as a composing update, then
    //    WM_IME_ENDCOMPOSITION → ComposeEndHook → collapsed composing.
    await engineState(
        text: '  你', selBase: 3, selExtent: 3, compBase: 2, compExtent: 3);
    await tester.pump();
    await engineState(
        text: '  你', selBase: 3, selExtent: 3, compBase: -1, compExtent: -1);
    await tester.pump();

    final bytes = pty.writes.expand((e) => e).toList();
    expect(utf8.decode(bytes), '你',
        reason: 'committed text must reach the PTY exactly once');
    expect(find.byType(PreeditOverlay), findsNothing,
        reason: 'overlay must hide after commit');

    title.dispose();
  });
}
