# Third-party notices

Scrcpy Viewer is an independent macOS application. Its original application code,
documentation and icon artwork are licensed under the [MIT License](LICENSE).
That license does not replace the licenses of external tools or grant rights to
third-party names and trademarks. This is not an official Genymobile or scrcpy
project, and no endorsement is implied.

## scrcpy Android server

The application implements a client for the **scrcpy 3.3.3** protocol and runs the
corresponding Android server from [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy).
The server is a separate third-party component, licensed under **Apache License 2.0**.

The [upstream v3.3.3 license](https://github.com/Genymobile/scrcpy/blob/v3.3.3/LICENSE)
contains these copyright notices:

```text
Copyright (C) 2018 Genymobile
Copyright (C) 2018-2025 Romain Vimont
```

A copy is retained in [LICENSES/scrcpy-Apache-2.0.txt](LICENSES/scrcpy-Apache-2.0.txt).
The MIT license for this application does not relicense scrcpy.

No scrcpy server binary is committed to this repository. The runtime server can
be supplied by a compatible local installation or obtained separately from the
[official v3.3.3 release](https://github.com/Genymobile/scrcpy/releases/tag/v3.3.3).
Any optional installer must use an explicit user action, pin the compatible
version, verify its checksum, and store it in local application support rather
than the source tree. The application temporarily pushes the server to the
connected Android device and removes its own session files on shutdown.

If distributing a package that includes the server, retain the applicable
upstream license and notices with that package. Do not describe the server as
MIT-licensed or as code authored by this project.

## Android Debug Bridge (adb)

The application invokes a separately installed `adb` executable from Android SDK
Platform-Tools. It does not include or relicense that executable. Obtain it from
the [Android SDK Platform-Tools distribution](https://developer.android.com/tools/releases/platform-tools)
or a package manager, and refer to the notices accompanying that distribution.

## Apple frameworks

The application uses SwiftUI, AppKit, CoreGraphics, CoreImage, CoreMedia and
VideoToolbox supplied by macOS. No copies of these frameworks are included in
this source repository. They remain subject to Apple's applicable terms.
