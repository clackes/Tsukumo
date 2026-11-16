<!--
SPDX-FileCopyrightText: 2026 Tsukumo contributors
SPDX-License-Identifier: GPL-3.0-only
-->

# Contributing to Tsukumo

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an [issue](https://github.com/clackes/Tsukumo/issues) with your Mac model, macOS version, Tsukumo version, which modules are on, and the steps to reproduce. For visual bugs a screenshot or a short screen recording helps a lot.

## Pull requests

1. Open an issue first for anything larger than a small fix, so we can agree on the approach.
2. Keep each pull request focused on one change.
3. Run `Tools/check.sh` before pushing: swift-format, SwiftLint, REUSE, tests and the app build must all be green.
4. Sign off every commit (`git commit -s`), certifying the [Developer Certificate of Origin](https://developercertificate.org/). By contributing you agree that your work is licensed under GPL-3.0-only, like the rest of the project.

## Rules that block a review

Tsukumo's main promise is that it costs nothing when idle. The full rules are in [Docs/DESIGN.md §5.2](Docs/DESIGN.md); the short version:

- **A module that is off costs zero:** no code running, no timers, no observers.
- No `Timer`/`DispatchSource` outside the module's `ResourceBag`, with at least 10% tolerance.
- Events before polling. Only do work when something is visible.
- Display links at 30-60 Hz only during animations; never `CVDisplayLink`.
- No global `.mouseMoved` monitor, no recurring subprocesses, no audio engine running without sound.
- No telemetry and no new network calls.

Code style: Swift 6 language mode with strict concurrency, `swift-format` and SwiftLint as configured, Swift Testing for tests. Every new file needs the SPDX header:

```swift
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only
```

## Third-party code

Only code under GPL-3.0-compatible licenses (MIT, BSD, Apache-2.0, ISC, GPL-3.0) can be added, with its copyright notice kept and an entry in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and `REUSE.toml`. Never copy AGPL code or code without a license.

## Security

Please do not report security problems in public issues. Use GitHub's [private vulnerability reporting](https://github.com/clackes/Tsukumo/security/advisories/new) instead.
