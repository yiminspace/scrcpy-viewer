# Architecture

`ViewerCore` owns dependency resolution, bounded adb commands, logical display discovery, the scrcpy 3.3.3 wire protocol, capture/control sessions and H.264 decoding. `ScrcpyViewer` owns SwiftUI state and presentation.

The runtime dependencies are a trusted local `adb` executable and the official scrcpy Android server matching protocol version **3.3.3**. A compatible local installation can supply the server. An optional installation flow must fetch that fixed official release only after an explicit user action, verify its pinned checksum, and store it outside the repository. It must not silently replace another installed scrcpy version. The application is an independent client; scrcpy's Apache-2.0 license remains separate from the application's MIT license. See [third-party notices](../THIRD_PARTY_NOTICES.md).

Discovery is serialized. The matching `DisplayDeviceInfo` is the source of truth for ON/OFF; `mOverrideDisplayInfo` is not. Display identity combines device serial, logical ID and unique ID, so an ID reused by a different virtual display is a new item.

Each capture session has its own server jar path, random scid and adb forward. Main display 0 opens video and control channels; secondary displays open video only, enforced by the transport. All use `audio=false`, `power_on=false`. The client validates the dummy byte, device metadata, H.264 codec header, packet sizes and frame flags. Config NAL units update the decoder; subsequent video packets maintain their dependency chain. Rendering uses decoded frames and retains the last image after the source ends.

Control messages are generated only by explicit user actions. Input targets the main display, using the current decoded video dimensions and the fitted image rectangle. Retained frames and secondary displays never accept control. Merely discovering a display or changing selection must not inject input.

The UI isolates stream callbacks by generation. An old session cannot update the new session's card after an OFF→ON transition or device switch. The stream is only described as live after a frame has actually decoded. Static images are not disconnected merely for lacking new frames.

`DisplayScenePolicy` keeps inactive secondary displays in folded history, separate from the live stage. Explicit history selection reveals a cached frame without restarting capture. Clearing history releases frames and remembers full identities until those sources become active again; an OFF display still enumerated by Android does not immediately reappear. Main-screen input focus suppresses automatic follow for that arrival only, so it is never replayed after typing ends.

Discovery uses Android logical display IDs and source-display metadata. Availability and capturability depend on the device and the application that owns the display. All secondary displays follow the same discovery and read-only capture rules.

Audio playback and video-file recording are not currently implemented. H.264 packets are decoded for viewing; saving the current image exports a PNG rather than a video.

No remote service is exposed. Android's normal USB debugging authorization is required. History frames live in memory. Diagnostic screen capture is opt-in and must remain outside source control; clearing in-app history does not delete separate screenshot exports or diagnostic artifacts.
