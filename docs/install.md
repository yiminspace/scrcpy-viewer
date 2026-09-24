# Installing Scrcpy Viewer / 安装指南

## Requirements

- Apple Silicon Mac, macOS 14 or later. Release archives contain an `arm64` executable. Intel releases are not currently supported.
- An Android device with USB debugging enabled and authorized for this Mac.
- `adb`, usually installed with Homebrew's `android-platform-tools`.
- The official **scrcpy-server 3.3.3**. The full desktop scrcpy client is optional when using the managed server below.

The app is designed around standard Android display discovery and scrcpy. Multiple-display behavior has been tested on Android 15; capture, input and encoder availability vary by device. It cannot reveal displays that Android does not make capturable. Audio is not implemented.

## Download and open

1. Download the versioned `Scrcpy-Viewer-<version>-macOS-arm64.zip` and `SHA256SUMS` from the **same** [GitHub release](https://github.com/yiminspace/scrcpy-viewer/releases).
2. Put both files in one directory, open Terminal there and verify:

   ```bash
   shasum -a 256 --check SHA256SUMS
   ```

3. Unzip the archive. It includes the app, this guide, the dependency setup script, version and license information.
4. Complete dependency setup below. Move **Scrcpy Viewer.app** into `/Applications` or your personal `~/Applications` folder.
5. Open the app. Connect the phone, enable USB debugging and accept the phone's authorization prompt.

The download is **ad-hoc signed, not signed with an Apple Developer ID and not notarized**. A checksum verifies file integrity; it is not an Apple identity certificate. macOS may block the first launch. If you trust the release, first attempt to open the app, then go to **System Settings → Privacy & Security → Open Anyway**. Follow [Apple's instructions](https://support.apple.com/102445). Managed Macs may have policies that disallow this. There is no need to disable Gatekeeper globally.

日常使用可双击、Spotlight 搜索或拖入 Dock。首次启动若被拦截，确认来源可信后到「系统设置 → 隐私与安全 → 仍要打开」。当前使用免费临时签名，没有 Apple 公证。

## Dependencies

Install [Homebrew](https://brew.sh/) first if you want to use the following adb installation command:

```bash
brew install android-platform-tools
```

From the extracted release directory, run:

```bash
bash setup-dependencies.sh
```

From a source checkout, use `bash scripts/setup-dependencies.sh` instead. The script downloads only the official scrcpy 3.3.3 server from Genymobile's versioned GitHub release over HTTPS, verifies its pinned SHA-256 and stores it at:

```text
~/Library/Application Support/Scrcpy Viewer/Dependencies/scrcpy/3.3.3/scrcpy-server
```

It does not install an APK as an Android app, replace your Homebrew scrcpy, alter your shell startup files, or connect to the phone. The viewer pushes a temporary server to the selected device only when connecting. The app itself never automatically downloads dependencies.

An existing local scrcpy **3.3.3** with the official matching server also works. If Homebrew installs a newer scrcpy, keep it and use the setup script for the viewer's compatible server; do not downgrade other tools just for this app.

不需要 Android Studio。adb 负责连接；本应用使用固定版本的 scrcpy 服务端。依赖脚本不会覆盖你已经安装的新版 scrcpy，也不会操作手机。

### Advanced paths

For a terminal launch, environment overrides are available:

- `ADB`: full path to an executable adb.
- `SCRCPY_BIN`: full path to an optional compatible scrcpy executable.
- `SCRCPY_SERVER_PATH`: full path to the official 3.3.3 server; its SHA-256 must match the supported upstream binary.

Environment variables set only in your shell are not necessarily inherited by Finder-launched applications. The normal Homebrew and Application Support paths work without environment configuration.

## Updating and uninstalling

Quit the app before replacing it with a newer release. Verify each new download's checksum. Releases do not contain an in-app updater; version history and downloads remain available in GitHub Releases.

To uninstall, quit and remove **Scrcpy Viewer.app**. You may also remove `~/Library/Application Support/Scrcpy Viewer/Dependencies` if you no longer need its server. Keep shared adb or scrcpy installations if other tools use them.

The app keeps retained source frames in memory and remembers saved recording paths locally for playback. Screenshots and manual recordings are saved on request; automatic recording and optional diagnostics are off by default. Automatic recording starts only after you enable it in the gear menu. No remote analytics are created. Removing the app does not delete files you have exported.

## Screenshots and recording

The camera button saves the main display and every active secondary together as one PNG. It includes screens outside the visible scroll area. Exported images touch edge to edge with no padding, gaps or title bars; non-live frames include a status and date overlay.

Use the toolbar recording button to choose an MP4 destination and start recording. The app records the main display and all active secondary displays together, including screens discovered after recording starts and screens outside the visible scroll area. Stop from the toolbar to save one MP4 for the whole session; the completion control at the bottom of the window reveals it in Finder. Switching devices or quitting also finishes and saves the current recording.

The silent H.264 output is up to 720 pixels tall and 2560 pixels wide, at 12 fps. Bitrate adjusts to the output size and is capped at 1.6 Mbps. No additional encoder tools are required. The final video fits the widest combined layout used during the session. Each layout keeps its proportions and fills the height, aligned to the left, without gaps between screens or padding above or below. Before another screen appears, its future space on the right stays blank. A screen that sleeps or disappears during recording keeps a dated last frame with its status. GIF export is not available.

If the screen layout changes, stopping begins an extra saving step that combines the session into one video. Wait for saving to finish; only that completed file appears in history. A session with no layout changes saves without re-encoding. If combining fails, the app keeps its temporary source clips for recovery.

To record secondary-display sessions automatically, enable **副屏开启时自动录制** in the gear menu. This option is off by default and remembered across launches. It starts when the selected device has an active secondary display and a frame is available, then stops after the last active secondary sleeps, disappears or disconnects. A manual stop prevents immediate restart until all secondaries have closed. Manually started recordings continue when secondaries close. Automatic files go to `~/Movies/Scrcpy Viewer`; use the same menu to select or open the folder.

Saved recordings appear in the sidebar with timestamps and thumbnails. Click one to open it in the system default video player. The history list loads on launch and refreshes after saves or a recording-folder change. It reads only the selected recording folder and files explicitly saved through the app; manually chosen paths are remembered locally across launches.

## Troubleshooting

- **No device:** run `adb devices -l`, check USB debugging and accept the authorization prompt. Do not post the real serial number in an issue.
- **Missing/incompatible server:** run the included setup script, then click the app's recheck button. The viewer deliberately rejects unknown server protocols or a mismatching server hash.
- **No secondary display:** the app can only mirror displays Android enumerates and permits it to capture. A sleeping or ended secondary leaves the live canvas; the sidebar history contains saved recordings.
- **Many screens fail:** the phone may have exhausted its hardware encoder resources. A desktop-only test cannot establish a device's concurrent streaming limit.
- **No sound:** audio is not implemented. Recordings are silent.
- **Small text in recordings:** output is capped at 720 pixels in height and 2560 pixels in width. Many screens share that width; save a PNG screenshot for a higher-resolution still image.
- **Blank space on the right of a recording:** the video reserves enough width for the widest layout in that session. Earlier, narrower layouts fill the height and leave the unused right side blank.
- **Saving continues after stopping:** the app is combining layout changes into one MP4. Wait for completion; the recording appears in history after it is saved. If saving fails, temporary source clips are retained for recovery.
- **Automatic recording does not restart after a manual stop:** close all secondary displays before the next automatic session, or explicitly toggle automatic recording off and on.
- **A video is missing from history:** history reads the selected recording folder and remembered app exports. Check the folder in the gear menu and whether the file has been moved or deleted.
