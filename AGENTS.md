# scrcpy-viewer

Native macOS Android display viewer. Swift 5.10, SwiftUI, macOS 14+.

- Main display supports explicit user mouse, keyboard and clipboard actions through scrcpy control. Secondary displays are strictly read-only, enforced in the core transport as well as the UI.
- Never inject input automatically, auto-wake/unlock, launch apps, or change another application's virtual-display lifecycle. A user-triggered wake button is allowed. Audio is currently disabled.
- Use a trusted local adb executable and the official scrcpy Android server pinned to 3.3.3. An optional server download must be explicitly requested and checksum-verified; never silently download or upgrade it. Keep runtime binaries outside the source tree.
- Preserve third-party attribution and licenses. Do not include proprietary source, credentials, personal account data, real device logs or device screenshots. Use synthetic test fixtures.
- Keep public code and documentation generic: do not add employer names, internal product names, internal package identifiers, service endpoints or operational examples from private environments.
- Discover and label secondary displays using generic Android display attributes; do not specialize behavior by app vendor or package name.
- Discover logical displays through adb and read the actual DisplayDeviceInfo state. Override DisplayInfo may report ON for a sleeping source.
- Exclude scrcpy-owned mirror displays. OFF and removed displays keep a clearly dated last frame, never pretend to be live.
- Own and clean only this process's adb forwards and server sessions. Never kill the adb server or other scrcpy sessions.
- Build with `swift build`; test protocol parsing and lifecycle invariants with `swift test`.
- Product UI must not promise an active stream until a frame has been decoded.
