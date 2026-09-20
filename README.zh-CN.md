# Scrcpy Viewer

**一个 Mac 窗口，操作 Android 主屏、自动查看副屏。**

[English](README.md) · [安装说明](docs/install.md) · [版本下载](https://github.com/yiminspace/scrcpy-viewer/releases)

这是复用 scrcpy Android 服务端的 macOS 原生客户端。原版 scrcpy 本来就能投指定副屏；本项目增加自动发现、同窗多屏布局、休眠历史管理与主屏焦点保护，省去查询 display ID 和管理多个窗口的操作。

## 已有能力

- 自动发现系统可枚举、可捕获的主屏和副屏，支持单屏与并排布局。
- 主屏支持鼠标点击、拖动、滚动、键盘输入、中文输入法确认后的文字，以及 `⌘A/C/X/V`。
- 副屏仅观看；新副屏出现时不会抢走正在输入的主屏焦点。
- 副屏休眠或移除后，最后画面收进默认折叠的历史列表，并注明时间。
- 清除历史只释放本机画面缓存，不销毁手机屏幕；副屏再次活跃时自动恢复。
- 按需保存 PNG 截图、恢复已选择设备的连接。

通过 Android 系统接口发现屏幕，可用范围取决于设备是否允许枚举和捕获。

## 安装与启动

当前发布包支持 **Apple Silicon、macOS 14 及以上**，界面为中文；尚未提供 Intel、Windows、Linux 版本。

1. 在同一 [Release](https://github.com/yiminspace/scrcpy-viewer/releases) 下载 ZIP 和 `SHA256SUMS`，用 `shasum -a 256 --check SHA256SUMS` 核对后解压。
2. 如未安装 adb，执行 `brew install android-platform-tools`。
3. 在解压目录执行 `bash setup-dependencies.sh`，安装固定版本的官方 scrcpy 服务端。已有兼容的 scrcpy 3.3.3 也可直接使用。
4. 将 **Scrcpy Viewer.app** 放入 `~/Applications` 或 `/Applications`，打开手机 USB 调试并授权 Mac。

应用使用免费临时签名，**没有 Apple 公证**。首次打开下载包可能被系统拦截；确认下载可信后，到「系统设置 → 隐私与安全 → 仍要打开」放行。详见 [安装指南](docs/install.md) 和 [Apple 说明](https://support.apple.com/zh-cn/102445)。

以后可双击、Spotlight 搜索、拖入 Dock，或者：

```bash
open "$HOME/Applications/Scrcpy Viewer.app"
```

## 功能边界

目前**没有音频、录屏、文件传输、游戏手柄或创建副屏功能**，需要这些能力时使用原版 scrcpy。保存当前画面是 PNG 截图，不是录像。

可同时播放多少副屏取决于手机的编码器资源。受保护或不可访问的虚拟屏可能无法捕获。应用不会自动唤醒手机、自动发送输入或维持其他应用的后台任务。

## 从源码构建

需要 Swift 5.10+ 和 Xcode Command Line Tools；本地执行 XCTest 需要完整 Xcode。

```bash
git clone https://github.com/yiminspace/scrcpy-viewer.git
cd scrcpy-viewer
brew install android-platform-tools
bash scripts/setup-dependencies.sh
./scripts/run.sh
```

`swift build` 编译，`swift test` 测试，`./scripts/build-app.sh` 生成应用；`./scripts/package-release.sh` 在 Apple Silicon 上生成 ZIP 和校验文件。

协议固定为 scrcpy 3.3.3。安装脚本核对官方 SHA-256，将服务端保存在用户的 Application Support 目录，不替换现有 scrcpy；应用本身不会联网下载依赖。

贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)，发布流程见 [docs/releasing.md](docs/releasing.md)。升级时下载新版本并替换应用，暂未提供应用内自动更新。

本项目采用 [MIT](LICENSE) 协议，是独立项目，非 Genymobile 官方项目。scrcpy 服务端使用 Apache-2.0；仓库和应用下载包均不内置其二进制。详见 [第三方声明](THIRD_PARTY_NOTICES.md)。
