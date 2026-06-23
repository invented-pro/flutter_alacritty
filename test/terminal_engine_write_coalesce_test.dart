import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scheduleWrite coalesces within one scheduling tick', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      FakeBinding(),
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    engine.scheduleWrite(Uint8List.fromList([1, 2]));
    engine.scheduleWrite(Uint8List.fromList([3]));
    expect(captured, isEmpty);
    expect(pending, isNotEmpty);

    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(captured.length, 1);
    expect(captured.single, [1, 2, 3]);
  });

  test('dispose drains pending scheduleWrite', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      FakeBinding(),
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    engine.output.listen(captured.add);

    engine.scheduleWrite(Uint8List.fromList([9, 8]));
    expect(captured, isEmpty);
    expect(engine.pendingWriteBytesForTest, 2);

    engine.dispose();
    await Future<void>.value();

    expect(captured.length, 1);
    expect(captured.single, [9, 8]);
  });

  test('dispose drains pending scheduleTask chain', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      FakeBinding(),
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    engine.output.listen(captured.add);

    engine.scheduleTask(() {
      engine.scheduleWrite(Uint8List.fromList([7]));
    });
    expect(captured, isEmpty);

    engine.dispose();
    await Future<void>.value();

    expect(captured.single, [7]);
  });
}
