import 'package:flutter/material.dart';

/// Floating preedit (composing) string drawn just below the cursor cell.
///
/// The OS IM (fcitx / IBus / etc.) draws its OWN candidate window adjacent to
/// the cursor — we only render the active preedit substring. When [text] is
/// null or empty, the widget collapses to nothing.
class PreeditOverlay extends StatelessWidget {
  const PreeditOverlay({
    required this.text,
    required this.cursorRect,
    required this.bg,
    required this.fg,
    required this.underline,
    required this.textStyle,
    super.key,
  });

  /// The composing substring (`composing.textInside(value.text)` from ImeSession).
  final String? text;

  /// Local-coordinates rect of the cursor cell. The overlay floats just below
  /// it (`cursorRect.bottom + 2`).
  final Rect cursorRect;

  /// Packed RGB (0x00RRGGBB) for background; rendered with full alpha.
  final int bg;
  final int fg;
  final bool underline;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final t = text;
    if (t == null || t.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: cursorRect.left,
      top: cursorRect.bottom + 2,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Color(0xFF000000 | bg),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Text(
            t,
            style: textStyle.copyWith(
              color: Color(0xFF000000 | fg),
              decoration: underline ? TextDecoration.underline : TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
