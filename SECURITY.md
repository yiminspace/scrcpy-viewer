# Security policy

## Reporting a vulnerability

Please avoid public issues or pull requests containing exploit details, device
content, credentials or private logs. Use GitHub's **Report a vulnerability**
action in this repository's Security tab when it is available:

[Create a private security report](https://github.com/yiminspace/scrcpy-viewer/security/advisories/new)

If private reporting is unavailable, open an issue titled **Request for private
security contact** with no technical details, and ask the maintainer to arrange a
private channel. This project does not publish a guaranteed response time.

Include the affected revision, macOS and Android versions, relevant dependency
versions, impact, and a minimal reproduction using synthetic data where possible.
Do not include access tokens, personal screen captures, complete device dumps or
an unrestricted adb connection.

## Scope

The current development branch is the primary target for fixes. There is no
commitment to maintain security fixes for older revisions.

Relevant issues include unintended input sent to a secondary display, executing
unexpected host commands, unsafe handling of device-supplied data, leaking
clipboard or screen content, unsafe dependency downloads, or cleaning up another
process's resources. Vulnerabilities in scrcpy, adb or macOS should also be
reported to the corresponding upstream project; mention their impact here when
it affects this client.

## Local trust boundaries

Scrcpy Viewer runs `adb` and a compatible scrcpy Android server. Those are
executables, not passive configuration: use trusted installations and verify any
downloaded server against the pinned official release. The configured executable
paths must be treated with the same care as any program you run locally.

The application does not expose a remote control service.
Device control uses the Android debugging authorization granted to adb.
It is not a sandbox for a malicious host executable or an untrusted Android device.

Normal use retains display history in memory. Explicit screenshot exports and
opt-in diagnostics write data to the chosen local directory. Diagnostic output
can contain screen content and device identifiers; clearing the application's
history does not delete separately exported images or diagnostic artifacts.
