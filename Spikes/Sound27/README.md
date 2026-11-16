<!--
SPDX-FileCopyrightText: 2026 Tsukumo contributors
SPDX-License-Identifier: GPL-3.0-only
-->

# Spike 27 — Core Audio process tap

Command-line runner for DESIGN.md §2.4.1 and SPIKES.md #27.

```bash
swift run Sound27Spike             # list the process objects seen
swift run Sound27Spike <pid> [sec] # create a tap on the PID, collect N seconds
swift run Sound27Spike <bundle> --bundle  # on macOS 26, via bundleIDs
```

**Result 13 Nov 2026:** run from the unsigned CLI on macOS 27.0.1,
`kAudioHardwarePropertyProcessObjectList` returns 0 elements and
`AudioHardwareCreateProcessTap` answers `kAudioHardwareBadObjectError`
(`!obj`, 560947818). This is the Core Audio 14.2+ TCC gate: to use taps
`NSAudioCaptureUsageDescription` is needed in Info.plist and, with the hardened
runtime, an audio-capture entitlement. To be repeated from Tsukumo's signed
bundle, only when the Sound module is turned on.
