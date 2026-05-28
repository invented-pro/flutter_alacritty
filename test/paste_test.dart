import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/paste.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

void main() {
  test('raw utf8 when bracketed paste is off', () {
    expect(pasteBytes('hi', modeFlags: 0), utf8.encode('hi'));
  });

  test('wrapped in ESC[200~ / ESC[201~ when on', () {
    final out = pasteBytes('ab', modeFlags: kModeBracketedPaste);
    expect(out, [...'\x1b[200~'.codeUnits, ...'ab'.codeUnits, ...'\x1b[201~'.codeUnits]);
  });

  test('strips an embedded end marker (no break-out)', () {
    // The ESC byte is removed (so the leftover `[201~` characters cannot be
    // interpreted as the end marker — they're just plain text without ESC).
    // Matches alacritty event.rs:paste which replaces ['\x1b', '\x03'] only.
    final out = pasteBytes('a\x1b[201~b', modeFlags: kModeBracketedPaste);
    expect(out, [...'\x1b[200~'.codeUnits, ...'a[201~b'.codeUnits, ...'\x1b[201~'.codeUnits]);
  });

  test('strips all ESC bytes (alacritty parity) so embedded SGR cannot leak through', () {
    // A pasted snippet containing a colored ls output: "\x1b[34mdir\x1b[0m".
    // Stripping ESC removes the entire CSI sequence, leaving the visible text.
    final out = pasteBytes('\x1b[34mdir\x1b[0m', modeFlags: kModeBracketedPaste);
    expect(out, [...'\x1b[200~'.codeUnits, ...'[34mdir[0m'.codeUnits, ...'\x1b[201~'.codeUnits]);
  });

  test('strips Ctrl+C (0x03) — shells may incorrectly terminate bracketed paste on it', () {
    final out = pasteBytes('a\x03b', modeFlags: kModeBracketedPaste);
    expect(out, [...'\x1b[200~'.codeUnits, ...'ab'.codeUnits, ...'\x1b[201~'.codeUnits]);
  });

  test('non-bracketed mode is unchanged (raw bytes)', () {
    // No filtering in non-bracketed mode — the receiving program sees what the
    // user pasted (matches alacritty: non-bracketed paste only normalizes
    // newlines, not ESC/Ctrl-C).
    expect(pasteBytes('a\x1bb', modeFlags: 0), [0x61, 0x1b, 0x62]);
  });
}
