import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/controller/terminal_controller.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';

import 'fake_binding.dart';

/// Pure-Dart tests for TerminalController. The controller is a thin
/// ChangeNotifier shell around TerminalEngine — these tests pin the notify
/// semantics and the gates (clearSelection / searchClear no-ops). The engine
/// underneath is wired to a FakeBinding so no native init / no Flutter widget
/// tree is needed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalController + Engine wired', () {
    late FakeBinding binding;
    late TerminalEngine engine;
    late TerminalController controller;

    setUp(() {
      binding = FakeBinding();
      engine = TerminalEngine.fromBinding(
        binding,
        config: TerminalConfig.defaults(),
      );
      controller = TerminalController()..attach(engine);
    });

    tearDown(() {
      controller.dispose();
      engine.dispose();
    });

    test('attach exposes the engine; calling twice is a programmer error', () {
      expect(controller.engine, same(engine));
      expect(
        () => controller.attach(engine),
        throwsA(isA<AssertionError>()),
      );
    });

    test('selectionStart sets selectionActive and notifies', () {
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.selectionStart(0, 0, false, 0);
      expect(notifies, 1);
      expect(controller.selectionActive, isTrue);
      expect(binding.selStartCalls, 1);
    });

    test('selectionUpdate notifies (drag refresh)', () {
      controller.selectionStart(0, 0, false, 0);
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.selectionUpdate(0, 1, true);
      expect(notifies, 1);
    });

    test('clearSelection notifies + clears engine selection', () {
      controller.selectionStart(0, 0, false, 0);
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.clearSelection();
      expect(notifies, 1);
      expect(controller.selectionActive, isFalse);
      expect(binding.selClearCalls, 1);
    });

    test('clearSelection is a no-op when selectionActive is false', () {
      expect(controller.selectionActive, isFalse);
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.clearSelection();
      expect(notifies, 0,
          reason: 'gate matches alacritty event.rs:clear_selection');
      expect(binding.selClearCalls, 0);
    });

    test('readSelectionText proxies to the engine', () {
      // FakeBinding.selectionText returns null; we just assert the call path.
      expect(controller.readSelectionText(), isNull);
    });

    test('capturePrimary updates primary only when text changed', () {
      // FakeBinding returns null → primary stays empty.
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.capturePrimary();
      expect(controller.primary, '');
      expect(notifies, 0, reason: 'no change → no notify');
    });

    test('searchSet updates pattern + validity and notifies', () {
      var notifies = 0;
      controller.addListener(() => notifies++);
      // FakeBinding returns true for any non-`(` pattern.
      final ok = controller.searchSet('foo');
      expect(ok, isTrue);
      expect(controller.searchPattern, 'foo');
      expect(controller.searchValid, isTrue);
      expect(notifies, 1);
    });

    test('searchSet flags invalid patterns', () {
      controller.searchSet('(');
      expect(controller.searchValid, isFalse);
      expect(controller.searchPattern, '(');
    });

    test('empty pattern is always treated as valid', () {
      controller.searchSet('');
      expect(controller.searchValid, isTrue);
      expect(controller.searchPattern, '');
    });

    test('searchClear resets pattern + validity', () {
      controller.searchSet('foo');
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.searchClear();
      expect(controller.searchPattern, '');
      expect(controller.searchValid, isTrue);
      expect(notifies, 1);
    });

    test('searchClear is a no-op when pattern empty and valid', () {
      // Fresh controller: pattern == '' and searchValid == true.
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.searchClear();
      expect(notifies, 0);
    });

    test('searchNext/searchPrev notify', () {
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.searchNext();
      controller.searchPrev();
      expect(notifies, 2);
    });

    test('scrollLines notifies after the engine await', () async {
      var notifies = 0;
      controller.addListener(() => notifies++);
      await controller.scrollLines(-3);
      expect(notifies, 1);
      expect(binding.scrollCalls, 1);
    });

    test('scrollToBottom always notifies (simple semantics, matches Step 3)',
        () async {
      var notifies = 0;
      controller.addListener(() => notifies++);
      await controller.scrollToBottom();
      expect(notifies, 1);
      expect(binding.scrollToBottomCalls, 1);
    });

    test('dispose drops the engine reference', () {
      final c = TerminalController()..attach(engine);
      expect(c.engine, same(engine));
      c.dispose();
      expect(c.engine, isNull);
      // The engine itself is still alive — controller does not own it.
      expect(engine.title.value, isNotNull);
    });
  });
}
