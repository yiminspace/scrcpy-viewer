# Contributing

Scrcpy Viewer is a native macOS client for watching Android displays and
controlling the main display. Improvements to display discovery, stream
reliability, accessibility and native interaction are welcome. Discuss larger
features in an issue before making broad architectural changes.

## Development

Use macOS 14 or newer and Swift 5.10 or newer. Xcode Command Line Tools are enough
to build; the XCTest suite requires a full Xcode installation. See the
[README](README.md) for the supported `adb` and scrcpy-server setup.

```sh
swift build
swift test
./scripts/build-app.sh
```

`ViewerCore` contains discovery, protocol parsing, session ownership and decoding.
`ScrcpyViewer` contains application state, AppKit input handling and SwiftUI views.
See [the architecture](docs/architecture.md) and [design notes](docs/design.md).
The icon is original vector artwork; regenerate it with
`swift scripts/render-icon.swift`.

Keep pull requests focused and explain the user-visible change. Add tests for
behavioral changes, especially protocol bytes, malformed input, source state
transitions, stale callbacks and resource ownership. State which checks were
actually run. If a check requires a device or full Xcode and was not run, say so.

Use a Conventional Commit title, for example `fix: reconnect a sleeping display`
or `feat: add a viewing layout`. Pull requests are squash-merged using that title;
validated changes on `main` drive automatic versions and release downloads.
See [the release guide](docs/releasing.md) for the supported types and recovery steps.

## Device behavior

- Only the main display may receive input, and only through explicit user actions.
  Secondary displays and retained history frames are view-only.
- Do not automatically wake or unlock a device, launch an app, keep a source
  display alive, or change another application's virtual-display lifecycle.
- Clean up only the sessions, forwarded ports and device files owned by this
  process. Do not kill the adb server or unrelated scrcpy sessions.
- Use the actual source-display state; absence of new frames is not proof of
  sleep or disconnection.

Use a device and test content you can safely operate when verifying input.
Describe any real-device actions in the pull request rather than assuming unit
tests prove that Android executed them.

## Fixtures and reports

Use synthetic device serials, display identities and application content in
tests. Do not commit device screenshots, personal content, credentials or source
code you do not have the right to contribute. Review diagnostic output before
sharing it: opt-in diagnostics can contain device metadata and visible screen
content. Supply a small redacted excerpt or a synthetic reproduction instead of
a complete device dump.

Report vulnerabilities privately according to [SECURITY.md](SECURITY.md).

## Licensing

Submit only work you have the right to contribute. Contributions to the original
application are made under its [MIT License](LICENSE), unless explicitly agreed
otherwise before submission. Keep third-party code and assets clearly attributed
and preserve their license terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for the external scrcpy server and other runtime dependencies.
