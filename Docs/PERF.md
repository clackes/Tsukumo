<!--
SPDX-FileCopyrightText: 2026 Tsukumo contributors
SPDX-License-Identifier: GPL-3.0-only
-->

# Tsukumo power consumption: measurements

Acceptance criterion: budget of DESIGN.md §5.1 and rules §5.2 and §4.2.

## Method

- App: `/Applications/Tsukumo.app` 0.1.4, Release build of the working tree of 15 Nov 2026 (no source newer than the binary). The A/B tests use Release builds in `~/Library/Caches/tsukumo/DerivedData`.
- Mac: macOS 27.0.1, arm64, built-in display 1710×1112 points. Screen on, no interaction during the measurements.
- Tool: `Tools/perf/measure.sh <label> <seconds> <modules|keep|none>`. Restarts the app with the given modules, waits 40 s, then samples with `top` every 5 s: average and peak CPU, idle wakeups/s, threads. At the end it reads `footprint`. It covers Tsukumo, the adapter's perl, Converter.xpc and, as a hint of out-of-process costs, WindowServer.
- Not measured by an agent: GPU and power (they require `powermetrics`, hence sudo), lock screen, interactions (panels, Switcher, Snap). The steps are at the bottom.

**Beware of noise.** A single measurement is not enough. The first scenario 4a, started 15 s after the music began, gave 9.1% CPU and WindowServer at 28.9%. Repeated under equal conditions it gave 3.8% and 2.7%. A/B tests must be repeated in the same state (track already playing for more than a minute, island idle). WindowServer's CPU in scenarios 1–2 is affected by the activity of the rest of the system and is not attributable to Tsukumo.

## Baseline measurement (15 Nov 2026)

| Scenario | Average CPU | Peak | Wakeups/s | Threads | Footprint | Children | §5.1 budget |
|---|---|---|---|---|---|---|---|
| 1. All modules off, 300 s | 0.00% | 0.0% | 0.00 | 3 | 11 MB | none | < 0.05%, 0, ≤ 35 MB: **ok** |
| 2. Island alone, 180 s | 0.00% | 0.1% | 0.04 | 4 | 28 MB | perl 0.00%, 5.0 MB | 0%, 0, +8 MB (+12 perl): **ok** (+17 MB app; the footprint includes the 2 windows and the cover art) |
| 2. Snap | 0.00% | 0.1% | 0.03 | 3 | 11 MB | – | **ok** |
| 2. MenuBar | 0.00% | 0.1% | 0.01 | 3 | 13 MB | – | **ok** |
| 2. Monitor (item hidden by the user) | 0.00% | 0.0% | 0.01 | 3 | 12 MB | – | **ok** (with the item hidden it does not sample, correct) |
| 2. Clack | 0.00% | 0.0% | 0.01 | 4 | 12 MB | – | **ok** (no audio engine at rest) |
| 2. Convert | 0.00% | 0.0% | 0.01 | 3 | 11 MB | no Converter.xpc | **ok** |
| 2. Duo | 0.23% | 0.3% | 2.57 | 5 | 12 MB | – | documented exception (sensor 5–10 Hz): **ok** |
| 2. Sound | 0.00% | 0.0% | 0.01 | 3 | 13 MB | – | **ok** (no tap: no app with volume ≠ 100%) |
| 2. Switcher | 0.00% | 0.0% | 0.01 | 4 | 11 MB | – | **ok** |
| 3. All on, 300 s | 0.68% | 12.0% | 5.11 | 6 | 33 MB | perl 0.02%, 5.6 MB | < 1%, ≤ 120 MB: **ok** (Duo included; the peak is the modules restarting) |
| 4a. Music, compact island (first measurement, noisy) | 9.13% | 9.7% | 67.9 | 9 | 84 MB | perl 0.00% | see below |
| 4a. Music, compact island (repeated) | **3.83%** | 4.1% | **17.6** | 9 | **88 MB** | perl 0.00%, 5.7 MB | no figure for compact (exception §5.1). Expanded: < 1.5% |
| 4z. Right after pausing, 60 s | 0.30% | 0.9% | 2.37 | 8 | 34 MB | – | back to rest: **ok** |
| 4b. Music, island open | see bench below | | | | | | in the app it needs the pointer to hover (below) |
| 5. Locked screen with music | not measured | | | | | | needs the user (below) |
| 6. Panels, Switcher, Snap | not measured | | | | | | needs the user (below) |

Modules off (§4.2): in scenario 1 the process has 3 threads, 0 wakeups and 11 MB, and the modules do not start. `Tools/zero-cost/macho-check` passes on the Release build. The `sample` of scenario 1 shows no module code.

## Analysis

Only scenario 4a is above the expected zero. The scenarios at rest are all within budget and require no action.

### Island with music: three SwiftUI redraws per frame

`sample` of scenario 4a (8 s, 3605 samples on the main thread) and of the open-island bench (below):
- on every frame `NSDisplayCycleFlush`, then `NSHostingView.layout()` over the whole island tree, then `CA::Transaction::commit`, then `RBLayer display` and RenderBox's Metal rendering (`SharedSurfaceGroup::render_updates`);
- `footprint` in 4a: 46 MB of `Owned physical footprint (graphics)` (RenderBox Metal surfaces) that disappear when the music stops.

The causes, all of them time-driven SwiftUI animations inside the island window:

| Cause | Where | Effect |
|---|---|---|
| `.symbolEffect(.variableColor.iterative)` on the wave | compact island | layout and rendering of the whole island on every frame; on its own, in a test window, the symbol costs 5% |
| `ProgressView(timerInterval:)` of the time bar | open island and lock screen player | continuous panel layout: **one core at 100%** in the bench |
| `TimelineView` at 12 Hz with `.animation(_:value: time)` | open island equalizer | continuous interpolation, which also redoes the blur of the cover art underneath |

### Fix: continuous animations in Core Animation

Continuous animations are now Core Animation layers with infinite animations, computed by the render server; SwiftUI stays still:
- `IslandBars` (`IslandBars.swift`): the wave is the real `waveform` symbol drawn once and split into its bars (pixel columns), with the highlight sweeping from left to right like `variableColor.iterative`. The equalizer uses the same sine formula as before, sampled into one `CAKeyframeAnimation` per period and in phase with the clock.
- `LiveProgressBar` (`IslandLiveProgress.swift`): a capsule with a single linear `CABasicAnimation` from the current position to the end of the track.
- New "While playing" option: **Wave** (default, looks like before), **Colored bars** (the open island's bars in the cover art's colors, also when compact) or **Still**.
- DESIGN.md: updated the Island row of §5.1 and the exception; new rule 12 in §5.2.

Check that the animation really runs: `IslandBarsTests` mounts the bars and the real `IslandView` (compact and open) in real windows, checks that every bar has the animation and that the presentation layer changes over time, and that the time bar starts from the right position and grows. The visual judgment is left to the user (comparison probe below).

### Before/after

Island bench (`IslandBarsTests.costBench`, real window with the `IslandView`, tests built in release, 45 s, before and after alternated twice; the "before" version is a copy of the package with the original SwiftUI views):

| State | CPU before | CPU after | Wakeups/s before → after | Footprint before → after |
|---|---|---|---|---|
| Compact, wave | 15.6% · 12.7% | 0.00% · 0.00% | 4.2 · 15.8 → 0 | 69 → 14 MB |
| Compact, colored bars | – | 0.00% · 0.00% | → 0 | 13 MB |
| Compact, still | – | 0.00% | → 0 | 13 MB |
| Open | 101.9% · 101.9% | **0.34% · 0.46%** | 0 → 0.2–0.3 | 21 → 21 MB |

Real app, scenario 4a (music playing for more than a minute, 60 s wait, 120 s measurement, before and after alternated twice):

| | Before | After |
|---|---|---|
| Tsukumo CPU | 17.6% · 4.2% | **0.33% · 0.34%** |
| Wakeups/s | 29.1 · 14.7 | **2.8 · 2.2** (these are Duo's: the island no longer adds any) |
| Footprint | 86 · 88 MB | **33 · 33 MB** |
| WindowServer | 19.5% · 3.3% | 1.5% · 1.6% |
| adapter perl | 0.01% · 5.8 MB | 0.01% · 5.6 MB |

During the tests this Mac's WindowServer was between 33 and 47% on behalf of other apps (the Claude app in the foreground), so its Δ is only a hint: it drops by about 4 points in the open-island bench, in both repetitions.

Discarded attempts:

| Attempt | Outcome |
|---|---|
| `symbolEffect` in a separate `NSHostingView` | 5.33% versus 3.83%: no improvement, dropped |
| `NSImageView.addSymbolEffect` (AppKit) | not verifiable: inside the SwiftUI hosting the effect does not appear to be active; discarded |

### Other checks (static, no problems found)

| Resource | Interval | Tolerance | When it stops |
|---|---|---|---|
| `SharedSampler` (Monitor) | 1 s with popover open, 5 s in background, 10 s in Low Power | 25% | no subscribers, screen off, session locked; hidden item = no subscribers |
| Duo `idleWatch` | 100 ms, 200 ms after 5 s still | 15% | screen off; fold session active |
| Duo `tick` | 16 ms | `ResourceBag` default | end of the fold |
| Clack `idleTimer` | 5 s | 2 s | engine stopped |
| `IslandLockMedia` reveal | once (`revealDuration`) | 10% | after the snap |
| Energy (Settings) | 2 s | 400 ms | page closed |
| Island display link | 30–60 Hz | – | end of the morph |

- All timers go through the `ResourceBag`. The only `DispatchSource` outside the bag is Switcher's signal (`makeSignalSource`): it is an event source for restoring ⌘⇥ (§2.2.1), not a timer.
- Lock screen background: a CA animation that stops (`speed = 0`) when the music is paused, alpha 0 and the panel closed outside the lock. The live cost is measured in scenario 5; that player's time bar has already moved to `LiveProgressBar`.
- Sound: tap only for apps with volume < 99.9% or with their own output; `syncIO` stops the IO when the app is not playing.
- The island's glow window stays off screen when the island is compact: verified with `CGWindowListCopyWindowInfo`.

## Visual comparison

A window with the old wave, the new one and the colored bars, side by side, for 60 s:

```sh
cd Packages/Modules/Island && TSUKUMO_ISLAND_COMPARE=60 swift test --filter compareProbe
```

## To measure with the user

### Power and GPU (sudo)

With Tsukumo on and the music playing for at least a minute (compact island), in Terminal:

```sh
sudo powermetrics --samplers tasks,cpu_power,gpu_power --show-process-energy --show-process-gpu -i 5000 -n 24 > ~/Desktop/pm-musica.txt
```

Then the same with the music paused (`pm-pausa.txt`). Send me the two files. I read the lines for Tsukumo, WindowServer, coreaudiod and `GPU Power`.

### Scenario 4b: open island with music

1. Music playing for at least a minute.
2. Run `Tools/perf/measure.sh s4b-isola-aperta 120 keep` and, as soon as it starts, keep the pointer still on the open island for the whole 2 minutes.
3. Send me the printed lines.

### Scenario 5: locked screen with music

1. In Settings leave the player, side text and cover art as background on (they already are).
2. Start the music, then run in Terminal `sleep 20; Tools/perf/measure.sh s5-blocco 120 keep > ~/Desktop/s5.txt`.
3. Within 20 s lock the screen (⌃⌘Q) and leave it locked, with the display on, for 2 and a half minutes.
4. Unlock and send me `~/Desktop/s5.txt`.

### Scenario 6: panels and interactions

For each line, run the command and then perform the action for the whole duration of the measurement:

- `Tools/perf/measure.sh s6-monitor 60 keep`: Monitor popover open (requires the item to be visible).
- `Tools/perf/measure.sh s6-sound 60 keep`: Sound popover open, with music.
- `Tools/perf/measure.sh s6-switcher 60 keep`: ⌘⇥ repeated every 2–3 s.
- `Tools/perf/measure.sh s6-snap 60 keep`: drag a window toward the edges for the whole minute.
