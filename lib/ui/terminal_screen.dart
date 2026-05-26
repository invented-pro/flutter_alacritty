import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../input/key_input.dart';
import '../pty/flutter_pty_backend.dart';
import '../pty/pty_backend.dart';
import '../render/mirror_grid.dart';
import '../render/terminal_painter.dart';
import '../src/rust/api/terminal.dart';
import '../src/rust/engine.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const _style = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    height: 1.2,
  );

  late final CellMetrics _metrics = CellMetrics.measure(_style);
  final MirrorGrid _grid = MirrorGrid();
  final FocusNode _focus = FocusNode();

  TerminalEngine? _engine;
  PtyBackend? _pty;
  int _cols = 0, _rows = 0;

  void _ensureStarted(int cols, int rows) {
    if (_engine != null) {
      if (cols != _cols || rows != _rows) {
        _cols = cols;
        _rows = rows;
        engineResize(engine: _engine!, columns: cols, rows: rows);
        _pty!.resize(rows, cols);
      }
      return;
    }
    _cols = cols;
    _rows = rows;
    _engine = engineNew(columns: cols, rows: rows);
    _pty = FlutterPtyBackend(rows: rows, columns: cols);
    _pty!.output.listen(_onOutput);
  }

  void _onOutput(Uint8List bytes) {
    engineAdvance(engine: _engine!, bytes: bytes);
    _pushSnapshot();
  }

  void _pushSnapshot() {
    final s = engineSnapshot(engine: _engine!);
    _grid.update(MirrorSnapshot(
      rows: s.rows,
      columns: s.columns,
      codepoints: s.cells.map((c) => c.codepoint).toList(growable: false),
      fg: s.cells.map((c) => c.fg).toList(growable: false),
      bg: s.cells.map((c) => c.bg).toList(growable: false),
      cursorRow: s.cursorLine,
      cursorCol: s.cursorCol,
      cursorVisible: s.cursorVisible,
    ));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final bytes = encodeKey(event.logicalKey, event.character, ctrl: ctrl);
    if (bytes == null) return KeyEventResult.ignored;
    _pty?.write(bytes);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _pty?.kill();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cols = (constraints.maxWidth / _metrics.width)
              .floor()
              .clamp(1, 1000);
          final rows = (constraints.maxHeight / _metrics.height)
              .floor()
              .clamp(1, 1000);
          // Defer start/resize until after layout to avoid setState-in-build.
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => _ensureStarted(cols, rows));
          return Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: GestureDetector(
              onTap: () => _focus.requestFocus(),
              child: CustomPaint(
                size: Size.infinite,
                painter: TerminalPainter(
                  grid: _grid,
                  style: _style,
                  metrics: _metrics,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
