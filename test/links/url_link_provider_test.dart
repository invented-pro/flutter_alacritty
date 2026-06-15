import 'package:flutter_alacritty/links/url_link_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final p = UrlLinkProvider();

  test('detects http/https/ftp/file URLs with correct ranges', () {
    final spans = p.scan('see https://x.io/p and file:///a/b done').toList();
    expect(spans.map((s) => s.payload),
        containsAll(['https://x.io/p', 'file:///a/b']));
    final url = spans.firstWhere((s) => s.payload == 'https://x.io/p');
    expect('see https://x.io/p and file:///a/b done'.substring(url.start, url.end),
        'https://x.io/p');
  });

  test('no scheme => no spans', () {
    expect(p.scan('just plain words here'), isEmpty);
  });

  test('URLs are always enabled (no validation)', () {
    final span = p.scan('https://x.io').single;
    expect(p.isEnabled(span), isTrue);
  });
}
