import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/program_scroll_encoder.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/ui/terminal_scroll_controller.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('alt-screen: multiple ingests coalesce to one batched write', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final binding = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
    );
    engine.refreshView();

    ctrl.onPanDelta(dyPx: 12, shiftHeld: false);
    ctrl.onPanDelta(dyPx: 12, shiftHeld: false);
    ctrl.onPanDelta(dyPx: 20, shiftHeld: false);
    expect(captured, isEmpty);

    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(captured.length, 1);
    expect(captured.single.length, 2 * 3);
  });

  test('history: routes to scrollPixels not output', () async {
    final binding = FakeBinding();
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
    );

    ctrl.onPanDelta(dyPx: -30, shiftHeld: false);
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollPixelsArgs, isNotEmpty);
    expect(binding.scrollPixelsArgs.single, closeTo(-30.0, 1e-9));
  });

  test('history wheel negates dy like PointerScrollEvent', () async {
    final binding = FakeBinding();
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
    );

    ctrl.onWheelSignal(dyPx: 120, shiftHeld: false);
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollPixelsArgs.single, closeTo(-120.0, 1e-9));
  });

  Future<void> drain(List<void Function()> pending) async {
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();
  }

  test('alt-screen pan positive dy scrolls up (SS3 A)', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final binding = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
    );
    engine.refreshView();

    ctrl.onPanDelta(dyPx: 40, shiftHeld: false);
    await drain(pending);

    expect(captured.single, [0x1b, 0x4f, 0x41, 0x1b, 0x4f, 0x41]);
  });

  test('alt-screen wheel positive dy scrolls down (SS3 B)', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final binding = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
    );
    engine.refreshView();

    ctrl.onWheelSignal(dyPx: 40, shiftHeld: false);
    await drain(pending);

    expect(captured.single, [0x1b, 0x4f, 0x42, 0x1b, 0x4f, 0x42]);
  });

  test('mouse mode uses multiplier 1.0 not scrollMultiplier/3', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final modeFlags = kModeSgrMouse | kModeMouseClick;
    final binding = FakeBinding()..modeFlags = modeFlags;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 6,
    );
    engine.refreshView();
    ctrl.setWheelCell(col: 1, row: 1);

    // scrollMultiplier 6 → _multiplier 2.0, but mouse mode forces 1.0 → 1 line.
    ctrl.onPanDelta(dyPx: 25, shiftHeld: false);
    await drain(pending);

    final oneLine = encodeMouseWheelLines(
      lines: 1,
      up: true,
      col: 1,
      row: 1,
      modeFlags: modeFlags,
    );
    expect(captured.single, oneLine);
  });
}
