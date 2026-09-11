import 'package:flutter/widgets.dart';

/// Inline preedit (composing) string drawn at the cursor cell, on the cursor's
/// own row (Windows Terminal / Alacritty convention).
///
/// The OS IM (fcitx / IBus / MS Pinyin / etc.) draws its OWN candidate window
/// anchored below the caret rect we report via `setImeGeometry` — so the
/// preedit must stay ON the cursor row; placing it below (as before) put it
/// exactly under the OS candidate pane, which always paints over app content
/// (preedit became invisible on Windows). Callers should gate construction so
/// this widget is only mounted while [text] is non-empty.
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
  final String text;

  /// Local-coordinates rect of the cursor cell. The overlay renders inline on
  /// that row (`cursorRect.top`), starting at the cursor column.
  final Rect cursorRect;

  /// Packed RGB (0x00RRGGBB); alpha is forced to full when rendered.
  final int bg;

  /// Packed RGB (0x00RRGGBB); alpha is forced to full when rendered.
  final int fg;
  final bool underline;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: cursorRect.left,
      top: cursorRect.top,
      child: IgnorePointer(
        child: Container(
          height: cursorRect.height,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: Color(0xFF000000 | bg),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Text(
            text,
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
