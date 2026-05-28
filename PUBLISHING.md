# Publishing to pub.dev

The FFI plugin is a **separate repo**
([rust_lib_flutter_alacritty](https://github.com/hhoao/rust_lib_flutter_alacritty)),
linked here as `packages/rust_lib_flutter_alacritty/` (git submodule).

Publish **in order**.

## 1. `rust_lib_flutter_alacritty`

```bash
cd packages/rust_lib_flutter_alacritty
dart pub publish --dry-run
dart pub publish
```

In the parent repo, temporarily move `.pubignore` aside if dry-run complains
(see comment about `/packages/rust_lib_flutter_alacritty/`).

## 2. `flutter_alacritty` (this repo)

Remove `dependency_overrides` from `pubspec.yaml`, commit, then:

```bash
dart pub get
dart pub publish --dry-run
dart pub publish
```

## Pre-flight checklist

- [ ] `dart pub login`
- [ ] Package names available on pub.dev
- [ ] `flutter test` and `flutter analyze lib test` pass
- [ ] Versions bumped in both repos + `CHANGELOG.md`
