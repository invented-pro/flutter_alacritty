import 'dart:io';

import 'package:flutter/foundation.dart';

import 'terminal_config.dart';

/// App-level glue that turns an on-disk TOML file into a [TerminalConfig].
/// The only component that knows the config path; a library consumer skips it
/// and builds [TerminalConfig] directly. All failures fall back to defaults.
class ConfigLoader {
  /// `$XDG_CONFIG_HOME/flutter_alacritty/flutter_alacritty.toml`, else
  /// `$HOME/.config/...`. Null when neither env var is set.
  static String? resolveConfigPath([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final xdg = e['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return '$xdg/flutter_alacritty/flutter_alacritty.toml';
    }
    final home = e['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home/.config/flutter_alacritty/flutter_alacritty.toml';
    }
    return null;
  }

  /// Read + parse [path]. Returns defaults if [path] is null, the file is
  /// absent, or parsing throws.
  static TerminalConfig loadFile(String? path) {
    if (path == null) return TerminalConfig.defaults();
    final file = File(path);
    if (!file.existsSync()) return TerminalConfig.defaults();
    try {
      return TerminalConfig.fromTomlString(file.readAsStringSync());
    } catch (e) {
      debugPrint('config: failed to load $path ($e); using defaults');
      return TerminalConfig.defaults();
    }
  }

  /// Resolve the default path and load it (used by main()).
  static TerminalConfig load() => loadFile(resolveConfigPath());
}
