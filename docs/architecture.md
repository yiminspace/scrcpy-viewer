# Architecture

`ViewerCore` owns dependency resolution, bounded adb commands, logical display discovery, the scrcpy 3.3.3 wire protocol, capture/control sessions, H.264 decoding and video-file recording. `ScrcpyViewer` owns SwiftUI state and presentation.

The runtime dependencies are a trusted local `adb` executable and the official scrcpy Android server matching protocol version **3.3.3**. A compatible local installation can supply the server. An optional installation flow must fetch that fixed official release only after an explicit user action, verify its pinned checksum, and store it outside the repository. It must not silently replace another installed scrcpy version. The application is an independent client; scrcpy's Apache-2.0 license remains separate from the application's MIT license. See [third-party notices](../THIRD_PARTY_NOTICES.md).

Discovery is serialized. The matching `DisplayDeviceInfo` is the source of truth for ON/OFF; `mOverrideDisplayInfo` is not. Display identity combines device serial, logical ID and unique ID, so an ID reused by a different virtual display is a new item.

Each capture session has its own server jar path, random scid and adb forward. Main display 0 opens video and control channels; secondary displays open video only, enforced by the transport. All use `audio=false`, `power_on=false`. The client validates the dummy byte, device metadata, H.264 codec header, packet sizes and frame flags. Config NAL units update the decoder; subsequent video packets maintain their dependency chain. Rendering uses decoded frames and retains the last image after the source ends.

Control messages are generated only by explicit user actions. Input targets the main display, using the current decoded video dimensions and the fitted image rectangle. Retained frames and secondary displays never accept control. Merely discovering a display or changing selection must not inject input.

The UI isolates stream callbacks by generation. An old session cannot update the new session's card after an OFF→ON transition or device switch. The stream is only described as live after a frame has actually decoded. Static images are not disconnected merely for lacking new frames.

The live scene and device list include the main display and active secondaries. Inactive secondary frames may remain in memory for a recording's source status, but do not become sidebar history entries or reappear through history selection. Main-screen input focus suppresses automatic follow for that arrival only, so it is never replayed after typing ends.

Discovery uses Android logical display IDs and source-display metadata. Availability and capturability depend on the device and the application that owns the display. All secondary displays follow the same discovery and read-only capture rules.

The live stage places the main display and all active secondary displays in a horizontal row with no gap on one black canvas. Keyboard focus uses a neutral status indicator without a focus outline. Selection and scroll position do not determine recording contents.

`CanvasComposition` draws decoded images into a tightly packed row with a common height, without padding, gaps or title bars. Screenshots use the main display and all active secondaries in the current scene, including screens outside the scroll viewport, and export one PNG up to 2160 pixels tall and 8192 pixels wide. Non-live frames carry status and date overlays inside their image area.

Recording uses the same composition through `AVAssetWriter` for silent H.264 MP4 at 12 fps. Output dimensions follow the combined aspect ratio, capped at 720 pixels in height and 2560 pixels in width without upscaling sources. The target bitrate follows the output area, capped at 1.6 Mbps. The recording roster starts with the main display and active secondaries, then adds active displays discovered during the session. Ended sources retain a dated last frame and status for that recording, independently of the current live scene.

The model writes internal clips to a hidden temporary directory when the roster, source aspect ratios or composition dimensions change. Each clip has stable dimensions, and previous clips finalize asynchronously while the next clip records. Stopping, switching devices and quitting finalize the outstanding clips and publish one MP4 at the chosen destination. A session with one clip does not need re-encoding.

For multiple clips, the final export uses the largest combined width-to-height ratio across the session, with a common height capped at 720 pixels and a width capped at 2560 pixels. Each clip is scaled proportionally to that height and aligned left. The images within a clip remain adjacent; no vertical padding is added. Narrower layouts leave empty space on the right, including the time before later screens appear. Combining takes place while the UI shows saving. Only the final published file enters recording history and Finder reveal. Successful publication removes the temporary clips; a failed export retains them for recovery.

An `NSSavePanel` chooses the destination for manual recording. The gear menu's automatic recording option defaults to off and persists through `UserDefaults`. `SecondaryAutoRecordingPolicy` starts when the selected device has an active secondary and a frame is available, and stops only automatic recordings when all secondaries become inactive or the option is disabled. Overlapping secondaries share a session. Manual stops and failures suppress restart until no secondary remains; saving defers new starts. Automatic files use a persistent directory, defaulting to `~/Movies/Scrcpy Viewer`, which can be selected or opened from the gear menu.

`RecordingHistoryCatalog` builds sidebar history from the selected recording directory and explicitly saved file URLs persisted locally in `UserDefaults`; it does not scan other directories. Entries refresh on launch, after saves and when the directory changes. Each entry presents a file timestamp and a thumbnail generated from an early local video frame through AVFoundation. Clicking an entry opens the file in the system default video player. Catalog loading and thumbnail generation do not start playback or send device input.

Recording does not capture the Mac desktop, inject device input or start audio. GIF export and audio playback are not implemented.

No remote service is exposed. Android's normal USB debugging authorization is required. Retained source frames live in memory; recording history refers to saved local video files. Diagnostic screen capture is opt-in and must remain outside source control. Screenshot exports, saved recordings and diagnostic artifacts are separate files.
