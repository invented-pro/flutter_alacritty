import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/kitty_keyboard.dart';

/// Tests for [encodeKeyWithKitty] — the Kitty-protocol branch of the
/// key encoder that flutter_alacritty's `_onKeyFallback` consults first
/// when `kitty.disambiguate` (flag 1) is active.
///
/// Policy under test:
///   * Ctrl+I / Ctrl+M / Ctrl+[ / Ctrl+Space → CSI-u (legacy byte
///     collides with another key, app needs disambiguation).
///   * Every other Ctrl+letter (Ctrl+P, Ctrl+R, Ctrl+T, …) → falls
///     through to `encodeKey`, which emits the unique legacy byte
///     (0x10, 0x12, 0x14, …). Apps that bind on the legacy byte
///     (opencode's command panel matching on `\x10`, etc.) keep working
///     exactly as under a stock alacritty.
///   * The `mods` field on emitted CSI-u sequences carries the *full*
///     modifier mask, so Ctrl+Shift+I and Ctrl+I arrive as distinct
///     events for apps that bind on the CSI-u form.
void main() {
  Uint8List csiu(String s) => Uint8List.fromList(utf8.encode(s));

  /// A kitty instance with flag 1 ("disambiguate escape codes") pushed,
  /// which is the canonical state once an app like opencode opts in.
  KittyKeyboardProtocol kittyDisambiguate() {
    final k = KittyKeyboardProtocol();
    k.applyPush(1);
    return k;
  }

  group('Ambiguous Ctrl+letter — emitted as CSI-u so the app can '
      'disambiguate from the colliding key', () {
    final kitty = kittyDisambiguate();

    test('Ctrl+I → CSI 9;5 u (disambiguated from Tab)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyI, 'i',
            kitty: kitty, ctrl: true),
        equals(csiu('\x1b[9;5u')),
      );
    });

    test('Ctrl+Shift+I → CSI 9;6 u (shift included in mods)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyI, 'I',
            kitty: kitty, ctrl: true, shift: true),
        equals(csiu('\x1b[9;6u')),
      );
    });

    test('Ctrl+Alt+I → CSI 9;7 u', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyI, 'i',
            kitty: kitty, ctrl: true, alt: true),
        equals(csiu('\x1b[9;7u')),
      );
    });

    test('Ctrl+M → CSI 13;5 u (disambiguated from Enter)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyM, 'm',
            kitty: kitty, ctrl: true),
        equals(csiu('\x1b[13;5u')),
      );
    });

    test('Ctrl+Shift+M → CSI 13;6 u', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyM, 'M',
            kitty: kitty, ctrl: true, shift: true),
        equals(csiu('\x1b[13;6u')),
      );
    });

    test('Ctrl+[ → CSI 27;5 u (disambiguated from Escape)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.bracketLeft, '[',
            kitty: kitty, ctrl: true),
        equals(csiu('\x1b[27;5u')),
      );
    });

    test('Ctrl+Shift+[ → CSI 27;6 u', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.bracketLeft, '[',
            kitty: kitty, ctrl: true, shift: true),
        equals(csiu('\x1b[27;6u')),
      );
    });

    test('Ctrl+Space → CSI 0;5 u (disambiguated from NUL)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.space, ' ',
            kitty: kitty, ctrl: true),
        equals(csiu('\x1b[0;5u')),
      );
    });

    test('Ctrl+Space → CSI 0;5 u even when character is null', () {
      // Windows sometimes delivers character = null for Space; the
      // disambiguation must still fire.
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.space, null,
            kitty: kitty, ctrl: true),
        equals(csiu('\x1b[0;5u')),
      );
    });
  });

  group('Non-ambiguous Ctrl+letter — falls through to legacy byte', () {
    final kitty = kittyDisambiguate();

    test('Ctrl+P → null (encodeKey emits \\x10)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'p',
            kitty: kitty, ctrl: true),
        isNull,
      );
    });

    test('Ctrl+Shift+P → null (encodeKey still emits \\x10)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'P',
            kitty: kitty, ctrl: true, shift: true),
        isNull,
      );
    });

    test('Ctrl+Alt+P → null', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'p',
            kitty: kitty, ctrl: true, alt: true),
        isNull,
      );
    });

    test('Ctrl+Meta+P → null', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'p',
            kitty: kitty, ctrl: true, meta: true),
        isNull,
      );
    });

    test('Ctrl+Super+P → null', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'p',
            kitty: kitty, ctrl: true, superPressed: true),
        isNull,
      );
    });

    test('Ctrl+Shift+Alt+P → null', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'P',
            kitty: kitty, ctrl: true, shift: true, alt: true),
        isNull,
      );
    });

    test('Ctrl+R → null (encodeKey emits \\x12)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyR, 'r',
            kitty: kitty, ctrl: true),
        isNull,
      );
    });

    test('Ctrl+Shift+R → null', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyR, 'R',
            kitty: kitty, ctrl: true, shift: true),
        isNull,
      );
    });

    test('Ctrl+T → null (encodeKey emits \\x14)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyT, 't',
            kitty: kitty, ctrl: true),
        isNull,
      );
    });

    test('Ctrl+N → null (encodeKey emits \\x0E)', () {
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyN, 'n',
            kitty: kitty, ctrl: true),
        isNull,
      );
    });
  });

  group('Guard rails', () {
    test('kitty.disambiguate == false → null for Ctrl+P (legacy owns it)',
        () {
      final off = KittyKeyboardProtocol();
      expect(off.disambiguate, isFalse);
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'p',
            kitty: off, ctrl: true),
        isNull,
      );
    });

    test('no modifier pressed → null (plain printable is still legacy)',
        () {
      final kitty = kittyDisambiguate();
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'p', kitty: kitty),
        isNull,
      );
    });

    test('Shift only (no Ctrl) → CSI 80;2 u (codepoint of P)', () {
      final kitty = kittyDisambiguate();
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'P',
            kitty: kitty, shift: true),
        equals(csiu('\x1b[80;2u')),
      );
    });

    test('Alt only (no Ctrl) → CSI 112;3 u (codepoint of p, mods incl. alt)',
        () {
      final kitty = kittyDisambiguate();
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.keyP, 'p',
            kitty: kitty, alt: true),
        equals(csiu('\x1b[112;3u')),
      );
    });

    test('Enter (functional key) → CSI 13;5 u under Ctrl', () {
      final kitty = kittyDisambiguate();
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.enter, null,
            kitty: kitty, ctrl: true),
        equals(csiu('\x1b[13;5u')),
      );
    });

    test('Tab (functional key) → CSI 9;5 u under Ctrl+Shift '
        '(disambiguated from Ctrl+I)', () {
      final kitty = kittyDisambiguate();
      expect(
        encodeKeyWithKitty(LogicalKeyboardKey.tab, null,
            kitty: kitty, ctrl: true, shift: true),
        equals(csiu('\x1b[9;6u')),
      );
    });
  });
}