import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/ime_key_routing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => ImeKeyRouting.setDeferUncomposedPrintableOverride(null));

  group('shouldDeferPrintableToTextInput', () {
    test('not attached → never defer', () {
      for (final p in TargetPlatform.values) {
        expect(
          ImeKeyRouting.shouldDeferPrintableToTextInput(
            imeAttached: false,
            imeComposing: true,
            platform: p,
          ),
          isFalse,
          reason: '$p',
        );
      }
    });

    test('composing → defer on all platforms', () {
      for (final p in TargetPlatform.values) {
        expect(
          ImeKeyRouting.shouldDeferPrintableToTextInput(
            imeAttached: true,
            imeComposing: true,
            platform: p,
          ),
          isTrue,
          reason: '$p',
        );
      }
    });

    test('Linux attached, not composing → encodeKey path', () {
      expect(
        ImeKeyRouting.shouldDeferPrintableToTextInput(
          imeAttached: true,
          imeComposing: false,
          platform: TargetPlatform.linux,
        ),
        isFalse,
      );
    });

    test('macOS/Windows attached, not composing → defer to TextInput', () {
      for (final p in [TargetPlatform.macOS, TargetPlatform.windows]) {
        expect(
          ImeKeyRouting.shouldDeferPrintableToTextInput(
            imeAttached: true,
            imeComposing: false,
            platform: p,
          ),
          isTrue,
          reason: '$p',
        );
      }
    });
  });

  group('isDeferrablePrintableKeyEvent', () {
    test('Backspace is never deferrable even with a character payload', () {
      final hw = HardwareKeyboard.instance;
      final event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.backspace,
        logicalKey: LogicalKeyboardKey.backspace,
        character: '\x7f',
        timeStamp: Duration.zero,
      );
      expect(ImeKeyRouting.isDeferrablePrintableKeyEvent(event, hw), isFalse);
    });

    test('letter a is deferrable without modifiers', () {
      final hw = HardwareKeyboard.instance;
      final event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      );
      expect(ImeKeyRouting.isDeferrablePrintableKeyEvent(event, hw), isTrue);
    });
  });

  test('policy override hook', () {
    ImeKeyRouting.setDeferUncomposedPrintableOverride((_) => true);
    expect(
      ImeKeyRouting.deferUncomposedPrintableOn(TargetPlatform.linux),
      isTrue,
    );
    ImeKeyRouting.setDeferUncomposedPrintableOverride(null);
    expect(
      ImeKeyRouting.deferUncomposedPrintableOn(TargetPlatform.linux),
      isFalse,
    );
  });
}
