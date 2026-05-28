import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bottom search bar: a text field plus prev/next/close. Pure UI — all terminal
/// logic stays in TerminalScreen via the callbacks.
class TerminalSearchBar extends StatefulWidget {
  const TerminalSearchBar({
    required this.onChanged,
    required this.onNext,
    required this.onPrev,
    required this.onClose,
    this.invalidPattern = false,
    super.key,
  });

  final bool invalidPattern;
  final ValueChanged<String> onChanged;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onClose;

  @override
  State<TerminalSearchBar> createState() => _TerminalSearchBarState();
}

class _TerminalSearchBarState extends State<TerminalSearchBar> {
  final FocusNode _node = FocusNode();
  final TextEditingController _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _node.requestFocus();
  }

  @override
  void dispose() {
    _node.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      HardwareKeyboard.instance.isShiftPressed ? widget.onPrev() : widget.onNext();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xEE202020),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(
            widget.invalidPattern ? Icons.error_outline : Icons.search,
            size: 16,
            color: widget.invalidPattern
                ? const Color(0xFFE06C75)
                : const Color(0xFFBBBBBB),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: _ctrl,
                focusNode: _node,
                autofocus: true,
                style: const TextStyle(color: Color(0xFFEDEDED), fontSize: 14),
                cursorColor: const Color(0xFFEDEDED),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: widget.invalidPattern ? 'invalid regex' : 'search (regex)',
                  hintStyle: TextStyle(
                    color: widget.invalidPattern
                        ? const Color(0xFFE06C75)
                        : const Color(0xFF888888),
                  ),
                ),
                onChanged: widget.onChanged,
                onSubmitted: (_) => widget.onNext(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onPrev,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onNext,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}
