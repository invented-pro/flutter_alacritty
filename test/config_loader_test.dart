import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/config_loader.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cfg2f'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('loadFile parses a valid file', () {
    final f = File('${tmp.path}/c.toml')
      ..writeAsStringSync('[font]\nsize = 19.0\n[colors.primary]\nbackground = "#123456"\n');
    final c = ConfigLoader.loadFile(f.path);
    expect(c.font.size, 19.0);
    expect(c.colors.background, 0x123456);
  });

  test('missing file returns defaults', () {
    final c = ConfigLoader.loadFile('${tmp.path}/nope.toml');
    expect(c.font.size, 14.0);
    expect(c.colors.background, 0x181818);
  });

  test('null path returns defaults', () {
    final c = ConfigLoader.loadFile(null);
    expect(c.font.size, 14.0);
  });

  test('broken TOML returns full defaults (no throw)', () {
    final f = File('${tmp.path}/bad.toml')..writeAsStringSync('this is = = not toml [[[');
    final c = ConfigLoader.loadFile(f.path);
    expect(c.font.size, 14.0);
    expect(c.colors.background, 0x181818);
  });

  test('resolveConfigPath prefers XDG_CONFIG_HOME', () {
    expect(
      ConfigLoader.resolveConfigPath({'XDG_CONFIG_HOME': '/xdg', 'HOME': '/home/u'}),
      '/xdg/flutter_alacritty/flutter_alacritty.toml',
    );
    expect(
      ConfigLoader.resolveConfigPath({'HOME': '/home/u'}),
      '/home/u/.config/flutter_alacritty/flutter_alacritty.toml',
    );
    expect(ConfigLoader.resolveConfigPath({}), isNull);
  });
}
