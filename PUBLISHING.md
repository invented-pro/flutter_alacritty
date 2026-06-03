# Publishing to pub.dev

The FFI plugin is a **separate repo**
([rust_lib_flutter_alacritty](https://github.com/hhoao/rust_lib_flutter_alacritty)),
linked here as `packages/rust_lib_flutter_alacritty/` (git submodule).

Both packages are on pub.dev. To publish a new version:

1. Bump and publish `rust_lib_flutter_alacritty` from
   `packages/rust_lib_flutter_alacritty/` (submodule repo).
2. Bump the `rust_lib_flutter_alacritty` constraint in this `pubspec.yaml`,
   then `dart pub get`, `dart pub publish --dry-run`, `dart pub publish`.

Use `PUB_HOSTED_URL=https://pub.dev` if your shell points at a mirror.

## Pre-flight checklist

- [ ] `dart pub login`
- [ ] Package names available on pub.dev
- [ ] `flutter test` and `flutter analyze lib test` pass
- [ ] Versions bumped in both repos + `CHANGELOG.md`
