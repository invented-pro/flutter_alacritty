import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds an engine whose drain pipeline runs synchronously when the test
  /// calls [drain]. The default `schedule` uses `SchedulerBinding`'s
  /// post-frame callback, which never fires in a unit test without
  /// `tester.pump()`.
  ({TerminalEngine engine, Future<void> Function() drain}) buildEngine(
    FakeBinding binding,
  ) {
    void Function()? pending;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending = cb,
    );
    Future<void> drain() async {
      // Run scheduled drains until the buffer is empty (the drain re-schedules
      // itself when more bytes arrive mid-advance).
      while (pending != null) {
        final p = pending!;
        pending = null;
        p();
        await Future<void>.delayed(Duration.zero);
      }
    }
    return (engine: engine, drain: drain);
  }

  test('write(bytes) flows out via the output stream', () async {
    final binding = FakeBinding();
    final h = buildEngine(binding);
    final captured = <Uint8List>[];
    final sub = h.engine.output.listen(captured.add);

    h.engine.write(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(Duration.zero);

    expect(captured, isNotEmpty);
    expect(captured.expand((b) => b).toList(), [1, 2, 3]);

    await sub.cancel();
    h.engine.dispose();
  });

  test('Event::Title (via pumpEvents) updates the title ValueListenable',
      () async {
    final binding = FakeBinding();
    final h = buildEngine(binding);
    expect(h.engine.title.value, isNotNull);

    binding.pendingEvents.add(('title', 'my-title'));
    h.engine.feed(Uint8List.fromList([1])); // schedule a drain
    await h.drain();

    expect(h.engine.title.value, 'my-title');

    h.engine.dispose();
  });

  test('Event::ResetTitle resets title to default', () async {
    final binding = FakeBinding();
    final h = buildEngine(binding);
    binding.pendingEvents.add(('title', 'changed'));
    h.engine.feed(Uint8List.fromList([1]));
    await h.drain();
    expect(h.engine.title.value, 'changed');

    binding.pendingEvents.add(('reset_title', null));
    h.engine.feed(Uint8List.fromList([2]));
    await h.drain();
    expect(h.engine.title.value, kDefaultTerminalTitle);

    h.engine.dispose();
  });

  test('Event::Bell emits on the bell stream', () async {
    final binding = FakeBinding();
    final h = buildEngine(binding);
    var bells = 0;
    final sub = h.engine.bell.listen((_) => bells++);

    binding.pendingEvents.add(('bell', null));
    h.engine.feed(Uint8List.fromList([1]));
    await h.drain();

    expect(bells, 1);

    await sub.cancel();
    h.engine.dispose();
  });

  test('Event::ClipboardStore emits on the clipboardStore stream', () async {
    final binding = FakeBinding();
    final h = buildEngine(binding);
    final captured = <String>[];
    final sub = h.engine.clipboardStore.listen(captured.add);

    binding.pendingEvents.add(('clipboard', 'hello'));
    h.engine.feed(Uint8List.fromList([1]));
    await h.drain();

    expect(captured, ['hello']);

    await sub.cancel();
    h.engine.dispose();
  });

  test('Event::PtyWrite emits on the output stream', () async {
    final binding = FakeBinding();
    final h = buildEngine(binding);
    final captured = <Uint8List>[];
    final sub = h.engine.output.listen(captured.add);

    binding.pendingEvents.add(('pty', Uint8List.fromList([7, 8, 9])));
    h.engine.feed(Uint8List.fromList([1]));
    await h.drain();

    expect(captured.expand((b) => b).toList(), [7, 8, 9]);

    await sub.cancel();
    h.engine.dispose();
  });

  test('hyperlinkAt forwards to the engine binding', () async {
    final binding = FakeBinding()
      ..hyperlinkAt[(0, 3)] = 42
      ..hyperlinkUris[42] = 'https://example.com';
    final h = buildEngine(binding);
    // Resize triggers a refreshView() which applies the searched snapshot —
    // that's what populates the mirror grid's hyperlinkId column.
    h.engine.resize(columns: 80, rows: 24);
    await h.drain();

    expect(h.engine.hyperlinkAt(0, 3), 'https://example.com');
    expect(h.engine.hyperlinkAt(0, 0), isNull);

    h.engine.dispose();
  });

  test('dispose closes output, bell, and clipboardStore streams', () async {
    final binding = FakeBinding();
    final h = buildEngine(binding);
    var outputDone = false;
    var bellDone = false;
    var clipboardDone = false;
    h.engine.output.listen(null, onDone: () => outputDone = true);
    h.engine.bell.listen(null, onDone: () => bellDone = true);
    h.engine.clipboardStore.listen(null, onDone: () => clipboardDone = true);

    h.engine.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(outputDone, isTrue);
    expect(bellDone, isTrue);
    expect(clipboardDone, isTrue);
  });

  test('search proxies forward to the binding', () async {
    final binding = FakeBinding();
    final h = buildEngine(binding);
    // The fake binding returns true for any non-`(` pattern.
    expect(h.engine.searchSet('foo'), isTrue);
    expect(h.engine.searchSet('('), isFalse);
    // next/prev/clear don't have asserts beyond not throwing.
    h.engine.searchNext();
    h.engine.searchPrev();
    h.engine.searchClear();
    h.engine.dispose();
  });

  test('only resize binds the engine; pre-bind calls buffer then replay',
      () async {
    var factoryCalls = 0;
    late int boundCols;
    late int boundRows;
    final fake = FakeBinding();
    final engine = TerminalEngine(
      config: TerminalConfig.defaults(),
      engineFactory: ({
        required int columns,
        required int rows,
        required void Function(Uint8List) onPtyWrite,
        required void Function(String) onTitle,
        required void Function() onBell,
        required void Function(String) onClipboard,
        required void Function() onClipboardLoad,
        required void Function(String) onWorkingDir,
        required void Function(String) onNotify,
        required engineConfig,
      }) {
        factoryCalls++;
        boundCols = columns;
        boundRows = rows;
        return fake;
      },
    );
    // No native init yet — even title is readable.
    expect(engine.title.value, isNotNull);
    expect(factoryCalls, 0);

    // Non-sizing calls must NOT fabricate a grid: the parser cannot run before
    // the line width is known. They stash and replay on bind.
    engine.setCellPixels(7, 15);
    engine.feed(Uint8List.fromList([65, 66]));
    engine.feed(Uint8List.fromList([67]));
    expect(factoryCalls, 0, reason: 'feed/setCellPixels must not bind');
    expect(engine.isBound, isFalse);
    expect(fake.fedBytes, isEmpty);
    expect(fake.lastCellWidth, isNull);

    // The first resize is the authoritative size source — it binds exactly once
    // at the real dimensions and replays everything buffered, metrics first.
    engine.resize(columns: 80, rows: 24);
    expect(factoryCalls, 1);
    expect(boundCols, 80);
    expect(boundRows, 24);
    expect(fake.lastCellWidth, 7);
    expect(fake.lastCellHeight, 15);
    // Feed is batched through the client's drain scheduler; flush it.
    await engine.drainForTest();
    expect(fake.fedBytes, [65, 66, 67],
        reason: 'buffered PTY output replays in order — no first frame lost');

    engine.dispose();
  });
}
