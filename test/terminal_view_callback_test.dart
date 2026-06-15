import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/links/terminal_link_provider.dart';
import 'package:flutter_alacritty/links/url_link_provider.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

// ---------------------------------------------------------------------------
// Stub link provider for link-overlay tests.
// ---------------------------------------------------------------------------

class _StubProvider extends TerminalLinkProvider {
  _StubProvider(this.matchText, this.payload, {this.enabled = true});
  final String matchText;
  final String payload;
  bool enabled;

  @override
  Iterable<LinkSpan> scan(String lineText) {
    final i = lineText.indexOf(matchText);
    return i < 0
        ? const []
        : [LinkSpan(start: i, end: i + matchText.length, payload: payload)];
  }

  @override
  bool isEnabled(LinkSpan span) => enabled;
}

/// Provider whose spans start disabled and flip to enabled on [confirm], which
/// also fires `notifyListeners` — modelling an async validator (e.g. filesystem
/// existence check) confirming a candidate after the fact.
class _AsyncStubProvider extends TerminalLinkProvider {
  _AsyncStubProvider(this.matchText, this.payload);
  final String matchText;
  final String payload;
  bool _ready = false;

  @override
  Iterable<LinkSpan> scan(String lineText) {
    final i = lineText.indexOf(matchText);
    return i < 0
        ? const []
        : [LinkSpan(start: i, end: i + matchText.length, payload: payload)];
  }

  @override
  bool isEnabled(LinkSpan span) => _ready;

  void confirm() {
    _ready = true;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// FakeBinding subclass that puts `text` on row 0 of every snapshot.
// ---------------------------------------------------------------------------

class _TextFakeBinding extends FakeBinding {
  _TextFakeBinding(this.rowText);
  final String rowText;

  GridUpdate _textSnapshot() {
    const cols = 80, rows = 24;
    final codepoints = Int32List(cols)..fillRange(0, cols, 32);
    for (var i = 0; i < rowText.length && i < cols; i++) {
      codepoints[i] = rowText.codeUnitAt(i);
    }
    final line0 = LineCells(
      line: 0,
      codepoints: codepoints,
      fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
      bg: Int32List(cols)..fillRange(0, cols, 0x181818),
      flags: Uint16List(cols),
      hyperlinkId: Int32List(cols),
    );
    LineCells blank(int i) => LineCells(
          line: i,
          codepoints: Int32List(cols)..fillRange(0, cols, 32),
          fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
          bg: Int32List(cols)..fillRange(0, cols, 0x181818),
          flags: Uint16List(cols),
          hyperlinkId: Int32List(cols),
        );
    return GridUpdate(
      full: true,
      rows: rows,
      columns: cols,
      lines: [line0, for (var i = 1; i < rows; i++) blank(i)],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      modeFlags: modeFlags,
    );
  }

  @override
  GridUpdate fullSnapshotSearched() => _textSnapshot();
}

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
  List<TerminalLinkProvider>? linkProviders,
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
        linkProviders: linkProviders ?? [UrlLinkProvider()],
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

  // Regression for the engine-swap bug caught in 2W code review: TerminalView
  // subscribes to engine.bell in initState but didUpdateWidget originally
  // didn't compare widget.engine to oldWidget.engine, so after a host-driven
  // engine swap (e.g. shell restart) the bell stream pointed at the disposed
  // OLD engine and any Bell event was silently lost.
  testWidgets('bell after engine swap still flashes the visual bell',
      (tester) async {
    final binding1 = FakeBinding();
    final engine1 = TerminalEngine.fromBinding(
      binding1,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    final binding2 = FakeBinding();
    final engine2 = TerminalEngine.fromBinding(
      binding2,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    addTearDown(() {
      engine1.dispose();
      engine2.dispose();
    });

    // The harness lets the test swap the engine prop and triggers
    // didUpdateWidget on the inner TerminalView.
    final engineNotifier = ValueNotifier<TerminalEngine>(engine1);
    addTearDown(engineNotifier.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<TerminalEngine>(
          valueListenable: engineNotifier,
          builder: (context, engine, _) => TerminalView(
            engine,
            // Non-zero duration so _flashBell actually animates the
            // controller (zero-duration short-circuits).
            bellDuration: const Duration(milliseconds: 100),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    AnimationController bellCtrl() {
      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      return state.bellControllerForTest;
    }

    // Drive bell events through the rewired binding callback directly —
    // simpler than queueing a pendingEvent + feeding through the drain (which
    // would need the schedule shim wired). `_bindEager` populates binding.onBell
    // at fromBinding construction time, pointing at the engine's bellCtl.add.

    // Sanity: pre-swap bell fires through engine1.
    binding1.onBell!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
    expect(bellCtrl().value, greaterThan(0.0),
        reason: 'bell on the initial engine should animate the controller');

    // Let the animation settle so we observe a fresh trigger after the swap.
    await tester.pump(const Duration(milliseconds: 200));
    expect(bellCtrl().value, 0.0);

    // SWAP the engine — Without the didUpdateWidget fix, _bellSub still
    // points at engine1 (whose stream is about to close on dispose), so
    // the next bell would be dropped.
    engineNotifier.value = engine2;
    await tester.pump();

    binding2.onBell!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
    expect(bellCtrl().value, greaterThan(0.0),
        reason:
            'bell on the swapped-in engine must also animate — TerminalView '
            'must cancel + re-subscribe _bellSub on engine identity change');
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

  // -------------------------------------------------------------------------
  // Link provider (overlay) tests
  // -------------------------------------------------------------------------

  testWidgets('linkOverlay is populated after debounce when provider matches',
      (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _StubProvider(matchText, 'stub-payload');
    final binding = _TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    await _pumpView(
      tester,
      engine: engine,
      linkProviders: [provider],
    );

    // Throwaway click to populate the mirror grid from fullSnapshotSearched().
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    // Advance past the 120ms debounce.
    await tester.pump(const Duration(milliseconds: 150));

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final overlay = state.linkOverlayForTest;
    // Row 0, col 0 is inside STUB_LINK (start=0).
    expect(overlay.isLinkCell(0, 0), isTrue,
        reason: 'overlay should mark the stub link cells as link cells');
    // A column well beyond the match text should not be a link.
    expect(overlay.isLinkCell(0, matchText.length + 5), isFalse,
        reason: 'columns outside the span should not be link cells');
  });

  testWidgets(
      'Ctrl+click on enabled provider span fires onLinkActivate(payload)',
      (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _StubProvider(matchText, 'stub-payload');
    final binding = _TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      onLinkActivate: (uri) => launched = uri,
      linkProviders: [provider],
    );

    // Throwaway click to prime the grid.
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    // Wait for debounce to fire and overlay to be built.
    await tester.pump(const Duration(milliseconds: 150));

    // Ctrl+left-click on cell (0,0) which is inside STUB_LINK.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(launched, 'stub-payload',
        reason: 'Ctrl+click on an enabled overlay link should fire onLinkActivate');
  });

  testWidgets('Ctrl+click on disabled provider span does NOT fire onLinkActivate',
      (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _StubProvider(matchText, 'stub-payload', enabled: false);
    final binding = _TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      onLinkActivate: (uri) => launched = uri,
      linkProviders: [provider],
    );

    // Throwaway click to prime the grid.
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    // Wait for debounce.
    await tester.pump(const Duration(milliseconds: 150));

    // The overlay should be empty because the provider is disabled.
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(state.linkOverlayForTest.isLinkCell(0, 0), isFalse,
        reason: 'disabled provider should not add cells to the overlay');

    // Ctrl+click should not fire the callback.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(launched, isNull,
        reason: 'disabled span should not trigger onLinkActivate');
  });

  testWidgets(
      'provider notifyListeners flows through debounce and updates the overlay',
      (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _AsyncStubProvider(matchText, 'stub-payload');
    final binding = _TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    await _pumpView(
      tester,
      engine: engine,
      linkProviders: [provider],
    );

    // Throwaway click to populate the mirror grid from fullSnapshotSearched().
    final painterTopLeft = tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    // Not yet confirmed → the span is detected but not enabled.
    expect(state.linkOverlayForTest.isLinkCell(0, 0), isFalse,
        reason: 'unconfirmed async span should not be a link cell');

    // Async confirmation fires notifyListeners; this must schedule a debounced
    // recompute (not a direct one), after which the overlay marks the cell.
    provider.confirm();
    await tester.pump(const Duration(milliseconds: 150));

    expect(state.linkOverlayForTest.isLinkCell(0, 0), isTrue,
        reason: 'provider notification should flow through the debounce and '
            'update the overlay once the span is enabled');
  });
}
