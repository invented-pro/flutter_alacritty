## 2.1.0

- **Breaking:** `TerminalView.linkProviders` now defaults to `const []` (no
  automatic URL regex scan on every PTY update). Pass `[UrlLinkProvider()]`
  explicitly to restore clickable `http(s)://` detection. OSC 8 hyperlinks are
  unchanged.
- Library API: `TerminalEngine`, `TerminalController`, `TerminalView` with
  `PtyBackend` wiring; public barrel exports `RustLib` for host `main()`.
- Platform default fonts aligned with VS Code; CJK IME fixes on desktop.
- GNOME-style smooth scrolling, OSC cwd/notifications, hyperlink UX, and
  live color sync via `rust_lib_flutter_alacritty` 0.1.0.

## 1.0.0

- Initial pub.dev release.
- Terminal widget, TOML config, search, selection, and Alacritty-based Rust
  engine via `rust_lib_flutter_alacritty`.
