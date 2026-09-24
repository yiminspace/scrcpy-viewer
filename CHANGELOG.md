# Changelog

<!-- version list -->

## v0.5.0 (2026-09-24)

### Features

- 合并多屏画布并加入录屏与录像历史 ([#4](https://github.com/yiminspace/scrcpy-viewer/pull/4),
  [`a41045f`](https://github.com/yiminspace/scrcpy-viewer/commit/a41045fd681a3c23f1080ee826325a04f52a241e))


## Unreleased

- Add a per-recording trash button that moves saved videos to the system Trash and removes their history entries.

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
