import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/render/glyph_atlas.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'engine swap on a stable TerminalView preserves the glyph cache '
      '(no remount, no rebuild)', (tester) async {
    final binding1 = TextFakeBinding('HELLO_WORLD_GLYPHS');
    final engine1 = TerminalEngine.fromBinding(
      binding1,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    final binding2 = TextFakeBinding('SECOND_ENGINE_TEXT');
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

    // A throwaway mouse click triggers the selection refresh that primes the
    // grid from fullSnapshotSearched(); the subsequent pump rasterizes row-0
    // glyphs into the cache.
    final topLeft = tester.getTopLeft(find.byType(CustomPaint).first);
    final g = await tester.startGesture(
      topLeft + const Offset(2, 2),
      kind: PointerDeviceKind.mouse,
    );
    await g.up();
    await tester.pump();
    await tester.pump();

    final stateBefore = tester.state<TerminalViewState>(find.byType(TerminalView));
    final atlasBefore = stateBefore.atlasForTest;
    expect(atlasBefore?.image, isNotNull,
        reason: 'painting row-0 text should build the glyph atlas');

    // SWAP the engine — the host changes only the engine prop on the same view.
    engineNotifier.value = engine2;
    await tester.pump();

    final stateAfter = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(identical(stateAfter, stateBefore), isTrue,
        reason: 'engine swap must reuse the State (no remount)');
    expect(identical(stateAfter.atlasForTest, atlasBefore), isTrue,
        reason: 'engine swap must NOT rebuild the GlyphAtlas — this warm atlas '
            'is what prevents partial-text on member/tab switch');
    expect(stateAfter.atlasForTest?.generation,
        greaterThanOrEqualTo(atlasBefore!.generation),
        reason: 'previously rasterized glyphs must still be atlased after swap');
  });
}
