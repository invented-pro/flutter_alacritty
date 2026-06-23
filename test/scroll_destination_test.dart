import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/scroll_destination.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

void main() {
  test('mouse mode routes to program', () {
    expect(
      scrollDestination(
        modeFlags: kModeMouseClick,
        shiftHeld: false,
      ),
      ScrollDestination.program,
    );
  });

  test('shift routes to history even in alt screen', () {
    expect(
      scrollDestination(
        modeFlags: kModeAltScreen | kModeAlternateScroll,
        shiftHeld: true,
      ),
      ScrollDestination.history,
    );
  });

  test('alt + DEC 1007 routes to program', () {
    expect(
      scrollDestination(
        modeFlags: kModeAltScreen | kModeAlternateScroll,
        shiftHeld: false,
      ),
      ScrollDestination.program,
    );
  });

  test('alt without DEC 1007 routes to history', () {
    expect(
      scrollDestination(
        modeFlags: kModeAltScreen,
        shiftHeld: false,
      ),
      ScrollDestination.history,
    );
  });
}
