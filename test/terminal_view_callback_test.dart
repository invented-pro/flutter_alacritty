import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

Future<TerminalEngine> _engineForView(FakeBinding binding) async {
  // Use the lazy constructor path; the view drives `resize` on its first
  // build via the LayoutBuilder, which boots the binding under the hood.
  // For tests we bind eagerly so the view can paint a non-empty grid.
  return TerminalEngine.fromBinding(
    binding,
    config: TerminalConfig.defaults(),
    schedule: (_) {},
  );
}

Future<void> _pumpView(
  WidgetTester tester, {
  required TerminalEngine engine,
  void Function(TapDownDetails, CellOffset)? onTapDown,
  void Function(TapUpDetails, CellOffset)? onTapUp,
  void Function(TapDownDetails, CellOffset)? onSecondaryTapDown,
  void Function(TapUpDetails, CellOffset)? onSecondaryTapUp,
  void Function(String)? onLinkActivate,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TerminalView(
        engine,
        onTapDown: onTapDown,
        onTapUp: onTapUp,
        onSecondaryTapDown: onSecondaryTapDown,
        onSecondaryTapUp: onSecondaryTapUp,
        onLinkActivate: onLinkActivate,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('onTapUp fires with the CellOffset of the tap', (tester) async {
    final binding = FakeBinding();
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    TapUpDetails? gotDetails;
    CellOffset? gotCell;
    await _pumpView(
      tester,
      engine: engine,
      onTapUp: (d, c) {
        gotDetails = d;
        gotCell = c;
      },
    );

    // Top-left of the painter, offset by ~2px so it lands inside cell (0,0).
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final tapPos = painterTopLeft + const Offset(2, 2);
    final g = await tester.startGesture(tapPos, kind: PointerDeviceKind.mouse);
    await g.up();
    await tester.pump();

    expect(gotDetails, isNotNull);
    expect(gotCell, isNotNull);
    expect(gotCell!.row, 0);
    expect(gotCell!.column, 0);
  });

  testWidgets('onSecondaryTapUp fires for right-click', (tester) async {
    final binding = FakeBinding();
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    CellOffset? gotCell;
    await _pumpView(
      tester,
      engine: engine,
      onSecondaryTapUp: (_, c) => gotCell = c,
    );

    final center = tester.getCenter(find.byType(CustomPaint).first);
    final g = await tester.startGesture(
      center,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await g.up();
    await tester.pump();

    expect(gotCell, isNotNull);
  });

  testWidgets('onLinkActivate fires for Ctrl+left-click on a hyperlink cell',
      (tester) async {
    final binding = FakeBinding()
      ..hyperlinkAt[(0, 0)] = 7
      ..hyperlinkUris[7] = 'https://example.org';
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      onLinkActivate: (uri) => launched = uri,
    );

    // Prime the mirror grid with the hyperlink-bearing snapshot — the view's
    // hyperlink lookup reads from the grid, and the grid is populated on
    // the engine's first refresh, which the FakeBinding ties to selection
    // events. A throwaway click registers that refresh.
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    // Ctrl+left-click on the hyperlink cell.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(launched, 'https://example.org');
  });
}
