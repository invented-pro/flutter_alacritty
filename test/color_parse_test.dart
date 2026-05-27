import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/color_parse.dart';

void main() {
  test('parses #rrggbb to 0x00RRGGBB', () {
    expect(parseColor('#181818'), 0x181818);
    expect(parseColor('#CC0000'), 0xCC0000);
    expect(parseColor('#3a6ea5'), 0x3A6EA5);
  });
  test('parses #aarrggbb preserving alpha', () {
    expect(parseColor('#80ffffff'), 0x80FFFFFF);
  });
  test('parses 0x prefix', () {
    expect(parseColor('0xcc0000'), 0xCC0000);
    expect(parseColor('0XCC0000'), 0xCC0000);
  });
  test('returns null on malformed input', () {
    expect(parseColor('nope'), isNull);
    expect(parseColor('#xyz'), isNull);
    expect(parseColor('#12'), isNull);
    expect(parseColor('#1234567'), isNull);
    expect(parseColor(''), isNull);
  });
}
