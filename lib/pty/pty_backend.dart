import 'dart:typed_data';

/// A source/sink of terminal bytes. flutter_pty is the v1 implementation;
/// the interface lets us swap to a forked PTY, a dart:ffi PTY, or a remote
/// (SSH) source later without touching the engine.
abstract class PtyBackend {
  /// Bytes produced by the child process (shell stdout/stderr).
  Stream<Uint8List> get output;

  /// Completes with the child process's exit code when it terminates.
  Future<int> get exitCode;

  /// Send bytes to the child process (stdin).
  void write(Uint8List data);

  /// Tell the child the new window size. Order is (rows, columns).
  void resize(int rows, int columns);

  /// Terminate the child and release resources.
  void kill();

  /// Release the underlying ConPTY / PTY handle. On Windows this drains
  /// the pending write queue, closes the ConPTY input pipe, calls
  /// `ClosePseudoConsole` (which terminates the attached shell and waits
  /// for conhost to flush conout), then closes the output pipe and
  /// joins the reader/writer threads. With the dedicated writer
  /// thread, neither the `Dart_PostCObject_DL` path nor
  /// `WriteFile(conin)` can block the UI thread. On unix it's a no-op.
  /// Mirrors the alacritty tty/windows model.
  void close();
}
