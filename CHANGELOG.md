# Changelog

<!-- version list -->

## v0.10.2 (2026-10-30)

### Bug Fixes

- Handle padded wireless debugging log timestamps
  ([#12](https://github.com/yiminspace/scrcpy-viewer/pull/12),
  [`3e883b5`](https://github.com/yiminspace/scrcpy-viewer/commit/3e883b5ae7bd8cee666062deac4d96aa4e9fa5d8))

- 修复无线调试断网事件时间戳解析 ([#12](https://github.com/yiminspace/scrcpy-viewer/pull/12),
  [`3e883b5`](https://github.com/yiminspace/scrcpy-viewer/commit/3e883b5ae7bd8cee666062deac4d96aa4e9fa5d8))


## v0.10.1 (2026-10-28)

### Bug Fixes

- 声明跨队列录屏快照的 Sendable 契约 ([#11](https://github.com/yiminspace/scrcpy-viewer/pull/11),
  [`9340db8`](https://github.com/yiminspace/scrcpy-viewer/commit/9340db8a287136c109b47060f4dd8d71cce564a3))

### Performance Improvements

- 降低录屏历史滚动及实时显示的卡顿与内存积压 ([#11](https://github.com/yiminspace/scrcpy-viewer/pull/11),
  [`9340db8`](https://github.com/yiminspace/scrcpy-viewer/commit/9340db8a287136c109b47060f4dd8d71cce564a3))


## v0.10.0 (2026-10-19)

### Features

- 合并同一手机的 USB 与无线连接并支持连接切换 ([#10](https://github.com/yiminspace/scrcpy-viewer/pull/10),
  [`c876603`](https://github.com/yiminspace/scrcpy-viewer/commit/c87660308b0016783d367726d6351530d4877a45))


## v0.9.1 (2026-10-17)

### Bug Fixes

- Recover wireless debugging after network interruptions
  ([#9](https://github.com/yiminspace/scrcpy-viewer/pull/9),
  [`28c7ac5`](https://github.com/yiminspace/scrcpy-viewer/commit/28c7ac5cfffd3e5fd9b7031eb3e823392fad97a9))

- Wi-Fi 恢复后重新开启无线调试 ([#9](https://github.com/yiminspace/scrcpy-viewer/pull/9),
  [`28c7ac5`](https://github.com/yiminspace/scrcpy-viewer/commit/28c7ac5cfffd3e5fd9b7031eb3e823392fad97a9))


## v0.9.0 (2026-10-16)

### Features

- 按设备身份发现无线连接并支持停止和恢复重连 ([#8](https://github.com/yiminspace/scrcpy-viewer/pull/8),
  [`7115df6`](https://github.com/yiminspace/scrcpy-viewer/commit/7115df6e46f720b91f2fde389fe33b8313269e02))


## v0.8.0 (2026-10-16)

### Features

- Reconnect selected wireless devices with exponential backoff
  ([#7](https://github.com/yiminspace/scrcpy-viewer/pull/7),
  [`2bdd718`](https://github.com/yiminspace/scrcpy-viewer/commit/2bdd7188e430e90c9be5d5f9754783e302b1d0f5))

- 无线设备自动重连并采用指数退避 ([#7](https://github.com/yiminspace/scrcpy-viewer/pull/7),
  [`2bdd718`](https://github.com/yiminspace/scrcpy-viewer/commit/2bdd7188e430e90c9be5d5f9754783e302b1d0f5))


## v0.7.0 (2026-10-15)

### Features

- Group recording history by date ([#6](https://github.com/yiminspace/scrcpy-viewer/pull/6),
  [`d69073b`](https://github.com/yiminspace/scrcpy-viewer/commit/d69073b4d9d365eb3eeb9e58126cc60cb3a65aa3))

- 录屏历史按日期分组 ([#6](https://github.com/yiminspace/scrcpy-viewer/pull/6),
  [`d69073b`](https://github.com/yiminspace/scrcpy-viewer/commit/d69073b4d9d365eb3eeb9e58126cc60cb3a65aa3))


## v0.6.0 (2026-09-24)

### Features

- 完善多屏录制与历史管理 ([#5](https://github.com/yiminspace/scrcpy-viewer/pull/5),
  [`47769ce`](https://github.com/yiminspace/scrcpy-viewer/commit/47769ce187dc12ca3b1cc8ac2f9b3fdf1e8d0918))


## v0.5.0 (2026-09-24)

### Features

- 合并多屏画布并加入录屏与录像历史 ([#4](https://github.com/yiminspace/scrcpy-viewer/pull/4),
  [`a41045f`](https://github.com/yiminspace/scrcpy-viewer/commit/a41045fd681a3c23f1080ee826325a04f52a241e))


## Unreleased

- Add a hover-revealed per-recording trash button with a confirmation dialog, defaulting to Cancel, before moving saved videos to the system Trash and removing their history entries.

- Display the main screen and all active secondary screens edge to edge on one black canvas.
- Replace blue focus outlines with a compact, neutral keyboard status.
- Save all screens on the canvas together in one PNG without padding, gaps or title bars.
- Save each recording session as one compact, silent H.264 MP4, including layout changes and dated last frames for ended sources. Earlier layouts leave space on the right for screens that appear later.
- Add optional automatic recording for secondary-display sessions, with a persistent setting and configurable save folder.
- Replace inactive-display history with saved recordings, timestamps, thumbnails and playback in the system default video player on click.

## v0.4.1

- Initial packaged release for Apple Silicon Macs running macOS 14 or later.
- Main-screen mouse, keyboard and clipboard control, with view-only secondary displays.
- Automatic secondary-display discovery, folded history and main-screen input focus protection.
- Pinned, checksum-verified server setup that works without installing or downgrading desktop scrcpy.
- Automated versioning, tested release archives, installation guides and open-source contribution materials.
