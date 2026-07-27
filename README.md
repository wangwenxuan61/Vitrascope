# Vitrascope

Vitrascope is a lightweight, English-language system monitor for Apple silicon
Macs. It lives in the menu bar and presents live CPU, memory, GPU, temperature,
thermal-state, and fan readings in a native Liquid Glass panel.

CPU and Memory cards also show the three processes currently consuming the
most CPU time or memory. Process rankings refresh every two seconds and remain
entirely on the Mac.

## Requirements

- Apple silicon Mac
- macOS 26 or later
- Xcode 26.4 or later when building from source

GPU, temperature, and fan values are best-effort readings from hardware
interfaces that Apple does not expose uniformly. Vitrascope shows
`Unavailable` when a value is not published by the current Mac instead of
requesting administrator access.

## Install from a DMG

1. Download `Vitrascope-0.4.0-arm64.dmg` from
   [GitHub Releases](https://github.com/houou81/VitrascopeLW/releases).
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

The menu-bar value uses five independently rendered fixed-width cells: three
for the number and two for the unit. Empty leading cells keep values such as
`9%`, `60%`, `61%`, `100%`, and `63°C` in exactly the same layout. Each glyph
has its own fixed coordinate, so neither font fallback nor a changing reading
can move the waveform icon or adjacent value columns.

## Lightweight performance design

This branch keeps the UI and collector features from `origin/main`, while
replacing its always-on one-second full collection loop with demand-based,
tiered sampling:

| State | Active sampling |
| --- | --- |
| Panel closed, CPU selected | CPU every 1 second |
| Panel closed, Memory selected | Memory every 2 seconds |
| Panel closed, GPU selected | GPU every 2 seconds |
| Panel closed, Temperature selected | Temperature and fans every 5 seconds |
| Panel closed, Icon Only | No periodic sampling |
| Panel open | CPU every 1 second; Memory, GPU, and processes every 2 seconds; temperature and fans every 5 seconds |

The implementation also:

- keeps one SMC connection open, caches key metadata, and polls only sensor keys
  that succeeded during the initial probe;
- invokes the HID temperature reader only when SMC has no CPU temperature;
- retains valid GPU IOKit service handles and re-enumerates only after they
  become invalid;
- publishes one combined monitor state per update and does not maintain chart
  history while the panel is closed;
- stores three 30-point histories in fixed-capacity ring buffers and adds chart
  points at most every two seconds;
- draws one linear `LineMark` per chart instead of an area plus interpolated
  line; and
- listens for thermal-state notifications and gives sampling sleeps a 10%
  tolerance so macOS can coalesce wake-ups.

### Measured improvement

The following results come from 15-second optimized sampling probes on the same
Apple silicon Mac, compared with the full-polling `origin/main` loop. They
measure collector and scheduler work in optimized builds, excluding SwiftUI and
AppKit rendering. Values are reductions relative to the upstream baseline:

| Mode | CPU cycles | Context switches |
| --- | ---: | ---: |
| Panel closed, CPU | 83% lower | 86% lower |
| Panel closed, Memory | 89% lower | 90% lower |
| Panel closed, GPU | 87% lower | 89% lower |
| Panel closed, Temperature | 80% lower | 77% lower |
| Panel closed, Icon Only | 92% lower | 96% lower |
| Panel open | 74% lower | 63% lower |

These figures are directional rather than universal benchmarks: results vary by
Mac model, available sensors, process count, and system load. Full-app memory
should still be evaluated with a longer Release run and Instruments because
SwiftUI, Charts, and the system allocator retain their own caches.

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
./scripts/build-dmg.sh 0.4.0
```

The DMG and its SHA-256 checksum are written to `build/`. Pushing a semantic
version tag such as `v0.4.0` runs the same build on GitHub Actions and attaches
both files to a GitHub Release.

## Distribution note

Ad-hoc signing does not satisfy Gatekeeper in the same way as Apple Developer ID
signing and notarization. A future notarized release can reuse the app and DMG
pipeline by replacing the ad-hoc signing step with Developer ID signing,
notarization, and ticket stapling.
