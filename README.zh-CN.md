# Scrcpy Viewer

**一个 Mac 窗口，操作 Android 主屏、自动查看副屏。**

[English](README.md) · [安装说明](docs/install.md) · [版本下载](https://github.com/yiminspace/scrcpy-viewer/releases)

这是复用 scrcpy Android 服务端的 macOS 原生客户端。原版 scrcpy 本来就能投指定副屏；本项目增加自动发现、同窗多屏布局、录屏回看与主屏焦点保护，省去查询 display ID 和管理多个窗口的操作。

## 已有能力

- 自动发现系统可枚举、可捕获的主屏和副屏，在同一块黑色画布上紧贴并排显示；屏幕多时可横向滚动。
- 主屏支持鼠标点击、拖动、滚动、键盘输入、中文输入法确认后的文字，以及 `⌘A/C/X/V`。
- 副屏仅观看；新副屏出现时不会抢走正在输入的主屏焦点。
- 副屏休眠或结束后退出实时画布；侧栏显示带时间和缩略图的录屏历史，点击即可使用系统默认播放器回看。
- 将主屏和所有活跃副屏合成一张 PNG 截图；恢复已选择设备的连接。
- 主动录制主屏与所有活跃副屏，合成小体积的无声 MP4；录制中新出现的副屏也会自动加入。
- 可选开启副屏自动录屏，跟随当前设备的副屏活动开始和结束。

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

## 截图与录屏

点击相机按钮，将主屏和全部活跃副屏合成一张 PNG。横向滚动到窗口外的屏幕也会包含在内。画面紧贴排列，没有额外边距、间隙或标题栏；非实时画面的状态和时间标注在画面内部。

点击工具栏的录屏按钮，选择 MP4 保存位置，完成后点击停止。录屏包含主屏和所有活跃副屏，不受选中屏幕或横向滚动位置影响；新出现的活跃副屏自动加入，休眠或移除的屏幕保留带状态和时间的最后画面。每次录制保存为一个 MP4，保存成功后可点击窗口底部的「查看录屏」在 Finder 中查看。

输出为无声 H.264 MP4，高度最高 720 像素、宽度最高 2560 像素、12 fps，码率随输出尺寸调整，上限 1.6 Mbps。视频采用本次录制中最宽布局的比例，各时刻的画面按统一高度等比缩放、左侧对齐，屏幕之间没有间隙，上下不加多余区域；新副屏尚未出现时，右侧预留的位置为空白。

副屏新增或旋转等布局变化会在停止录制后合成为同一个完整视频，期间显示正在保存；布局不变时无需重新编码。历史只显示最终保存的视频。合成失败时会保留临时片段，便于恢复。为控制文件体积，采用 MP4，暂不提供 GIF 导出。切换设备或退出应用时会完成并保存当前录制。

齿轮菜单中的「副屏开启时自动录制」默认关闭，开启后会记住设置。当前设备有活跃副屏且已有可录制画面时自动开始，最后一个活跃副屏休眠、移除或断连后停止并保存；多个副屏重叠存在时保持同一次录制。手动停止后，要等所有副屏关闭才会恢复自动触发；手动开启的录制不随副屏关闭而停止。自动录屏默认保存到 `~/Movies/Scrcpy Viewer`，可在齿轮菜单选择或打开保存目录。

侧栏的录屏历史显示保存时间和缩略图，点击条目即可使用系统默认播放器播放。鼠标悬停在条目上时，右侧会出现删除按钮；点击后先确认，确认后才将视频移到系统废纸篓，并从历史中移除。确认框默认选择取消。启动应用或录屏保存后，从当前录屏目录和本应用明确保存过的文件加载列表，不扫描其他目录。手动选择的保存路径会记在本机，重启后仍可回看这些录屏。

## 功能边界

目前**没有音频、文件传输、游戏手柄或创建副屏功能**，需要这些能力时使用原版 scrcpy。全屏 PNG 截图与录屏分别操作。

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
