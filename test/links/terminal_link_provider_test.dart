import 'package:flutter_alacritty/links/terminal_link_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubProvider extends TerminalLinkProvider {
  final Set<String> enabled = {};
  @override
  Iterable<LinkSpan> scan(String lineText) =>
      lineText.contains('X') ? [const LinkSpan(start: 0, end: 1, payload: 'X')] : const [];
  @override
  bool isEnabled(LinkSpan span) => enabled.contains(span.payload);
  void confirm(String p) {
    enabled.add(p);
    notifyListeners();
  }
}

void main() {
  test('LinkSpan holds range + payload', () {
    const s = LinkSpan(start: 2, end: 5, payload: 'a/b.dart');
    expect(s.start, 2);
    expect(s.end, 5);
    expect(s.payload, 'a/b.dart');
    expect(s.contains(3), isTrue);
    expect(s.contains(5), isFalse); // half-open [start, end)
  });

  test('provider scan + isEnabled gate, notifies on confirm', () {
    final p = _StubProvider();
    final span = p.scan('aXb').single;
    expect(p.isEnabled(span), isFalse);
    var notified = 0;
    p.addListener(() => notified++);
    p.confirm('X');
    expect(notified, 1);
    expect(p.isEnabled(span), isTrue);
  });
}
