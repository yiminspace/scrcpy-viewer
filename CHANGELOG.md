# Changelog

<!-- version list -->

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
