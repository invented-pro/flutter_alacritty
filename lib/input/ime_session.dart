import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';

/// Sentinel editing state so macOS/Windows TextInput can signal Backspace via
/// a shrinking field (xterm [CustomTextEdit] delete-detection parity).
const TextEditingValue kImeDeleteDetectionBaseline = TextEditingValue(
  text: '  ',
  selection: TextSelection.collapsed(offset: 2),
);

/// Owns the platform TextInput connection for the terminal view. Parses
/// `updateEditingValue` into events the rest of the app cares about:
///
///   onPreeditChanged(String?) — the current composing substring (null = no
///     active preedit; the overlay should hide).
///   onCommit(String)         — a finalized string the terminal should write
///     to the PTY as UTF-8 bytes.
///   onBackspace()            — delete key while the TextInput buffer shrinks.
///
/// Protocol: on attach the editing state is seeded with the two-space
/// [kImeDeleteDetectionBaseline] sentinel (deletes must stay observable —
/// IMEs stop issuing delete commands against an empty field). From then on
/// the platform-side field is NEVER re-truncated via setEditingState while
/// the session lives. Belief-tracking IMEs (segmented pinyin, Sogou-style
/// continuous input, …) derive the ranges they pass to setMarkedText from
/// the field contents they last commanded; an out-of-band truncation
/// desyncs them — the engine then combines their stale cursor offsets with
/// the shortened text and emits an editing state whose selection exceeds
/// the text length, which the framework drops (debug assertion
/// "Range start N is out of text of length M"), killing all further IME
/// delivery for the session. Instead, Dart tracks a consumption frontier
/// ([_consumed]): commits are whatever the field grew beyond the frontier,
/// a shrink is a backspace (restoring the sentinel only when the deletion
/// bites into it), and a field that no longer carries the sentinel at all
/// is a wholesale replace (lone-CJK IMEs) — commit-and-reset. The field is
/// re-seeded only at attach and after those two repairs: moments when no
/// marked text is in flight.
///
/// Per-frame, the caller should pass cursor geometry via [setImeGeometry] so
/// the OS IM (fcitx / IBus / macOS IME / etc.) positions its candidate window
/// adjacent to the cursor cell.
class ImeSession implements TextInputClient {
  ImeSession({
    required this.onCommit,
    required this.onPreeditChanged,
    required this.onBackspace,
  });

  final void Function(String text) onCommit;
  final void Function(String? preedit) onPreeditChanged;
  final void Function() onBackspace;

  TextInputConnection? _conn;
  bool _composing = false;
  TextEditingValue _editing = kImeDeleteDetectionBaseline;

  /// Offset into the platform-side field text up to which everything has
  /// already been committed to the PTY. See the class doc.
  int _consumed = kImeDeleteDetectionBaseline.text.length;

  bool get isAttached => _conn != null && _conn!.attached;

  /// True while the platform IM has an active composing range (preedit).
  bool get isComposing => _composing;

  /// Open a platform TextInput session. Idempotent.
  void attach() {
    if (isAttached) return;
    // Provide the viewId so the platform text input plugin can associate
    // the client with the correct FlutterView. Without this, TextInput.setClient
    // fails with "view ID is null" on Windows. (Same fix as AppFlowy #1126.)
    final viewId = PlatformDispatcher.instance.views.firstOrNull?.viewId;
    _conn = TextInput.attach(
      this,
      TextInputConfiguration(
        inputType: TextInputType.text,
        inputAction: TextInputAction.none,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        enableIMEPersonalizedLearning: false,
        viewId: viewId,
      ),
    );
    _resetEditing(notify: false);
    _conn!.show();
  }

  /// Close the session and clear any visible preedit. Safe to call when not
  /// attached.
  /// [notify] — when false, skip [onPreeditChanged] (e.g. widget [dispose]).
  void detach({bool notify = true}) {
    _composing = false;
    if (notify) onPreeditChanged(null);
    _conn?.close();
    _conn = null;
  }

  /// Positions the platform IME: editable bounds + caret.
  ///
  /// [localCaret] is the caret rectangle in the editable's LOCAL coordinate
  /// space (origin at the editable's top-left, no pane offset). Both platform
  /// messages sent here take local coordinates — the same contract
  /// `EditableText` uses (`RenderEditable.getLocalRectForCaret`): the engines
  /// combine the rect with [editableTransform] themselves.
  ///
  ///   Windows: `TextInput.setMarkedTextRect` — the engine computes
  ///   composing_rect_ × editabletext_transform_ to position the IME
  ///   composition window.
  ///   macOS: `TextInput.setCaretRect` — the engine answers
  ///   `firstRectForCharacterRange:` (queried by CJK IME candidate panes and
  ///   the accent menu) by transforming _caretRect by the editable transform.
  ///   Passing a view-global rect there double-applies the pane offset, which
  ///   flings the candidates pane far from the caret in split panes.
  void setImeGeometry({
    required Size editableSize,
    required Matrix4 editableTransform,
    required Rect localCaret,
  }) {
    if (!isAttached) return;
    _conn!.setEditableSizeAndTransform(editableSize, editableTransform);
    _conn!.setComposingRect(localCaret);
    _conn!.setCaretRect(localCaret);
  }

  void _resetEditing({bool notify = true}) {
    _editing = kImeDeleteDetectionBaseline;
    _composing = false;
    _consumed = kImeDeleteDetectionBaseline.text.length;
    _conn?.setEditingState(_editing);
    if (notify) onPreeditChanged(null);
  }

  // TextInputClient ----------------------------------------------------------

  @override
  void updateEditingValue(TextEditingValue value) {
    _editing = value;
    final text = value.text;
    final composing = value.composing;
    // Release builds don't assert range validity in
    // TextEditingValue.fromJSON; a desynced engine could hand us an
    // out-of-bounds composing range, which textInside would turn into a
    // RangeError. Treat those as "no active composing".
    final composingActive = composing.isValid &&
        !composing.isCollapsed &&
        composing.end <= text.length;
    if (composingActive) {
      _composing = true;
      onPreeditChanged(composing.textInside(text));
      return;
    }
    _composing = false;
    onPreeditChanged(null);

    final sentinel = kImeDeleteDetectionBaseline.text;
    if (text.startsWith(sentinel)) {
      if (text.length > _consumed) {
        onCommit(text.substring(_consumed));
        _consumed = text.length;
      } else if (text.length < _consumed) {
        // The platform deleted committed text (backspace / word delete).
        onBackspace();
        _consumed = text.length;
      }
      return;
    }
    if (sentinel.startsWith(text)) {
      // The deletion bit into the sentinel itself ('  ' → ' ' → ''):
      // report the backspace and restore the two spaces so the next
      // delete remains observable. IMEs stop issuing delete commands on
      // an empty field.
      if (text.isNotEmpty && text.length < _consumed) onBackspace();
      _resetEditing(notify: false);
      return;
    }
    // The field was replaced wholesale — some IMEs commit lone CJK by
    // replacing everything instead of inserting at the cursor.
    if (text.isNotEmpty) onCommit(text);
    _resetEditing(notify: false);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _editing;

  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  void performAction(TextInputAction action) {}
  @override
  void insertContent(KeyboardInsertedContent content) {}
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // No _resetEditing here: these selectors arrive without the engine
    // having mutated its editing model, so re-seeding the field would only
    // truncate committed history under the IME's feet (see class doc).
    if (action == 'deleteBackward' || action == 'deleteWordBackward') {
      onBackspace();
    }
  }
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
  @override
  void connectionClosed() => detach();
  @override
  bool onFocusReceived() => false;
  @override
  void didChangeInputControl(TextInputControl? old, TextInputControl? n) {}
  @override
  void insertTextPlaceholder(Size size) {}
  @override
  void removeTextPlaceholder() {}
  @override
  void showToolbar() {}
  @override
  void performSelector(String selectorName) {
    // See performPrivateCommand for why this must not reset the field.
    if (selectorName == 'deleteBackward:') {
      onBackspace();
    }
  }
}
