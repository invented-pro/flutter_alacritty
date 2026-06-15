import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

// Puts non-space text on row 0 so the painter actually rasterizes glyphs
// (spaces are skipped by the painter, so a blank grid never fills the cache).
class _TextFakeBinding extends FakeBinding {
  _TextFakeBinding(this.rowText);
  final String rowText;

  GridUpdate _snapshot() {
    const cols = 80, rows = 24;
    final codepoints = Int32List(cols)..fillRange(0, cols, 32);
    for (var i = 0; i < rowText.length && i < cols; i++) {
      codepoints[i] = rowText.codeUnitAt(i);
    }
    LineCells line(int i, Int32List cps) => LineCells(
          line: i,
          codepoints: cps,
          fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
          bg: Int32List(cols)..fillRange(0, cols, 0x181818),
          flags: Uint16List(cols),
          hyperlinkId: Int32List(cols),
        );
    return GridUpdate(
      full: true,
      rows: rows,
      columns: cols,
      lines: [
        line(0, codepoints),
        for (var i = 1; i < rows; i++)
          line(i, Int32List(cols)..fillRange(0, cols, 32)),
      ],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      modeFlags: modeFlags,
    );
  }

  @override
  GridUpdate fullSnapshotSearched() => _snapshot();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'engine swap on a stable TerminalView preserves the glyph cache '
      '(no remount, no rebuild)', (tester) async {
    final binding1 = _TextFakeBinding('HELLO_WORLD_GLYPHS');
    final engine1 = TerminalEngine.fromBinding(
      binding1,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    final binding2 = _TextFakeBinding('SECOND_ENGINE_TEXT');
    final engine2 = TerminalEngine.fromBinding(
      binding2,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    addTearDown(() {
      engine1.dispose();
      engine2.dispose();
    });

    final engineNotifier = ValueNotifier<TerminalEngine>(engine1);
    addTearDown(engineNotifier.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<TerminalEngine>(
          valueListenable: engineNotifier,
          builder: (context, engine, _) => TerminalView(engine),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Prime engine1's grid from fullSnapshotSearched() via a throwaway click,
    // then pump so the painter rasterizes row-0 glyphs into the cache.
    final topLeft = tester.getTopLeft(find.byType(CustomPaint).first);
    final g = await tester.startGesture(topLeft + const Offset(2, 2));
    await g.up();
    await tester.pump();

    final stateBefore = tester.state<TerminalViewState>(find.byType(TerminalView));
    final cacheBefore = stateBefore.glyphCacheForTest;
    final lenBefore = cacheBefore.length;
    expect(lenBefore, greaterThan(0),
        reason: 'painting row-0 text should populate the glyph cache');

    // SWAP the engine — the host changes only the engine prop on the same view.
    engineNotifier.value = engine2;
    await tester.pump();

    final stateAfter = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(identical(stateAfter, stateBefore), isTrue,
        reason: 'engine swap must reuse the State (no remount)');
    expect(identical(stateAfter.glyphCacheForTest, cacheBefore), isTrue,
        reason: 'engine swap must NOT rebuild the GlyphCache — this warm cache '
            'is what prevents partial-text on member/tab switch');
    expect(stateAfter.glyphCacheForTest.length, greaterThanOrEqualTo(lenBefore),
        reason: 'previously rasterized glyphs must still be cached after swap');
  });
}
