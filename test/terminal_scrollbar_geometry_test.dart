import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/example/terminal_scrollbar_geometry.dart';

void main() {
  group('TerminalScrollbarGeometry', () {
    test('thumb fraction matches viewport / total content', () {
      const geom = TerminalScrollbarGeometry(
        historySize: 100,
        viewportRows: 24,
        scrollOffsetLines: 0,
        trackHeight: 240,
      );
      expect(geom.thumbFraction, closeTo(24 / 124, 1e-9));
      expect(geom.thumbHeight, closeTo(240 * 24 / 124, 1e-9));
    });

    test('position at live bottom is 1.0, at top of history is 0.0', () {
      const bottom = TerminalScrollbarGeometry(
        historySize: 50,
        viewportRows: 24,
        scrollOffsetLines: 0,
        trackHeight: 200,
      );
      expect(bottom.positionFraction, 1.0);

      const top = TerminalScrollbarGeometry(
        historySize: 50,
        viewportRows: 24,
        scrollOffsetLines: 50,
        trackHeight: 200,
      );
      expect(top.positionFraction, 0.0);
    });

    test('partial history uses live history_size not config cap', () {
      const geom = TerminalScrollbarGeometry(
        historySize: 30,
        viewportRows: 24,
        scrollOffsetLines: 15,
        trackHeight: 200,
      );
      expect(geom.positionFraction, closeTo(0.5, 1e-9));
      expect(geom.scrollOffsetForFraction(0.5), 15);
    });

    test('track click maps through usable range with thumb height', () {
      const trackHeight = 200.0;
      const thumbHeight = 40.0;
      expect(
        TerminalScrollbarGeometry.fractionFromTrackDy(
          localDy: trackHeight - thumbHeight / 2,
          trackHeight: trackHeight,
          thumbHeight: thumbHeight,
        ),
        0.0,
      );
      expect(
        TerminalScrollbarGeometry.fractionFromTrackDy(
          localDy: thumbHeight / 2,
          trackHeight: trackHeight,
          thumbHeight: thumbHeight,
        ),
        1.0,
      );
    });

    test('edge snap detects top and bottom', () {
      const geom = TerminalScrollbarGeometry(
        historySize: 100,
        viewportRows: 24,
        scrollOffsetLines: 0,
        trackHeight: 200,
      );
      expect(geom.isNearBottom(0), isTrue);
      expect(geom.isNearBottom(0.4), isTrue);
      expect(geom.isNearBottom(2), isFalse);
      expect(geom.isNearTop(100), isTrue);
      expect(geom.isNearTop(99.6), isTrue);
      expect(geom.isNearTop(50), isFalse);
    });

    test('hidden when no scrollback', () {
      const geom = TerminalScrollbarGeometry(
        historySize: 0,
        viewportRows: 24,
        scrollOffsetLines: 0,
        trackHeight: 200,
      );
      expect(geom.visible, isFalse);
    });
  });
}
