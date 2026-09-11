import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/ime_session.dart';

void main() {
  void noopBackspace() {}

  // ImeSession works without the platform binding for its parsing logic.
  group('updateEditingValue', () {
    test('preedit-only value fires onPreeditChanged with composing substring', () {
      String? preedit = '__unset__';
      var commits = 0;
      final s = ImeSession(
        onCommit: (_) => commits++,
        onPreeditChanged: (p) => preedit = p,
        onBackspace: noopBackspace,
      );
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      expect(preedit, 'ni');
      expect(commits, 0);
    });

    test('committed value fires onCommit once and clears preedit', () {
      final commits = <String>[];
      String? preedit = '__unset__';
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (p) => preedit = p,
        onBackspace: noopBackspace,
      );
      s.updateEditingValue(const TextEditingValue(text: '你好'));
      expect(commits, ['你好']);
      expect(preedit, isNull);
    });

    test('empty value (no text, no composing) clears preedit without commit', () {
      final commits = <String>[];
      var backspaces = 0;
      String? preedit = 'stale';
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (p) => preedit = p,
        onBackspace: () => backspaces++,
      );
      s.updateEditingValue(TextEditingValue.empty);
      expect(commits, isEmpty);
      expect(backspaces, 0);
      expect(preedit, isNull);
    });

    test('shrinking sentinel fires onBackspace (TextInput delete path)', () {
      var backspaces = 0;
      final s = ImeSession(
        onCommit: (_) {},
        onPreeditChanged: (_) {},
        onBackspace: () => backspaces++,
      );
      s.updateEditingValue(
        const TextEditingValue(
          text: ' ',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(backspaces, 1);
    });

    test('preedit then commit produces one onCommit and clears preedit', () {
      final preedits = <String?>[];
      final commits = <String>[];
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: preedits.add,
        onBackspace: noopBackspace,
      );
      s.updateEditingValue(
        const TextEditingValue(text: 'n', composing: TextRange(start: 0, end: 1)),
      );
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      s.updateEditingValue(const TextEditingValue(text: '你'));
      expect(preedits, ['n', 'ni', null]);
      expect(commits, ['你']);
    });

    test('isComposing true only during active composing range', () {
      final s = ImeSession(
        onCommit: (_) {},
        onPreeditChanged: (_) {},
        onBackspace: noopBackspace,
      );
      expect(s.isComposing, isFalse);
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      expect(s.isComposing, isTrue);
      s.updateEditingValue(const TextEditingValue(text: '你'));
      expect(s.isComposing, isFalse);
    });
  });

  group('consumption frontier (no mid-session field truncation)', () {
    // Regression: the old protocol reset the platform field to the sentinel
    // after every commit. Belief-tracking IMEs (segmented pinyin, Sogou,
    // ...) kept issuing setMarkedText with cursor offsets derived from the
    // pre-reset contents; the engine combined those with the shortened text
    // and emitted a selection beyond the text length, which the framework
    // drops ("Range start N is out of text of length M") — permanently
    // killing IME delivery for the session.
    test('segmented pinyin: commit then immediate next preedit keeps flowing', () {
      final preedits = <String?>[];
      final commits = <String>[];
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: preedits.add,
        onBackspace: noopBackspace,
      );
      // Long preedit.
      s.updateEditingValue(const TextEditingValue(
          text: '  dianbi', composing: TextRange(start: 2, end: 8)));
      // Candidate commit replaces the composing range; next syllable's
      // preedit starts immediately, offsets by the committed text.
      s.updateEditingValue(const TextEditingValue(
          text: '  点',
          selection: TextSelection.collapsed(offset: 3)));
      s.updateEditingValue(const TextEditingValue(
          text: '  点吧', composing: TextRange(start: 3, end: 4)));
      s.updateEditingValue(const TextEditingValue(
          text: '  点吧',
          selection: TextSelection.collapsed(offset: 5)));
      expect(commits, ['点', '吧']);
      expect(preedits, ['dianbi', null, '吧', null]);
    });

    test('consecutive commits report only the delta beyond the frontier', () {
      final commits = <String>[];
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (_) {},
        onBackspace: noopBackspace,
      );
      s.updateEditingValue(
          const TextEditingValue(text: '  你', selection: TextSelection.collapsed(offset: 3)));
      s.updateEditingValue(
          const TextEditingValue(text: '  你好', selection: TextSelection.collapsed(offset: 4)));
      expect(commits, ['你', '好']);
    });

    test('shrinking into committed text fires one backspace per update', () {
      var backspaces = 0;
      final s = ImeSession(
        onCommit: (_) {},
        onPreeditChanged: (_) {},
        onBackspace: () => backspaces++,
      );
      s.updateEditingValue(
          const TextEditingValue(text: '  你', selection: TextSelection.collapsed(offset: 3)));
      expect(backspaces, 0);
      s.updateEditingValue(
          const TextEditingValue(text: '  ', selection: TextSelection.collapsed(offset: 2)));
      expect(backspaces, 1);
    });

    test('deletion into the sentinel restores it for the next backspace', () {
      var backspaces = 0;
      final commits = <String>[];
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (_) {},
        onBackspace: () => backspaces++,
      );
      s.updateEditingValue(
          const TextEditingValue(text: ' ', selection: TextSelection.collapsed(offset: 1)));
      expect(backspaces, 1);
      s.updateEditingValue(
          const TextEditingValue(text: ' ', selection: TextSelection.collapsed(offset: 1)));
      expect(backspaces, 2);
      // After the repair the frontier is back at the sentinel: a normal
      // commit works again.
      s.updateEditingValue(
          const TextEditingValue(text: '  好', selection: TextSelection.collapsed(offset: 3)));
      expect(commits, ['好']);
    });

    test('wholesale replace commits full text and repairs the frontier', () {
      final commits = <String>[];
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (_) {},
        onBackspace: noopBackspace,
      );
      s.updateEditingValue(const TextEditingValue(
          text: '的', selection: TextSelection.collapsed(offset: 1)));
      expect(commits, ['的']);
      s.updateEditingValue(
          const TextEditingValue(text: '  好', selection: TextSelection.collapsed(offset: 3)));
      expect(commits, ['的', '好']);
    });
  });

  test('performPrivateCommand deleteBackward fires onBackspace', () {
    var backspaces = 0;
    final s = ImeSession(
      onCommit: (_) {},
      onPreeditChanged: (_) {},
      onBackspace: () => backspaces++,
    );
    s.performPrivateCommand('deleteBackward', const {});
    expect(backspaces, 1);
  });

  test('connectionClosed triggers detach (preedit cleared, no double-fire)', () {
    String? preedit = 'stale';
    final s = ImeSession(
      onCommit: (_) {},
      onPreeditChanged: (p) => preedit = p,
      onBackspace: noopBackspace,
    );
    s.connectionClosed();
    expect(preedit, isNull);
    expect(s.isAttached, isFalse);
  });

  test('platform-side connectionClosed mid-composition resets isComposing + clears preedit', () {
    final preedits = <String?>[];
    final commits = <String>[];
    final s = ImeSession(
      onCommit: commits.add,
      onPreeditChanged: preedits.add,
      onBackspace: noopBackspace,
    );
    s.updateEditingValue(
      const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
    );
    expect(s.isComposing, isTrue);
    s.connectionClosed();
    expect(s.isComposing, isFalse);
    expect(s.isAttached, isFalse);
    expect(preedits.last, isNull);
    expect(commits, isEmpty);
  });

  test('detach when never attached is a safe no-op', () {
    final s = ImeSession(
      onCommit: (_) {},
      onPreeditChanged: (_) {},
      onBackspace: noopBackspace,
    );
    expect(() => s.detach(), returnsNormally);
    expect(s.isAttached, isFalse);
  });
}
