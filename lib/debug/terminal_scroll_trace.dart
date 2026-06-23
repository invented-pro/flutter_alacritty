import 'package:flutter/foundation.dart';

/// Scroll pipeline tracing. Enable any of:
/// - `flutter run --dart-define=TERMINAL_SCROLL_TRACE=1`
/// - `TerminalScrollTrace.enabled = true` in host `main()`
class TerminalScrollTrace {
  TerminalScrollTrace._();

  static bool enabled = bool.fromEnvironment(
    'TERMINAL_SCROLL_TRACE',
    defaultValue: false,
  );

  static int _seq = 0;

  static void log(String component, String message) {
    if (!enabled) return;
    final n = ++_seq;
    debugPrint('[scroll#$n $component] $message');
  }

  static String pos({
    required int displayOffset,
    required double scrollFraction,
    required int historySize,
  }) =>
      'off=$displayOffset frac=${scrollFraction.toStringAsFixed(3)} '
      'pos=${(displayOffset + scrollFraction).toStringAsFixed(3)} hist=$historySize';
}
