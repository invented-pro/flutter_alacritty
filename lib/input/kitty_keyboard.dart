import 'dart:typed_data';

import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// Kitty keyboard protocol (https://sw.kovidgoyal.net/kitty/keyboard-protocol/).
///
/// Adds two responsibilities to a terminal emulator that previously only
/// shipped xterm/VT100 key encoding:
///
///   1. **Advertise support.** When a running program queries the terminal
///      with the bare `CSI ? u` request, we must reply with `CSI ? <flags> u`
///      listing the flag bits we support. The program then enables the
///      features it wants by sending `CSI > <push> ; <pop> ; <changes> u`
///      and we update our local flag state. Without (1), programs like
///      opencode / Claude Code / Codex CLI never enable the protocol and
///      fall back to legacy encoding where `Shift+Enter` and `Enter` are
///      indistinguishable (`\r`).
///
///   2. **Encode special keys with modifiers.** When the program has
///      enabled flag 1 ("disambiguate escape codes"), keys that normally
///      carry no modifier subparameter — Enter, Tab, Backspace, Space,
///      the arrows, etc. — must be sent as `CSI <keycode> ; <mods> u`
///      instead of the legacy byte. The first byte is the Kitty keycode
///      (Unicode codepoint for printables, fixed values for functional
///      keys), the second is the modifier subparam
///      (`1 + shift + 2*alt + 4*ctrl + 8*super + 16*hyper + 32*meta`).
///
/// The parser in [processOutbound] scans PTY output for the query / push
/// sequences. Matched sequences are *consumed* (not forwarded to the
/// screen engine) and the response bytes are emitted on a stream the
/// caller drains into the PTY as if they were user input. Unmatched
/// bytes pass through untouched, so screen rendering is unaffected.
class KittyKeyboardProtocol {
  /// Bits we advertise as supported in response to `CSI ? u`.
  ///
  ///   bit 0 (0x01): disambiguate escape codes
  ///   bit 1 (0x02): report event types (press/repeat/release)
  ///   bit 2 (0x04): report alternate keys (shifted / alted variants)
  ///   bit 3 (0x08): report all keys as escape codes
  ///
  /// We support all four unconditionally; bit 3 only activates when the
  /// program explicitly pushes it (it changes every plain character into
  /// a CSI u sequence, which would break apps that don't speak the
  /// protocol).
  static const int advertisedFlags = 0x0F;

  int _flags = 0;

  /// Currently-enabled flag bits, as last pushed by the program.
  int get flags => _flags;

  /// `true` when the program has asked us to disambiguate escape codes
  /// (Kitty protocol flag 1). When set, [encodeKey] returns CSI u
  /// sequences for modified Enter/Tab/etc.
  bool get disambiguate => (_flags & 0x01) != 0;

  /// Apply a `CSI > push ; pop ; changes u` payload from the program.
  /// `push` bits are OR-ed into the flag state, `pop` bits are AND-NOT-ed
  /// out. Returns the echo bytes per the spec.
  /// Apply a `CSI > flags u` push from the app. Per the Kitty spec
  /// (https://sw.kovidgoyal.net/kitty/keyboard-protocol/) the format is
  /// `CSI > flags u` (one decimal integer = the new flag bitmask), or
  /// `CSI > flags; mode u` where the optional `mode` controls how the
  /// change is applied: 1 = replace (default), 2 = union (set listed
  /// bits, keep others), 3 = difference (clear listed bits, keep
  /// others). Both real alacritty and vte only read the first
  /// parameter; we do the same to stay compatible.
  ///
  /// Terminals do **not** echo the push back to the app — the app
  /// queries with `CSI ? u` if it wants to confirm the new state.
  /// Sending a 3-param echo (which the v0-draft of the protocol used
  /// before the spec settled on 1–2 params) confuses some apps into
  /// treating the echo as a *second* push, which can desync the
  /// per-app notion of which flags are active.
  void applyPush(int flags, {int mode = 1}) {
    switch (mode) {
      case 2:
        _flags = _flags | flags;
        break;
      case 3:
        _flags = _flags & ~flags;
        break;
      case 1:
      default:
        _flags = flags;
    }
  }

  /// Build the response to `CSI ? u` — `CSI ? <flags> u` with our
  /// advertised flag set.
  Uint8List encodeQueryResponse() => Uint8List.fromList(
      [0x1b, 0x5b, 0x3f, ...decimalDigits(advertisedFlags), 0x75]);

  // ── Outbound-byte parser ───────────────────────────────────────────
  //
  // Splits a chunk of PTY output into bytes that should still be sent
  // to the screen engine, and response bytes that should be written back
  // to the PTY as if the user had typed them. Maintains a small tail
  // buffer so a `CSI ? u` or `CSI > N;N;N u` that straddles a chunk
  // boundary is still recognized on the next call.

  final List<int> _tail = <int>[];

  /// Result of scanning a chunk: bytes to forward to `engine.feed(...)`
  /// and one or more response payloads to write back to the PTY via
  /// `engine.write(...)`.
  KittyParseResult processOutbound(Uint8List bytes) {
    final combined = _tail.isEmpty
        ? bytes
        : Uint8List.fromList(<int>[..._tail, ...bytes]);
    _tail.clear();

    final pass = <int>[];
    final responses = <Uint8List>[];

    var i = 0;
    while (i < combined.length) {
      // Scan for ESC [ that might start a kitty sequence.
      if (combined[i] != 0x1b) {
        pass.add(combined[i]);
        i++;
        continue;
      }
      if (i + 1 >= combined.length || combined[i + 1] != 0x5b /* '[' */) {
        pass.add(combined[i]);
        i++;
        continue;
      }
      // Need to see byte 2 to know if it's a kitty sequence.
      if (i + 2 >= combined.length) {
        break; // truncated — buffer from here
      }
      final c = combined[i + 2];
      if (c != 0x3f /* '?' */ && c != 0x3e /* '>' */) {
        // Not a kitty sequence — emit ESC [ and move on.
        pass.add(0x1b);
        pass.add(0x5b);
        i += 2;
        continue;
      }
      // Disambiguate from non-kitty CSI sequences that share the
      // `?` or `>` lead-in. The kitty query is the bare `CSI ? u`
      // with **no parameters** between `?` and `u`; anything like
      // `CSI ? 25 h` (DEC private mode set/reset — show/hide cursor,
      // mouse tracking, etc.) is a normal mode-set sequence and must
      // pass through to the screen engine untouched. For the `>` form
      // the kitty push payload is `CSI > digits(;digits)* u`; the
      // `>` is also used by DA1 (`CSI > c`), DECSCRL (`CSI > Ps;Ps
      // q`), etc., so demand a digit at offset 3 before attempting
      // to parse it as kitty.
      if (c == 0x3f /* '?' */) {
        // The only valid kitty form starting with `?` is the bare
        // `CSI ? u`. Anything else (digit, terminator, etc.) is a
        // normal DEC private mode sequence.
        if (i + 3 >= combined.length) {
          // Truncated — wait for the next chunk to know if it's kitty.
          break;
        }
        if (combined[i + 3] != 0x75 /* 'u' */) {
          pass.add(0x1b);
          pass.add(0x5b);
          i += 2;
          continue;
        }
      } else {
        // c == '>' — kitty push, DA1, DECSCRL, etc. Only enter the
        // kitty-push path when the byte after `>` is a digit (a
        // payload); bare `CSI > u` (no params) is malformed but
        // harmless, treat as a normal CSI sequence.
        if (i + 3 >= combined.length) {
          break; // truncated
        }
        final n = combined[i + 3];
        if (n != 0x75 /* 'u' */ && (n < 0x30 || n > 0x39) /* not a digit */) {
          pass.add(0x1b);
          pass.add(0x5b);
          i += 2;
          continue;
        }
        if (n == 0x75 /* bare 'CSI > u' with no params */) {
          pass.add(0x1b);
          pass.add(0x5b);
          i += 2;
          continue;
        }
      }
      // Try to parse the full sequence.
      final parsed = _tryParseKitty(combined, i);
      switch (parsed) {
        case _KittyMatch(:final consumed, :final response):
          responses.add(response);
          i += consumed;
          continue;
        case _KittySilent(:final consumed):
          // Kitty push — silently update internal flag state. No
          // response is sent back to the app.
          i += consumed;
          continue;
        case _KittyMalformed():
          // Bytes are enough to be sure this isn't a kitty sequence —
          // pass `ESC [` through, let the screen engine handle the
          // remainder of the CSI sequence, and keep scanning.
          pass.add(0x1b);
          pass.add(0x5b);
          i += 2;
          continue;
        case _KittyTruncated():
          // Bytes run out mid-payload — wait for the next chunk.
          break;
      }
      break;
    }

    // Whatever's left is an incomplete kitty prefix — buffer for next call.
    if (i < combined.length) {
      _tail.addAll(combined.sublist(i));
    }

    return KittyParseResult(
      passThrough: Uint8List.fromList(pass),
      responses: responses,
    );
  }

  /// Try to parse a kitty CSI sequence starting at [start].
  ///
  /// Returns one of:
  ///   * a `_KittyMatch` (consumed bytes + response payload to write
  ///     back to the PTY) when a complete query or push is found;
  ///   * a `_KittyTruncated` when the bytes run out mid-payload
  ///     (the caller should buffer and wait for the next chunk);
  ///   * a `_KittyMalformed` when the buffer has enough bytes to
  ///     prove this is **not** a kitty sequence (e.g. `CSI ? 25 h`,
  ///     `CSI > c`, `CSI > 1 u`) — the caller passes `ESC [` through
  ///     to the screen and keeps scanning past the rest of the CSI
  ///     sequence.
  _KittyParse _tryParseKitty(Uint8List buf, int start) {
    // Caller has verified buf[start]==0x1b and buf[start+1]==0x5b.
    final c = buf[start + 2];
    if (c == 0x3f /* '?' */) {
      // Query form: `CSI ? u` — no parameters.
      if (start + 4 > buf.length) return const _KittyTruncated();
      if (buf[start + 3] != 0x75 /* 'u' */) {
        return const _KittyMalformed();
      }
      return _KittyMatch(consumed: 4, response: encodeQueryResponse());
    }
    if (c == 0x3e /* '>' */) {
      // Push form: `CSI > flags [; mode] u`. Per the Kitty spec the
      // first parameter is the new flag bitmask; an optional second
      // parameter is the apply mode (1 = replace, 2 = union, 3 =
      // difference). Other params (if any) are ignored for forward
      // compatibility with the v0 3-param draft. We do NOT echo the
      // push back — alacritty doesn't, and apps that see an echo can
      // double-apply the change.
      final scan = _scanPushParams(buf, start + 3);
      switch (scan.status) {
        case _PushStatus.truncated:
          return const _KittyTruncated();
        case _PushStatus.malformed:
          return const _KittyMalformed();
        case _PushStatus.complete:
          applyPush(scan.flags, mode: scan.mode);
          return _KittySilent(consumed: scan.endIdx - start);
      }
    }
    return const _KittyMalformed();
  }

  /// Scan a kitty push `digits(;digits)? u` starting at [start] (the
  /// byte after `CSI > `). The first decimal integer is the new flag
  /// bitmask; the optional second integer (after a `;`) is the apply
  /// mode (1 = replace, 2 = union, 3 = difference). Anything else
  /// terminator-wise (`h`, `l`, `c`, `q`, …) means this isn't a
  /// kitty push — return malformed so the caller emits `ESC [` to the
  /// screen instead of starving.
  _PushScan _scanPushParams(Uint8List buf, int start) {
    var i = start;
    var sawDigit = false;
    var current = 0;
    var flags = 0;
    var mode = 1;
    var part = 0; // 0 = flags, 1 = mode
    while (i < buf.length) {
      final b = buf[i];
      if (b >= 0x30 && b <= 0x39) {
        current = current * 10 + (b - 0x30);
        sawDigit = true;
        i++;
        continue;
      }
      if (b == 0x3b /* ';' */) {
        if (!sawDigit) return const _PushScan.malformed();
        switch (part) {
          case 0:
            flags = current;
            part = 1;
          case 1:
            // Third (and beyond) params ignored — the v0 3-param
            // format (`push;pop;changes`) is no longer in the spec.
            mode = current;
            part = 2;
        }
        current = 0;
        sawDigit = false;
        i++;
        continue;
      }
      if (b == 0x75 /* 'u' */) {
        if (!sawDigit) return const _PushScan.malformed();
        switch (part) {
          case 0:
            flags = current;
          case 1:
            mode = current;
          case 2:
            // ignore
            break;
        }
        return _PushScan.complete(flags, mode, i + 1);
      }
      // Anything else (`h`, `l`, `c`, `q`, `;` after a non-digit, …)
      // — definitively not a kitty push payload.
      return const _PushScan.malformed();
    }
    // Ran off the end of the buffer mid-payload. The next chunk may
    // complete the push, so don't swallow it as malformed.
    return const _PushScan.truncated();
  }

  // ── Modifier encoding (shared with the key encoder) ───────────────

  /// Compute the Kitty modifier subparam from individual modifier
  /// booleans. Layout:
  ///   1 (base)
  /// + 1 if shift
  /// + 2 if alt
  /// + 4 if ctrl
  /// + 8 if super (a.k.a. cmd / win)
  /// + 16 if hyper
  /// + 32 if meta
  static int modifierParam({
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
    bool superPressed = false,
    bool hyper = false,
    bool meta = false,
  }) {
    var m = 1;
    if (shift) m += 1;
    if (alt) m += 2;
    if (ctrl) m += 4;
    if (superPressed) m += 8;
    if (hyper) m += 16;
    if (meta) m += 32;
    return m;
  }

  /// Encode a non-negative integer as its decimal ASCII digit bytes.
  static List<int> decimalDigits(int n) {
    if (n == 0) return const [0x30];
    final digits = <int>[];
    var v = n;
    while (v > 0) {
      digits.insert(0, 0x30 + (v % 10));
      v ~/= 10;
    }
    return digits;
  }
}

/// Internal sealed result of [_tryParseKitty]. One of four shapes:
///
///   * `_KittyMatch`         — a complete kitty query was recognised;
///                             `consumed` bytes have been removed
///                             from the buffer and the `response`
///                             must be written back to the PTY.
///   * `_KittySilent`        — a complete kitty push was recognised;
///                             `consumed` bytes removed, but the
///                             terminal does **not** echo the push
///                             back (alacritty and vte don't, and
///                             emitting an echo can cause apps to
///                             double-apply the change).
///   * `_KittyTruncated`     — bytes ran out mid-payload; buffer and
///                             retry on the next chunk.
///   * `_KittyMalformed`     — enough bytes were available to prove
///                             this is *not* a kitty sequence (e.g.
///                             `CSI ? 25 h`, `CSI > c`); emit `ESC [`
///                             through to the screen and keep
///                             scanning past the rest.
sealed class _KittyParse {
  const _KittyParse();
}

class _KittyMatch extends _KittyParse {
  const _KittyMatch({required this.consumed, required this.response});
  final int consumed;
  final Uint8List response;
}

class _KittySilent extends _KittyParse {
  const _KittySilent({required this.consumed});
  final int consumed;
}

class _KittyTruncated extends _KittyParse {
  const _KittyTruncated();
}

class _KittyMalformed extends _KittyParse {
  const _KittyMalformed();
}

/// Internal scan result of [_scanPushPayload].
enum _PushStatus { complete, truncated, malformed }

class _PushScan {
  const _PushScan.complete(this.flags, this.mode, this.endIdx)
      : status = _PushStatus.complete;
  const _PushScan.truncated()
      : flags = 0,
        mode = 1,
        endIdx = 0,
        status = _PushStatus.truncated;
  const _PushScan.malformed()
      : flags = 0,
        mode = 1,
        endIdx = 0,
        status = _PushStatus.malformed;

  final _PushStatus status;
  final int flags;
  final int mode;
  final int endIdx;
}

/// Result of [KittyKeyboardProtocol.processOutbound].
class KittyParseResult {
  const KittyParseResult({required this.passThrough, required this.responses});

  /// Bytes that did not match a kitty sequence — forward to the screen
  /// engine via `engine.feed(...)`.
  final Uint8List passThrough;

  /// Zero or more response payloads (each is a self-contained kitty
  /// reply). The caller should write each to the PTY in order via
  /// `engine.write(response)`.
  final List<Uint8List> responses;
}

// ── Key encoder ────────────────────────────────────────────────────
//
// Kitty keycodes for the functional keys we currently translate. Codes
// are taken from the Kitty keyboard-protocol spec
// (https://sw.kovidgoyal.net/kitty/keyboard-protocol/) — the cursor /
// page / home / end block uses 1..8, the editing keys use the PUA range
// 57348..57349, and F1..F12 use 57417..57428. Printables use their
// Unicode codepoint directly.
// `LogicalKeyboardKey` overrides `==`, so a `const` map keyed by it
// isn't allowed. Use a `final` instead — built once at library load.
final Map<LogicalKeyboardKey, int> _kKittyKeycodes = <LogicalKeyboardKey, int>{
  // Return / action keys.
  LogicalKeyboardKey.enter: 13,
  LogicalKeyboardKey.numpadEnter: 13,
  LogicalKeyboardKey.tab: 9,
  LogicalKeyboardKey.backspace: 127,
  LogicalKeyboardKey.escape: 27,
  // Cursor / navigation.
  LogicalKeyboardKey.arrowLeft: 1,
  LogicalKeyboardKey.arrowRight: 2,
  LogicalKeyboardKey.arrowUp: 3,
  LogicalKeyboardKey.arrowDown: 4,
  LogicalKeyboardKey.pageUp: 5,
  LogicalKeyboardKey.pageDown: 6,
  LogicalKeyboardKey.home: 7,
  LogicalKeyboardKey.end: 8,
  // Editing.
  LogicalKeyboardKey.insert: 57348,
  LogicalKeyboardKey.delete: 57349,
  // F-keys.
  LogicalKeyboardKey.f1: 57417,
  LogicalKeyboardKey.f2: 57418,
  LogicalKeyboardKey.f3: 57419,
  LogicalKeyboardKey.f4: 57420,
  LogicalKeyboardKey.f5: 57421,
  LogicalKeyboardKey.f6: 57422,
  LogicalKeyboardKey.f7: 57423,
  LogicalKeyboardKey.f8: 57424,
  LogicalKeyboardKey.f9: 57425,
  LogicalKeyboardKey.f10: 57426,
  LogicalKeyboardKey.f11: 57427,
  LogicalKeyboardKey.f12: 57428,
};

/// Encode a key event under the Kitty keyboard protocol, **only** for
/// the cases the legacy `encodeKey` doesn't already disambiguate. The
/// caller should try `encodeKeyWithKitty` first and fall back to
/// `encodeKey` when this returns null.
///
/// Behaviour matrix:
///
///   * `kitty.disambiguate == false` → null (legacy owns it).
///   * No modifier flags pressed → null (legacy byte is the same).
///   * Functional key (Enter, Tab, arrows, F-keys, ...) with any mods
///     → `CSI <keycode> ; <mods> u`.
///   * Printable + Ctrl (a..z or Ctrl-symbol) → `CSI <ctrl-byte> ; 5 u`
///     so apps can distinguish Ctrl+I from Tab, Ctrl+M from Enter, etc.
///   * Printable + Shift/Alt/Meta/Super → `CSI <codepoint> ; <mods> u`,
///     using the **shifted** character so the program can recover both
///     the logical key and the produced text in one sequence.
///
/// Per the spec, plain (unmodified) keys keep their legacy byte under
/// flag 1 — only modified keys change format. That matches what
/// opencode / Claude Code / Codex CLI expect: Shift+Enter shows up as
/// a distinct event, plain Enter still arrives as `\r`.
Uint8List? encodeKeyWithKitty(
  LogicalKeyboardKey key,
  String? character, {
  required KittyKeyboardProtocol kitty,
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
  bool meta = false,
  bool superPressed = false,
}) {
  if (!kitty.disambiguate) return null;
  if (!shift && !alt && !ctrl && !meta && !superPressed) return null;

  final mods = KittyKeyboardProtocol.modifierParam(
    shift: shift,
    alt: alt,
    ctrl: ctrl,
    superPressed: superPressed,
    meta: meta,
  );

  // 1. Functional key with a known Kitty keycode.
  final keycode = _kKittyKeycodes[key];
  if (keycode != null) {
    return _csiU(keycode, mods);
  }

  // 2. Ctrl + letter → keycode is the Ctrl control byte (1..26). Same
  // for Ctrl + a few non-letter symbols that produce stable control
  // bytes (matching the legacy encoder's `if (ctrl)` block).
  if (ctrl && !shift && !alt && !meta && !superPressed) {
    final ch = (character != null && character.length == 1)
        ? character
        : (key.keyLabel.length == 1 ? key.keyLabel : null);
    if (ch != null) {
      final c = ch.toLowerCase().codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7a) return _csiU(c - 0x60, mods); // a..z
      switch (ch) {
        case ' ':
          return _csiU(0x00, mods);
        case '[':
          return _csiU(0x1b, mods);
        case '\\':
          return _csiU(0x1c, mods);
        case ']':
          return _csiU(0x1d, mods);
        case '^':
          return _csiU(0x1e, mods);
        case '_':
        case '/':
          return _csiU(0x1f, mods);
      }
    }
    if (key == LogicalKeyboardKey.space) return _csiU(0x00, mods);
  }

  // 3. Printable with a non-Ctrl modifier — encode the produced
  // (shifted) character. When Shift is held, Flutter's `event.character`
  // already carries the shifted glyph ('A' for Shift+a).
  if (character != null && character.isNotEmpty && !ctrl) {
    // Take the first code unit only — CSI u keys are scalar, so
    // multi-codepoint graphemes (emoji, combining marks) fall back to
    // legacy encoding. Flag 8 (report all keys) would handle those.
    if (character.length == 1) {
      return _csiU(character.codeUnitAt(0), mods);
    }
  }

  // Anything else — Space without a known mapping, Hyper, or unknown
  // keys with modifiers — let the legacy encoder handle it.
  return null;
}

Uint8List _csiU(int keycode, int mods) => Uint8List.fromList([
      0x1b, 0x5b,
      ...KittyKeyboardProtocol.decimalDigits(keycode), 0x3b,
      ...KittyKeyboardProtocol.decimalDigits(mods), 0x75,
    ]);