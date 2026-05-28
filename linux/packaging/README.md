# Linux Packaging

Linux 端使用 [fastforge](https://pub.dev/packages/fastforge) 打包 `.deb` 和 `AppImage`。

## 一次性准备

```bash
dart pub global activate fastforge

# 系统依赖（Ubuntu/Debian）
sudo apt install -y dpkg-deb fakeroot file libfuse2
```

`libfuse2` 是 AppImage 运行时需要的。`dpkg-deb` / `fakeroot` 用于构建 `.deb`。

确保 `~/.pub-cache/bin` 在 `PATH` 中：

```bash
export PATH="$PATH:$HOME/.pub-cache/bin"
```

## 构建命令（在仓库根目录）

```bash
git submodule update --init --recursive
flutter pub get

# 同时构建 deb + AppImage
fastforge release --name dev

# 只构建 deb
fastforge package --platform linux --targets deb

# 只构建 AppImage
fastforge package --platform linux --targets appimage
```

产物在 `dist/<version>/` 下（例如 `flutter_alacritty-1.0.0-linux.deb`）。

## 文件结构

```
├── distribute_options.yaml                       # fastforge 顶层配置（release/jobs）
└── linux/packaging/
    ├── io.github.hhoao.flutter_alacritty.desktop # 通用 desktop entry
    ├── deb/make_config.yaml                      # .deb 元数据（依赖/维护者等）
    └── appimage/make_config.yaml                 # AppImage 元数据
```

## 验证安装效果

### `.deb`

```bash
sudo dpkg -i dist/1.0.0/flutter_alacritty-1.0.0-linux.deb
# 启动后查看 dock：应显示 "Flutter Alacritty" 名称和应用图标
```

卸载：`sudo apt remove flutter-alacritty`（包名以 `dpkg -l` 为准）

### AppImage

```bash
chmod +x dist/1.0.0/flutter_alacritty-1.0.0-linux.AppImage
./dist/1.0.0/flutter_alacritty-1.0.0-linux.AppImage
```

若希望 AppImage 也注册到桌面环境（dock 显示名称/图标），推荐安装
[AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher)，
首次运行时它会自动把 desktop entry 注册到 `~/.local/share/applications/`。

## 修改版本号

编辑 [`pubspec.yaml`](../../pubspec.yaml) 中的 `version:` 字段（如 `1.0.1+2`），
fastforge 会自动读取并写进包名和 deb control 文件。

## 常见问题

- **dock 显示 `io.github.hhoao.flutter_alacritty` 而非 `Flutter Alacritty`**：说明系统没在 `XDG_DATA_DIRS/applications/`
  下找到匹配的 desktop 文件。`.deb` 安装后会自动放置；AppImage 需要 AppImageLauncher
  或手动复制 `.desktop` 到 `~/.local/share/applications/` 并 `update-desktop-database`。
- **AppImage 报 `FUSE` 错误**：装 `libfuse2`（Ubuntu 22.04+ 默认不带）。
- **图标不显示**：检查 [`assets/icons/icon.png`](../../assets/icons/icon.png) 存在且非空。
