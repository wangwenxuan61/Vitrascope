# Vitrascope

Vitrascope is a lightweight, English-language system monitor for Apple silicon
Macs. It lives in the menu bar and presents live CPU, memory, GPU, temperature,
thermal-state, and fan readings in a native Liquid Glass panel.

## Requirements

- Apple silicon Mac
- macOS 26 or later
- Xcode 26.4 or later when building from source

GPU, temperature, and fan values are best-effort readings from hardware
interfaces that Apple does not expose uniformly. Vitrascope shows
`Unavailable` when a value is not published by the current Mac instead of
requesting administrator access.

## Install from a DMG

1. Download `Vitrascope-0.2.0-arm64.dmg` from
   [GitHub Releases](https://github.com/wangwenxuan61/Vitrascope/releases).
2. Open the DMG and drag Vitrascope to Applications.
3. Because the free release is not notarized with a paid Apple Developer ID,
   Control-click Vitrascope in Finder and choose **Open** the first time.
4. If macOS still blocks it, open **System Settings → Privacy & Security** and
   choose **Open Anyway** for Vitrascope.

Vitrascope never asks for a password, runs privileged commands, sends telemetry,
or connects to the network.

## Use

Click the waveform icon in the menu bar to open the monitor. The footer picker
changes the live menu-bar readout between CPU, Memory, GPU, Temperature, and
Icon Only. Choose **Quit** in the panel to stop Vitrascope.

## Build

Open `Vitrascope.xcodeproj` in Xcode 26.4 or later and run the `Vitrascope`
scheme. The target is intentionally arm64-only with a macOS 26 deployment
target.

To run the tests:

```sh
xcodebuild \
  -project Vitrascope.xcodeproj \
  -scheme Vitrascope \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGNING_ALLOWED=NO \
  test
```

To build the ad-hoc-signed DMG:

```sh
./scripts/build-dmg.sh 0.2.0
```

The DMG and its SHA-256 checksum are written to `build/`. Pushing a semantic
version tag such as `v0.2.0` runs the same build on GitHub Actions and attaches
both files to a GitHub Release.

## Distribution note

Ad-hoc signing does not satisfy Gatekeeper in the same way as Apple Developer ID
signing and notarization. A future notarized release can reuse the app and DMG
pipeline by replacing the ad-hoc signing step with Developer ID signing,
notarization, and ticket stapling.
