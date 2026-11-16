# Tsukumo: design document

**All-in-one macOS toolkit, open source, native to Apple Silicon and with near-zero power consumption.** "One app instead of twelve."

Version 1.4 of 12 November 2026. Author: lead architect. Status: proposal to be approved.

> **What's new in 1.4 (brainstorming with the maintainer, 12 Nov 2026).** **Dropped:** Phase 0.5 and the 15 December launch, `Tile`, `WatchSudo` (`sudo` with the Apple Watch: with it §2.4.1, the PAM module and spikes 11 and 14), `Home` (Home Assistant, Tsukumo Home on the Mac App Store, Matter) and `Remote` (trackpad/keyboard from iPhone, media and slide remote from the Watch). **Merged:** the cursor from iPhone, Apple Watch and AirPods is a single module, `Pointer` (§2.4); the Watch's gyroscopic pointer, excluded in 1.3, comes back into the product. **Convert** takes Tangerine's flow as a requirement: a radial picker that appears **during a file drag while holding ⌘** (§2.5). **Duo** is a priority and moves to the Mac-only modules phase. **Release:** a single public release, 1.0, with all the modules, preceded by a testing and bug-fixing phase (§9). Sections 1, 2, 9 and the spike table are updated; **the residual references to Home, Tile and Remote in sections 3‑8 are superseded by this note** and get cleaned up when the section is touched.

> **What's new in 1.3.** Removed "Unlock with iPhone" (a product decision on security, §7.2). Added the **Windeck** module: iPhone and iPad as the Mac's Stream Deck (§2.6, §7.3). The Apple Watch gyroscopic pointer becomes a media and presentation remote. Applied all the fixes from review r3: Island hit-testing, private API processes, multicast EventBus, `ModuleDescriptor`, TOCTOU-safe installation of WatchSudo, attack surface of `tsukumo://`, MetricKit on macOS, Input Monitoring, battery criterion, arm64e, GPL‑3.0‑only.

---

## 1. Executive summary and name

**Name: Tsukumo.** It comes from *tsukumogami* (付喪神): in Japanese folklore, tools that gain a soul after a hundred years of service. The app is a toolbox of tools that live inside the Mac.

**The modules.** Tsukumo has **10 modules** (12 Nov 2026: added `Sound`, dropped `Pointer`). **Maintainer decision, 12 Nov 2026: no native app on iPhone, iPad or Apple Watch.** Everything that goes through the phone uses what the phone already has (Safari, Shortcuts, AirDrop); the sections on "Tsukumo Remote", watchOS and `Pointer` are superseded by this note. The slogan "one app instead of twelve" stays as the origin of the working name, not as a count.

| # | Module | What it does / reference app | Status as of 12 Nov 2026 |
|---|---|---|---|
| 1 | `Island` | Notch as a Dynamic Island (NotchNook / boring.notch) | in the repo, needs polish |
| 2 | `Snap` | Window snapping (Rectangle) | in the repo |
| 3 | `MenuBar` | Menu bar icons (Bartender / Ice) | in the repo, backend to be rethought (spike 22) |
| 4 | `Monitor` | System monitor (iStat Menus / Stats) | in the repo |
| 5 | `Clack` | Mechanical keyboard sounds (Klack) | in the repo |
| 6 | `Convert` | File conversion and quick tools, with the ⌘‑drag flow (Tangerine) | tier 0, tools and tier 1 (LGPL ffmpeg in the helper) done |
| 7 | `Duo` | Animation tied to the MacBook hinge (iPhone Duo) | done (spike 7 go on Air M4) |
| 8 | `Switcher` | Alt‑Tab with thumbnails (AltTab) | done (⌥⇥ by default, ⌘⇥ optional; spike 6 partial) |
| 9 | ~~`Pointer`~~ | ~~iPhone, Apple Watch and AirPods as an air cursor~~ | **dropped (12 Nov 2026)**: no native apps on the phone |
| 10 | `Windeck` | iPhone and iPad as a Stream Deck (Elgato Stream Deck Mobile) | to do |
| 11 | `Sound` | Per-app volume mixer, per-app output, quick output switching, Music blocker (SoundSource / FineTune / noTunes) | to do (added on 12 Nov 2026) |

**Dropped in 1.4:** `Tile`, `Home`, `Remote`, `WatchSudo`. They are not reintroduced without a new decision by the maintainer.

**The bundle id and the Team ID must be decided before any signed build.** The TCC identity (bundle id plus designated requirement), the Keychain access groups, the App Group, the `tsukumo://` URL scheme, the Sparkle feed (`SUFeedURL` in Info.plist), the Developer ID provisioning profile and the name of the Homebrew tap all depend on this choice. Changing it after launch means making every permission start over and migrating the feed.
- If we register `tsukumo.app` (about $15 a year): bundle id `app.tsukumo.mac`, feed `https://tsukumo.app/appcast.xml`.
- If the domain is not available: `io.github.tsukumo-app.mac`, with the feed on GitHub Pages `https://tsukumo-app.github.io/appcast.xml`. We only use domains we really control.
- **Developer account:** we enroll as an individual. Activation usually takes a few days. An organization account requires a D‑U‑N‑S number and can take weeks, and moving later from individual to organization changes the Team ID, with the same TCC and Keychain reset. The choice must be made by 12 November and is not changed again.
- **Until 12 November** we work with a provisional bundle id, local only (`dev.local.tsukumo`), never signed with Developer ID and never published.
- **No launch date depends on this check anymore**: the 15 December launch is cancelled (§9). Name, bundle id and Team ID must still be fixed before the first signed build.

**Thesis.** Every function we want already exists in some open source app: boring.notch, Rectangle, Stats, AltTab, Thaw, Itsyhome. None of them puts them together, though:
- with a single modular architecture whose modules **cost zero when off** (in the measurable sense defined in §4.2);
- with a single coherent Liquid Glass UI;
- with permissions requested only when needed;
- notarized, with signed updates and total privacy.

Tsukumo's value lies in this integration, not in the individual features. Our advantage is discipline: energy, permissions, coherence, maintenance.

**Key decisions**

1. **GPL‑3.0‑only license for the whole project (Mac app, protocol, companion code and module SDK).** This is the most important choice in the document: the best references (boring.notch, Atoll, AltTab, DockDoor, Thaw and Loop) are GPL‑3.0. Contributions come in through pull requests with the DCO (`Signed-off-by`). Third-party code is accepted only under licenses compatible with GPL‑3.0 (MIT, BSD, Apache‑2.0, ISC, GPL‑3.0), with notices preserved; never AGPL or unlicensed code. The full reasoning is in §8.
2. **Build with the Xcode 27 SDK and Swift 6.4 (the version included in Xcode 27 and 27.1), deployment target macOS 26.0, arm64 only.** SwiftUI, with AppKit where needed.
3. **A single main process** with on‑demand XPC services, which isolate heavy work and the private APIs that can live outside the app (the others stay in the app, §4.1).
4. **Developer ID distribution**: notarization, Sparkle 2, Homebrew cask. No Mac App Store, except for the HomeKit bridge.
5. **Zero telemetry.** The only network calls are the Sparkle appcast and a signed `compat.json`. Diagnostics are local only (MetricKit and crash logs), see §3.6.
6. **Funding** through GitHub Sponsors and Buy Me a Coffee. No paywall.

> **Environment (November 2026).** macOS 27 is out and is the current release. macOS 26 Tahoe is the previous release, still widespread, and is the last one with Intel support. The 27.x updates are in public and developer beta. Hints from the ecosystem: Thaw 3.0 is the "for macOS 27" line (Thaw's FREQUENT_ISSUES.md, checked on 2026‑11‑09); mediaremote-adapter was tested on 27.0 beta on 2026‑09‑04 (README badge) and must be rechecked on the final 27.x. The design covers **26.x and 27.x** from day one:
> - it is built with the 27 SDK and runs on 26.0 and later;
> - APIs introduced only in 27 sit behind `if #available(macOS 27, *)`;
> - CI tests on both versions and, every week, also on the latest 27.x beta (§3.4).

---

## 2. The functions, one by one

Legend: **feasible** = public or stable private APIs; **partial** = works with structural limits; **hack only** = works only with fragile workarounds or security compromises; **impossible** = Apple does not allow it.
Battery: cost level with the module **on and at rest** / **in active use**. Unverified entries have been removed from the tables that drive decisions and moved to **Appendix A**. In the "Tools studied" columns, the word *reference* indicates a repo to read but not to use as a dependency (criterion in §8.2).

### 2.1 "Dynamic Island" notch (module `Island`)

| Function | Verdict | Approach | APIs / Permissions | Battery | Tools studied |
|---|---|---|---|---|---|
| Notch overlay window | feasible | Nonactivating, borderless `NSPanel`, level `.mainMenu+3`, behavior `[.canJoinAllSpaces,.stationary,.fullScreenAuxiliary,.ignoresCycle]`. **The panel frame follows the state**: when collapsed it covers only the physical area of the notch, where there are no clickable items; it grows only on expansion. Hit-testing and energy costs are in §2.1.1. The geometry comes from `safeAreaInsets.top` and `auxiliaryTopLeft/RightArea`. On Macs without a notch and on external displays the notch becomes a "pill" (§2.1.1). "Show on lock screen" option via SkyLight. | AppKit; no permissions. Private SkyLight (opt‑in). | 0 / low | [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) (MIT), [NotchDrop](https://github.com/Lakr233/NotchDrop) (MIT), [boring.notch](https://github.com/TheBoredTeam/boring.notch) (GPL), [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) (MIT) |
| Now Playing (cover art, controls, progress) | partial | `MediaBackend` protocol with 3 implementations, in this order: 1) mediaremote-adapter in `stream` mode (perl child process); 2) DistributedNotifications from Music/Spotify; 3) AppleScript for extras (favorites). `test` health check at startup. Progress is computed from timestamp and rate, with no timer. The visualizer is fake, spring-based, with a Metal `.colorEffect` at 30 fps, active only when expanded. | MediaRemote through `/usr/bin/perl`. Automation (Apple Events) only for the AppleScript backend, with the `com.apple.security.automation.apple-events` entitlement (§3.8). | ~0 / low | [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD‑3), [ejbills fork SPM](https://github.com/ejbills/mediaremote-adapter) (BSD‑3), [MewNotch](https://github.com/monuk7735/mew-notch) (GPL) |
| Battery / charging | feasible | `IOPSNotificationCreateRunLoopSource` and `NSProcessInfoPowerStateDidChange`. 3 s animation when the cable is plugged in, with the SF Symbol `battery.100percent.bolt` and `symbolEffect`. AirPods battery read only at connection time (undocumented IOBluetooth properties). | IOKit.ps; Bluetooth only for AirPods. | 0 / 0 | boring.notch (GPL) |
| Calendar / reminders | feasible | EventKit with full access, `EKEventStoreChanged`, a single one‑shot timer up to the next event boundary. "In 5 min" live activity with a "Join" button, derived from parsing Meet, Zoom and Teams URLs. | Calendars and Reminders (TCC); hardened runtime entitlement for calendars (§3.8). | 0 / 0 | boring.notch (GPL) |
| Replace macOS volume/brightness HUDs | hack only (opt‑in) | **Revised on 12 Nov 2026 at the maintainer's request** (it was previously excluded). With the option on, the shared active tap consumes the volume, mute and brightness keys (`NX_SYSDEFINED`, subtype 8): this way the system HUD does not appear, and Tsukumo sets the volume via CoreAudio and the built-in display's brightness via DisplayServices, showing a bar under the notch. ⌥+key is left to the system (opens Settings). We handle only what we know how to adjust: audio outputs without volume control and external displays are left to the system. Off by default; Settings shows the permission state and asks for them explicitly. No feedback sound and no HUD for keyboard backlight. | Accessibility (active tap); Input Monitoring if macOS requires it (spike 6). DisplayServices is private. | 0 / burst on key | MewNotch, SlimHUD (reference only) |
| Lock and lock screen | partial (opt‑in for the lock screen) | `com.apple.screenIsLocked`/`screenIsUnlocked` (distributed notifications): closed padlock while the screen is locked, opening animation on unlock. For the island to be visible **on** the lock screen, panel and glow are moved to a SkyLight Space at absolute level 400 (private APIs, opt‑in, off by default) **only while the screen is locked**: they enter at lock and return to the normal Space once unlocked (15 Nov 2026). Left there permanently, they were composited above the image of the dragged files and the system did not consider them drop targets, so the shelf did not receive the files. | No permissions. Private SkyLight. | 0 / 0 | SkyLightWindow (MIT, reference) |
| File shelf in the notch | feasible | Global `leftMouseDown/Dragged/Up` monitors, active only during drags, plus the comparison of `NSPasteboard(name:.drag).changeCount` and a hit‑test on the hot‑zone. When the drag enters the hot‑zone the panel expands and accepts the drop. Accepted with `.onDrop`/`NSFilePromiseReceiver`, security‑scoped bookmarks, `QLThumbnailGenerator`, drag‑out. | No permissions. | 0 / low | NotchDrop (MIT), boring.notch (GPL) |
| AirDrop from the shelf | partial | An "AirDrop" zone inside the shelf: on drop it calls `NSSharingService(named:.sendViaAirDrop).perform(withItems:)`. The system picker opens anyway, because there is no API to list peers. | AppKit; no permissions. | 0 / 0 | NotchDrop, boring.notch (`ShareServiceFinder`) |
| iPhone-style AirDrop animation | feasible | Concentric ripples with `phaseAnimator`, icon flight with `matchedGeometryEffect` and `.spring(response:0.45,dampingFraction:0.8)`, `symbolEffect` on the `airdrop` symbol if it exists and can be used by third parties in the current SF Symbols version (to be checked in the SF Symbols app and its terms), otherwise `dot.radiowaves.left.and.right`; final morph to a check on `didShareItems`. No Lottie. | SwiftUI. | 0 / burst < 1.5 s | boring.notch (concepts) |
| **Lock screen with Now Playing** (maintainer's request, 12 Nov 2026; redesigned on the evening of 12 Nov: background = cover art; 13 Nov: "Canopy" approach with our UI above the system lock screen) | partial (opt‑in, private APIs) | **Current state (14 Nov 2026, redesign modeled on the iOS lock screen player):** a single interactive `NSPanel` in the lock screen's SkyLight Space, a **glass card** (Liquid Glass) tinted with the cover art's average color, centered in the free band between the clock (up to 25% of the height) and the profile picture (from 80%): large square cover art (it shrinks a little when paused, no continuous animation), title and artist, clickable and draggable time bar with elapsed and remaining time below, ⏮ ⏯ ⏭, system output volume, a pill with the current output that opens the list of outputs inside the card. Height = free band (at most 540 pt), width = cover art + margins. No background panel, except for the option below. **Cover art as background (15 Nov 2026, opt-in):** with "Use the cover art as background" a second full-screen `NSPanel`, one level below the player, covers the clock, profile picture and password field like a screen saver. Cover art arrives at about 600 px: enlarged it gets grainy, so the background is the cover art **blurred while small** (at most 512 px, Core Image, 16 bits per channel against banding) and then enlarged by the layer; the sharp cover art stays in the player. **Composition (15 Nov 2026):** the cover art is square and centered, 1.25 times the short side of the screen tall (about a tenth is lost above and below; at 1.0 it looked small), just softened (blur 0.5% of the side) and with the sides fading to transparent; the fade is computed in the image with Core Image, once per track, with no CA masks, which would cost an offscreen pass at every composition. On the sides, the same cover art heavily blurred (12%) and darker fills the screen. Before, the cover art filled the screen (on a wide screen a third of it was lost and it looked zoomed), blurred at 7%, with zoom 1.15 → 1.34 and lateral drift. A slow zoom around the center (1.00 → 1.06, back and forth) is a `CAAnimation` (composited by the system, no per-frame code), stopped when paused and with Reduce Motion. A click on the background moves it aside for 12 s (one-shot timer in the `ResourceBag`) and shows the macOS login; Touch ID and the typed password work anyway. Without cover art the window is transparent and lets clicks through. **Text next to the player (14 Nov 2026, opt-in):** with the "Show the text next to the player" checkbox (active only with the player on; since 15 Nov independent of the lyrics in the island: the two checkboxes are chosen separately and LRCLIB is queried if at least one is on, §3.6) a second glass card, as tall as the player and 1.2 times as wide, shows the synced lyrics on the right; the player + lyrics block is centered. The current line is solid and centered, the others dimmed; it animates only on line change, which comes from Island's existing per-line timer (no extra timer). It works for any app that plays (Music, Spotify, browsers): the lyrics are looked up by title, artist and duration. The text that follows describes the earlier versions. With the screen locked and music playing, two `NSPanel`s in the lock screen's SkyLight Space at absolute level 400 (above loginwindow): a full-screen **background panel** with `ignoresMouseEvents = true` and a small **pill panel** with `ignoresMouseEvents = false`. The background panel shows the **cover art as full-screen wallpaper** (`scaledToFill` + clip, Ken Burns 1.00 → 1.08 over ~14 s, 32% black veil) and, above the cover art, drawn by us in **Liquid Glass style**: large clock (`.light`), abbreviated date, and a row of glass widgets under the clock (battery for now; weather, AirPods, Focus will follow). A **transparent hole** with soft edges and a custom shape is cut in the central-lower band of the background panel (about 73% of the height, 26% of the width): the profile picture and password field of the macOS lock screen show through and stay clickable and typeable with the native system authentication. The pill panel, just above the hole (bottom edge at 55% of the height), has thumbnail + title + artist + AirPlay icon + time bar + ⏮ ⏯ ⏭ and is interactive: the controls work with the mouse and the media keys. Approach inspired by Canopy (https://getcanopy.pro/, changelog v1.1 and v1.2): the substantial difference from what was done before is **not chasing** the native lock screen (SkyLight level 400 covers clock and date) but **redrawing** it above, as background and widgets, leaving only the authentication area transparent. Same Now Playing source as Island (backend 1); the LRCLIB lyrics stayed with Island (superseded on 14 Nov: see "Text next to the player"). Robust cleanup in `com.apple.screenIsUnlocked`: both panels must be closed on that notification, otherwise we run into Canopy v1.1's "widgets left on the desktop after unlock" bug. | No permissions. Private SkyLight. | 0 with the screen unlocked / low with the screen locked and music playing (self-managed SwiftUI animations, `TimelineView(.everyMinute)` for the clock, `Text(timerInterval:)` for the time bar, zero timers of our own) | Atoll (GPL, lock screen widgets), SkyLightWindow (MIT), [Canopy](https://getcanopy.pro/) (closed, visual reference) |
| **Passing files from the phone to the Mac "like AirDrop"** (maintainer's request, 12 Nov 2026) | partial | On the phone, in the Windeck web app (§2.6): you pick a file (photo, document) and drag it toward the edge of the screen on the Mac's side. The file travels over the same local connection as the web app (HTTPS), **not** over AirDrop: AirDrop has no API to receive with an animation of our own nor to choose the folder. On the Mac the file's icon/preview **flies in from the edge of the screen on the side where the phone is**, with the same iPhone-style AirDrop animation, and the file ends up **on the Desktop**. **Which side the phone is on:** Macs have no UWB, so no Nearby Interaction; the direction comes from the gesture, read by the web app (dragging right on the phone = phone to the left of the Mac, the file enters from the left), with a fallback setting. Spike 26 before implementation. | Local network (Mac and iOS). On the Mac no other permission (the Desktop is writable). | Mac ~0 with no phone connected / burst during the transfer | AirDrop (functional reference), boring.notch (animation) |

#### 2.1.1 Island panel hit-testing

A transparent panel at maximum size, at level `.mainMenu+3`, would intercept clicks on the menu bar items next to the notch. Transparency is not enough to let them through: for layer‑backed views pass-through on alpha 0 pixels is not reliable. The chosen strategy is as follows.

1. **Dynamic frame, not fixed.**
   - *Collapsed*: the frame coincides with the notch's physical rectangle (`frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width` × `safeAreaInsets.top`). There are no menu items there, so we do not steal clicks.
   - *Expansion and collapse*: the frame does not jump to the final size, but **follows the shape** (point 2).
2. **The frame tracks the shape, `hitTest` is not used.** An override of `hitTest(_:)` that returns `nil` inside the `NSHostingView` does **not** pass the click to the window below: AppKit and WindowServer deliver the mouse‑down to our window anyway, which simply does not handle it, and the menu bar item next to it never receives it. Between different windows click-through works in only two ways: `ignoresMouseEvents = true`, or a frame that hugs the shape. Therefore:
   - **default:** while the island expands or collapses, at every keyframe of the morph (`keyframeAnimator`, at most 60 Hz, only during the animation) the panel receives `setFrame(_:display:false)` with the current bounding rect of the `NotchShape`, rounded to pixels. The frame is never larger than the visible shape plus 2 pt of margin;
   - **alternative, if spike 17 shows artifacts or WindowServer cost:** fixed frame at the expanded size, with `ignoresMouseEvents` toggled by an `NSTrackingArea` on every opaque region (or by cursor rects): `false` when the cursor is inside the shape's path, `true` outside. The tracking area stays local to our window, so no global monitor.
   - **Test (spike 17):** with the island expanded, a synthetic click and a real one on a menu bar item adjacent to the island must reach the item in 20/20 tries, both at rest and during the morph.
3. **Hover without global monitors.** Mouse hover is detected with an `NSTrackingArea` (`.mouseEnteredAndExited`, `.activeAlways`) on the content view of the collapsed panel. The panel receives events only inside its own frame, so there is no need to observe the mouse at system level.
4. **`ignoresMouseEvents`** switches to `true` during the collapse animation and when the user chooses "notifications only, no interaction".
5. **Displays without a notch.** Here the pill would sit above the menu bar, where app menus can reach. By default the pill appears **only for events**: track change, charging, HUD, reminders. There is no hover, and the frame exists only while the pill is visible. The "hover on the pill" option creates a 120×4 pt window at the center of the top edge, with its own `NSTrackingArea`; the UI warns that it "may cover very long menus".

**Energy cost.** The "zero wakeups" at rest holds **only** because no global `.mouseMoved` monitor runs. An `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` would wake the process at every pointer movement across the whole system: 60‑125 events per second with a trackpad, up to 1000 with some gaming mice. An `NSTrackingArea` on our window generates events only when the cursor enters or leaves the frame. The shelf's `leftMouseDragged` monitors fire only during drags. The ban on global `.mouseMoved` monitors is a code review rule (§5.2) and a deterministic assertion of the zero‑cost test.

### 2.2 Windows, Dock and menu bar (modules `Snap`, `Switcher`, `MenuBar`)

| Function | Verdict | Approach | APIs / Permissions | Battery | Tools studied |
|---|---|---|---|---|---|
| Snapping and shortcuts | feasible | AXUIElement with `AXPosition/AXSize`, plus the single private API `_AXUIElementGetWindow`. `AXEnhancedUserInterface` is temporarily disabled. Edge drag is detected with a `leftMouseDragged` monitor, active only during the drag; snap preview in Liquid Glass; haptics on Force Touch. | Accessibility. | 0 / low | [Rectangle](https://github.com/rxhanson/Rectangle) (MIT), [Loop](https://github.com/MrKai77/Loop) (GPL) |
| ~~Automatic tiling and virtual workspaces (`Tile`)~~ | **dropped (1.4)** | Automatic window arrangement does not enter the product. | – | – | – |
| Alt‑Tab with thumbnails and previews on hovering the Dock | partial | **Input:** subscription to `InputTapService`'s *active tap* (§4.3) on `keyDown/keyUp/flagsChanged`. The tap detects the activation combination: default ⌥⇥; option ⌘⇥, which uses `CGSSetSymbolicHotKeyEnabled` (private) to disable the native switcher, with the crash‑safe restore of §2.2.1. It handles Tab, ⇧Tab and arrows to move while the modifier is held, and the **release of the modifier** (`flagsChanged`) to confirm. Events are consumed only while the switcher is open. We do not use Carbon hotkeys: since Sequoia `RegisterEventHotKey` with only ⌥ or ⌥⇧ was blocked; in 15.2 it was partly restored, but intermittent failures continue ([forum 763878](https://developer.apple.com/forums/thread/763878)). Moreover Carbon does not report the modifier release. **Content:** enumeration with `CGWindowListCopyWindowInfo` (metadata only) and titles through AX (`kAXTitleAttribute`, no Screen Recording). **Thumbnails, optional:** `SCScreenshotManager` (public) by default; `CGSHWCaptureWindowList` (private, faster) behind a flag. Capture only on open or on hover, LRU cache at 320 px. Cross‑Space focus with `_SLPSSetFrontProcessWithOptions` followed by the two `SLPSPostEventRecordTo` events that make the window *key*, and by `kAXRaiseAction` on the window's AX element. `kAXWindowsAttribute` lists only the windows of the current Space: those in other Spaces (and full screen) are obtained with `_AXUIElementCreateWithRemoteToken` (`AccessibilityBridge`, same technique as AltTab); without that element the app comes to the front but the Space does not change (verified on 27.0.1, 13 Nov 2026). Off-screen windows that AX does not know even this way are closed windows left in memory and are not listed. Without Screen Recording the switcher shows icons and titles. With Secure Event Input active (password fields) keyboard taps receive no events and the switcher does not open: this is the same limit as AltTab and is documented. | Accessibility (active tap, AX); for the keyboard active tap on 26/27 probably also Input Monitoring: **TBD until spike 6**, and the onboarding badges and texts stay provisional until then. Screen Recording only for thumbnails, with the periodic re‑prompts of §6.1. | 0 / medium in bursts | [AltTab](https://github.com/lwouis/alt-tab-macos) (GPL), [DockDoor](https://github.com/ejbills/DockDoor) (GPL) |
| Hide and reorder menu bar icons | feasible | **Reduced scope in 1.4 (12 Nov 2026):** no parity with Ice. 1.0 offers: hiding icons per app with macOS 27's native toggles (`trackedApplications`, requires Full Disk Access, spike 21); Control Center's system items; the arrow that shows the hidden icons again; **reordering icons** from a list in Settings. Reordering moves the icon as the user would with ⌘‑drag: a synthetic drag (`CGEvent`) from the current position to the chosen one, with positions read from `CGWindowListCopyWindowInfo` (bounds and PID only, no Screen Recording). No replacement HUD or control; no separate bar. | Accessibility for reordering; Full Disk Access for per-app toggles. | 0 / burst during reordering | [Ice](https://github.com/jordanbaird/Ice) (functional reference), [Hidden Bar](https://github.com/dwarvesf/hidden) (MIT), [Thaw](https://github.com/thaw-app/Thaw) (GPL + §7 exception) |

#### 2.2.1 Crash‑safe restore of the native switcher (⌘⇥)

`CGSSetSymbolicHotKeyEnabled(…, false)` changes WindowServer's state for the whole session. If Tsukumo crashes while holding ⌘⇥, the user is left **without an app switcher** until logout. For this reason the ⌘⇥ option has several levels of restore, modeled on AltTab:

1. **Persistent flag.** Before disabling the native hotkey, `switcher.nativeHotkeyDisabledByUs = true` is written in `Defaults`, and it is deleted only after re-enabling it.
2. **At launch**, before starting any module: if the flag is `true`, we immediately re-enable the native hotkey, then delete the flag. This way a crash is repaired at the next relaunch.
3. **On module stop** (`stop()`), in `applicationWillTerminate` and in an `atexit` handler: re-enabling and deleting the flag.
4. **Termination signals** (`SIGTERM`, `SIGINT`, `SIGHUP`): a `DispatchSourceSignal` on the main queue re-enables and then terminates cleanly.
5. **Crash signals** (`SIGABRT`, `SIGSEGV`, `SIGBUS`, plus `SIGILL` and `SIGTRAP`, which are the Swift runtime traps): a best-effort re-enable attempt in the handler. It is not async‑signal‑safe and is not guaranteed, so the real protection is point 2.
6. **Crash isolation:** if Switcher goes to `.suspended` (§4.2), the native hotkey is re-enabled before suspending the module.
7. **Visibility for the user:** the Tsukumo menu has a "Restore system ⌘⇥" item. The option's sheet warns: "if Tsukumo quits abnormally, ⌘⇥ comes back at the next Tsukumo launch or at logout". Spike 6 also measures the behavior after a `kill -9`.

### 2.3 Monitor and keyboard sounds (modules `Monitor`, `Clack`)

| Function | Verdict | Approach | APIs / Permissions | Battery | Tools studied |
|---|---|---|---|---|---|
| System monitor in the menu bar | feasible | A single `SharedSampler` with a `DispatchSourceTimer` (25% leeway), to which only the active modules subscribe. Sources: `host_statistics64`, `getifaddrs`, IOReport "Energy Model", IOHID for temperatures, SMC for fans (read only). The sensor table is a community-maintained JSON. Sampling every 5 s with the popover closed and every 1 s with the popover open; paused when the screen is off. **The item is redrawn only when the displayed value changes**: the value is rounded to the displayed precision and compared with the previous one, and only if it differs `button.attributedTitle` or the image is updated. Every redraw costs WindowServer work, and is counted in §5.1. | No permissions. IOReport, IOHID and SMC are private or undocumented. | low / low | [Stats](https://github.com/exelban/stats) (MIT), [socpowerbud](https://github.com/dehydratedpotato/socpowerbud) (MIT, archived), [mactop](https://github.com/context-labs/mactop) (MIT), [asitop](https://github.com/tlkh/asitop) (MIT), [eul](https://github.com/gao-sun/eul) (MIT, inactive) |
| Mechanical keyboard sounds | feasible | Subscription to `InputTapService`'s *listen tap* (dedicated thread). `AVAudioEngine` with a pool of 24 `AVAudioPlayerNode`s, `scheduleBuffer(.interrupts)`, stereo float32 buffers converted when the pack is loaded. **IO buffer: the device default** (usually 512 frames at 48 kHz). We do not lower it: the output device is shared, and CoreAudio runs the IO at the smallest buffer requested by its clients, so a 256-frame buffer would apply to **all** apps and increase coreaudiod's work for the whole system. The "Low latency (256 frames)" option exists, is off by default and warns about this cost. **Key→sound latency target:** p95 < 20 ms on built-in speakers and wired outputs, measured from the event timestamp (`CGEventGetTimestamp`) to the expected output instant, that is the buffer's host time plus `kAudioDevicePropertyLatency` plus the safety offset; recorded with `os_signpost` (spike 16). Bluetooth is excluded (§10). Mechvibes pack format. Stereo pan according to the key position, round‑robin variants, sound also on keyUp. Automatic mute with `IsSecureEventInputEnabled()`. **Engine lifecycle:** after 15 s without keys the engine goes to `pause()`, not `stop()`: graph, nodes and buffers stay allocated and the hardware IO stops. On the first keyDown after the pause, `start()` runs asynchronously on the audio queue, never in the tap callback. **Single rule for all sounds, also after a pause:** every sound must be able to start within **30 ms** of its event's timestamp; if it cannot, it is dropped and counted in `os_signpost`. There are no "late" sounds beyond this deadline. In practice the key that wakes the engine sounds if `start()` finishes in time, otherwise only that one is lost. | Input Monitoring only (`CGRequestListenEventAccess`). | 0 / low (app) + **coreaudiod and audio hardware cost** (§5.1) | [Clacky](https://github.com/jasonzh0/Clacky) (MIT, *reference*: 4 stars), [Mechvibes](https://github.com/hainguyents13/mechvibes) (MIT, pack format), Klack (closed) |

### 2.4 Input, authentication, display (module `Duo`; `Pointer` dropped on 12 Nov 2026)

| Function | Verdict | Approach | APIs / Permissions | Battery | Tools studied |
|---|---|---|---|---|---|
| **`Pointer`, Mac side** (common to the three sources) | feasible | A single module receives orientation deltas from one source at a time and moves the system cursor. Single chain: yaw/pitch deltas → dead zone → One‑Euro filter → acceleration curve → movement and click `CGEvent`s. Recenter and pause hotkeys. Active **only in "pointer mode"**: outside the mode no listener, no radio, no code running (§4.2). The choice of source and the sensitivity are in the module's Settings. | Accessibility (to post the events). Local network for iPhone and Watch. | 0 / low | [HeadOrbit](https://github.com/Cogria-AI/HeadOrbit) (MIT), [douinc/deck](https://github.com/douinc/deck) (MIT, *reference*) |
| **iPhone** source: the phone in hand as a remote | feasible | "Pointer" section of Tsukumo Remote, in the foreground: `CMMotionManager.deviceMotion` at 60 Hz, deltas sent as QUIC datagrams over `CompanionLink` (§7.1), click and right click with taps on the screen on a reliable stream. It is the first source to build: it has no unknowns beyond pairing (spike 4). | Local network (iOS and Mac); motion on iOS. | 0 / low | Mobile Mouse (closed, reference) |
| **Apple Watch** source: the wrist moves the cursor, the index‑thumb pinch clicks | feasible, transport to be chosen | **Revised in 1.4 by the maintainer's decision** (1.3 excluded it because of WatchConnectivity latency, 100‑300 ms). watchOS app in the foreground: `CMMotionManager` on the Watch for motion; click with the system gesture `.handGestureShortcut(.primaryAction)` (double tap, Series 9 / Ultra 2 and later) and, on other models, a tap on the screen. **Spike 23 chooses the transport**: a) direct Bluetooth LE Watch → Mac (Watch central, Mac peripheral); b) relay from the iPhone via WatchConnectivity. Criterion: motion → cursor latency p95 < 50 ms. The spike also decides how to keep the session alive while the wrist is lowered, without violating App Review rules. | Motion on watchOS; Bluetooth on the Mac if (a) wins. | Mac 0 / low; Watch medium, only during use | – |
| **AirPods** source: case or earbuds held in hand | **uncertain**, best effort | `CMHeadphoneMotionManager` exposes the motion of the earbuds, not of the case, and is meant for when they are worn. Spike 24 checks whether data arrives with the AirPods held in hand (in or out of the case). If it does not, the source leaves 1.0 and only head motion remains as an option. | Motion and fitness (`NSMotionUsageDescription`). | 0 / medium (BT radio) | [AirPodsPro-Motion-Sampler](https://github.com/tukuyo/AirPodsPro-Motion-Sampler) (MIT, *reference*) |
| ~~Media/slide remote from the Watch, trackpad and keyboard from iPhone (`Remote`)~~ | **dropped (1.4)** | Only the air cursor (`Pointer`) and Windeck remain in the product. The companion app keeps being called "Tsukumo Remote" until a new name is decided. | – | – | – |
| ~~Sudo with the Apple Watch (`WatchSudo`)~~ | **dropped (1.4)** | The module does not enter the product: no PAM module, no privileged installation. §2.4.1 remains only as an archive. | – | – | – |
| MacBook hinge open/close animation (module `Duo`) | feasible with hardware/API limits | Reads the hinge angle from the HID sensor (`las`, usage page 0x20 / 0x8A; changes every ~100 ms in whole degrees). At rest it checks the angle every 100 ms (documented exception, ~0.5 ms per read, stopped when the display is off); when the hinge moves by ≥ 4° a session starts: a single frame of the screen with `SCScreenshotManager`, frozen under a Metal overlay, and a 60 Hz timer. The animation appears only after an 8° dead zone and 0.2 s of continuous closing (short jolts are excluded), dissolves by itself when the lid stops, and fuses remove the overlay if the lid has been still for 1.5 s or the session exceeds 30 s. The desktop stays still on the screen ("Movimento" slider at 0%): blur and dimming change, growing with the distance from the hinge; at 100% it is anchored in space but stretches. It is not screen mirroring, a virtual display or streaming. Support is declared only on the MacBooks where the spike verifies the sensor (tried: Air 13" M4). | Access to the lid-angle sensor via non-public HID; Screen Recording/capture for the frozen frame (indicator and prompt to be verified); no network or Accessibility. | 0 at rest / burst during hinge movement | [iPhone Duo Animation](https://github.com/fx-xf/duo) (functional reference, license to be verified before any reuse) |

> **Unlocking the Mac with the iPhone: we do not do it.** Version 1.2 included "Unlock with iPhone". It was removed because of a security decision: the reasons and the native alternatives are in §7.2.

#### 2.4.1 Installing pam_watchid without a privileged daemon

> **Superseded section (1.4):** `WatchSudo` is dropped. The text remains as an archive and must not be implemented.

A root daemon registered with SMAppService just to write two files is disproportionate: it adds attack surface and approvals in *Login Items*. The `WatchSudo` module instead offers two paths, which run **the same installation procedure**.

**The procedure is generated by the UI, it is not static.** The bundle path is derived from the running app's `Bundle.main.resourcePath`, because the app can be in `/Applications`, in `~/Applications` or elsewhere; the UI inserts it with quoting and escaping, like the Team ID. The `pam_watchid.so.2` module (arm64e, signed with our Developer ID) and the rollback script live in `Contents/Resources/pam/`. The file names follow the upstream README. Here the procedure is described at design level; the exact text lives in `Tools/release/pam/` and is reviewed in the security audit.

**The problem to avoid: TOCTOU.** The procedure runs as root, but reads files from a bundle that sits in a **user-writable path**. If it verified the signature on the bundle and then copied from the bundle, malware with only the user's privileges could replace `pam_watchid.so.2` or the rollback between the check and the installation, and get code executed as root (the module inside `sudo`, the rollback from the watchdog). For this reason **nothing is ever installed that was verified in a place different from the one it is copied from**.

**Installation steps, in this order** (every failed step aborts everything before touching `/etc`):
1. **Copy into a private root directory.** A temporary directory is created with `mktemp -d`, owned by `root:wheel` with `0700` permissions, and the whole payload is copied into it (`ditto`, without following symbolic links). From here on nothing is read from the bundle anymore.
2. **Verify the copy with a signature requirement.** `codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[subject.OU] = "<TEAMID>"'` (the two OIDs are the Developer ID markers: leaf = Developer ID Application, intermediate = Developer ID CA) on the **copy** of the module. The `-R` requirement replaces the old textual check `codesign -dv | grep TeamIdentifier`, which could be fooled.
3. **Verify the rollback with an embedded hash.** The rollback is a script, so it carries no useful code signature. Its SHA‑256 is **written into the procedure's text** at build time and the procedure compares it with the `shasum -a 256` of the copy. Before 1.3 the rollback, later run as root, was not verified at all.
4. **Back up `sudo_local`, only once.** If a backup already exists it is not overwritten; if `sudo_local` does not exist its absence is recorded, so the full restore knows it must delete it.
5. **Install from the verified copy.** First the rollback in `/usr/local/libexec/` (root:wheel, 0755), so that it exists before any change; then the module in `/usr/local/lib/pam/` (root:wheel, 0444).
6. **Idempotent block in `sudo_local`.** A line is not appended: the **whole file is rewritten**, keeping intact everything outside our block and regenerating the block between the `# BEGIN tsukumo` and `# END tsukumo` markers. Inside the block, in order: the `auth optional …/pam_reattach.so` line if the user chose it (see below), **then** the `auth sufficient pam_watchid.so` line. The new file is written alongside and moved with an atomic rename, then `root:wheel` and `0444`. Re-running the procedure gives the same file.
7. **Watchdog with automatic rollback.** The confirmation file is deleted and a one‑shot watchdog is started, as root: if the confirmation of test B does not appear within 180 s, it runs the rollback by itself.
8. **Cleanup.** The temporary directory is deleted; the UI asks to run tests A and B within 3 minutes.

**Rollback** (idempotent, can be re-run without effects). The standard one **deletes the block** between `# BEGIN tsukumo` and `# END tsukumo`, with no regular-expression matching, then removes the module and the confirmation file. The full one (`--full`) restores `sudo_local` from the backup, or deletes it if it did not exist before.

The two paths:
1. **Copyable command (default).** The UI shows the generated procedure, a "Copy" button and the explanation of every step. The user runs it with `sudo sh`.
2. **One‑shot with administrator prompt.** The same procedure is run with `NSAppleScript` (`do shell script … with administrator privileges`), which shows the system authorization dialog based on Authorization Services. Before the call `NSApp.activate()` is invoked, because an LSUIElement app might open the dialog behind other windows. The call runs on the main thread, the only one supported by `NSAppleScript`, and is a one‑shot operation started by the user. Spike 14 verifies it works under hardened runtime in a notarized build. If it fails, it falls back to `/usr/bin/osascript` as a `Process`; as a last resort only the copyable command remains. We do not use `AuthorizationExecuteWithPrivileges`, deprecated since 10.7.

**Mandatory tests, to run in a new Terminal window within 3 minutes** (the sheet guides them and, only while it is open, checks the confirmation file):
- **Test A, Watch:** `sudo -k; sudo -v`. Approve on the Watch and verify that sudo passes.
- **Test B, password fallback and confirmation:** `sudo -k; sudo touch /private/var/run/tsukumo-pam.ok`. **Cancel** the Watch request: `Password:` must appear. Type the password. The created file disables the watchdog and the sheet shows ✓. This test shows that, with our module present, the password path still works.
- If test B is not completed within 180 s, the watchdog, which already runs as root, runs the rollback by itself. A broken module therefore cannot lock the user out.

**Lock‑out protections:**
- The sheet recommends keeping another Terminal open with `sudo -s` during the tests.
- Tsukumo's "Restore" button runs `tsukumo-pam-rollback` through the administrator prompt. This prompt goes through Authorization Services (`/etc/pam.d/authorization`), not `/etc/pam.d/sudo`, so it works even with sudo broken (to be confirmed in spike 14). As a last resort there is recovery mode.
- **Uninstall:** standard rollback (removing the `tsukumo` block, then the module), then removal of the backup and of the rollback itself.

**tmux and screen.** Inside tmux or screen the Watch prompt does not work without [pam_reattach](https://github.com/fabianishere/pam_reattach) (MIT), which reattaches the process to the GUI session. We do not include it in the bundle. If it is installed (for example with `brew install pam-reattach`, in `/opt/homebrew/lib/pam/pam_reattach.so`), the UI detects it and, with the user's consent, its `auth optional` line is **inserted before** ours inside the `# BEGIN tsukumo`/`# END tsukumo` block (step 6). Appending is not enough: PAM evaluates the lines in order, pam_reattach must reattach the session **before** pam_watchid asks for the Watch, and a `sufficient` line that passes stops the stack, so appended after it would be useless. If pam_reattach already has a line outside our block, the UI flags it and does not duplicate it. Its slice must also be checked (arm64e, spike 11).

**macOS updates.** System updates, Tahoe and 27 included, restore `/etc/pam.d/sudo` and the other system PAM files. **`/etc/pam.d/sudo_local`, introduced in Sonoma, survives updates, and the same holds for `/usr/local/lib/pam`.** The module nonetheless runs a health check after every OS build change (`kern.osversion`): it verifies that the `tsukumo` block and the file exist and that the signature satisfies the same `-R` requirement. If anything is missing it shows "Reapply", which regenerates the same procedure with the same tests. Declared limits: a GUI session is required (over SSH it falls back to the password) and the configuration applies to a single user.

### 2.4.1 Mac audio (module `Sound`)

Added by the maintainer on 12 Nov 2026. It lives in the menu bar (an item with a popover) and, where it makes sense, in Island.

| Function | Verdict | Approach | APIs / Permissions | Battery | Tools studied |
|---|---|---|---|---|---|
| **Per-app volume** (mixer) | feasible since macOS 14.4 | **Master volume at zero = silence (15 Nov 2026):** the slider at 0 does not really zero many outputs (built-in speakers included), so at 0 Sound turns on the device mute, which applies to every app, whoever brought the volume to zero; when it goes back up it removes only the mute it set. Island's HUD does the same with the volume keys. **Core Audio process taps** (`CATapDescription`, `AudioHardwareCreateProcessTap`): for every app with a volume different from 100% a tap is created with `muteBehavior = .muted` (not `.mutedWhenTapped`: on resume the app would play at full volume until the IO restarts), the app's audio is read, scaled (cubic, perceptual curve) and sent back to the output device through a private aggregate device that uses only the tap's stream (the device's inputs, like the AirPods microphone, stay off). Since the tap mutes at the source, a stalled IO means silence: after every start a one-time check (3 s later) verifies that the IOProc gets called, otherwise the tap is recreated once and, on a second failure within 30 s, it is removed and the app plays on its own again. No system driver to install. Apps at 100% volume and default output have **no** tap. The list of playing apps comes from `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningOutput`, event-driven (Core Audio listeners). | **System Audio Recording** permission (TCC `kTCCServiceAudioCapture`, `NSAudioCaptureUsageDescription`), requested only the first time a slider is moved. | 0 with no adjustments / low for every adjusted app **while playing** (IO proc active only with audio) | [AudioCap](https://github.com/insidegui/AudioCap) (BSD‑2, process tap example), FineTune (license to be verified), SoundSource (closed, functional reference) |
| **Per-app output** | feasible since macOS 14.4 | Same tap: the app's audio goes out on the aggregate device of the chosen device instead of the default one (for example music to the headphones and notifications to the speakers). | As above. | as above | as above |
| **Quick output switching** | feasible | List of devices from `kAudioHardwarePropertyDevices`, switching with `kAudioHardwarePropertyDefaultOutputDevice` (and optionally the system effects one). Event-driven listeners for connections and disconnections (AirPods, displays, USB). | No permissions. | 0 | SoundSource, Hammerspoon (`hs.audiodevice`) |
| **Music blocker** | feasible | Like noTunes: `NSWorkspace.didLaunchApplicationNotification` observer; if `com.apple.Music` launches (for example by pressing play or connecting headphones) and the blocker is on, the app is closed immediately; option to open another app (Spotify) in its place. No polling. | No permissions. | 0 | [noTunes](https://github.com/tombonez/noTunes) (license to be verified) |

**Energy rules:** no audio engine on without sound (§5.2): an app's tap exists only if the user adjusted it, and its IO proc works only while the app emits audio. Spike 27 before implementation: latency added by the tap, behavior with AirPods and AirPlay, recovery when the app or the device disappears.

### 2.5 Converter (module `Convert`)
| Function | Verdict | Approach | APIs / Permissions | Battery | Tools studied |
|---|---|---|---|---|---|
| File converter and quick tools (images, audio, video, PDF) | feasible | **Acceptance requirement (1.4): the flow works like Tangerine.** While the user drags one or more files (from Finder or any app) and **holds ⌘**, a **radial picker** appears around the cursor: in the center the file's preview, name and size; around it, as petals, the destinations suited to that file type. Releasing ⌘ without choosing closes it and the drag continues normally. Dropping the file on a petal runs the action. **Two sets of petals**, from the reference screenshots: *formats* (for an image: JPG, WEBP, HEIC, TIFF, AVIF, BMP, PDF, DOCX) and *tools* (for an image: Compress, Metadata, Edit, Annotate, Add BG, Crop, Redact). **⌘ alone shows the formats, ⌘⇧ the tools** (decided on 12 Nov 2026: two different gestures for two kinds of change); pressing or releasing ⇧ with the picker open switches between them. Releasing ⌘ always closes the picker, and a safety net closes it if the mouse button is no longer pressed (the mouse-up of a drag that ended over the picker does not reach the global monitor). **Tool panels**, each with a preview and an Apply button: *Edit Photo* (Light sliders: exposure, brightness, contrast, highlights, shadows, with per-item reset); *Add BG* (background behind the image from gradient presets, solid tints or your own image); *Trim Audio* (waveform with handles, start/end, "trim silence at the ends", listening to the selection); *Convert Audio Channels* (mono/stereo with per-channel levels and listening to the output). **Bleeps** (included at the maintainer's request): range lane above the waveform, original/with-bleep preview, 1 kHz sine bleep with 5 ms fades. Image tools: Compress, Metadata, Edit Photo, Annotate, Add BG, Crop, Redact (Redact really destroys the pixels and re-encodes without metadata). Tier 0 formats with no external processes: images and PDF with ImageIO/PDFKit, audio (M4A, WAV, AIFF, CAF) and video (MP4, MOV, audio to M4A) with AVFoundation; **Tier 1 (done on 12 Nov 2026):** WebP (also animated), MP3, FLAC, Opus, WebM (VP9+Opus), MKV (container change only) and animated GIFs from video go through LGPL ffmpeg, run by the `Converter.xpc` helper with closed presets (`ConverterKit`): absolute paths, new output next to the input, never overwriting, progress in the center of the wheel. ffmpeg is **included in the app** (maintainer's choice: it works offline, no network calls); tier 1 formats appear only if the build contains ffmpeg. The result always goes next to the original with a suffix, never overwritten. **Liquid Glass constraint:** the picker is a transparent window and the glass leaves the window's pixels empty, so without anything else the drag would pass through the petals; a view above the wheel draws a disc at 2% opacity and receives the drag. **Drag detection:** the same detector as Island's shelf, to be moved into `Core`: global `leftMouseDragged`/`leftMouseUp` monitors (they fire only during a drag) plus `NSPasteboard(name:.drag).changeCount` to know that files are being dragged. ⌘ is read from the `modifierFlags` of the same events; for ⌘ pressed with the mouse still, spike 25 verifies whether a `flagsChanged` monitor, installed only while a file drag is in progress, arrives without permissions. The picker is a non-activating panel registered as a drag destination. At rest, with no drag, the module runs no code. **Look:** mechanics and capabilities as in the reference, but our own UI in Liquid Glass (`DesignSystem`): no Tangerine name, icons or graphics. **Engines.** Tier 0, zero weight: ImageIO, Core Image, PDFKit, AVAssetReader/Writer and VideoToolbox hardware encoders. DOCX output from an image: a minimal OOXML document written by us with the image embedded (if the reference does OCR, Vision is evaluated). Tier 1, downloaded on‑demand: **LGPL-only** ffmpeg built by us (videotoolbox, SVT‑AV1, libvpx), run as a child process of `Converter.xpc`, for video, GIF and codecs not covered by tier 0. Tier 2: pandoc downloaded separately for documents. Batch when the action is compatible; non-destructive output, with explicit destination and conflicts. **Secondary inputs:** notch shelf, Finder Quick Action, Share extension, App Intents. | No permissions expected (to be confirmed by spike 25). | 0 / medium, only during jobs (QoS utility) | Tangerine (closed, functional reference: screenshots provided by the maintainer), [Gifski](https://github.com/sindresorhus/Gifski) (MIT, UX reference), [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next) (LGPL‑3.0; FFmpegKit is retired), [libvips](https://github.com/libvips/libvips) (LGPL), [HandBrake](https://github.com/HandBrake/HandBrake) (GPL‑2.0: do not link), [pandoc](https://github.com/jgm/pandoc) (GPL) |
| ~~Smart home: Home Assistant, HomeKit, Matter (`Home`)~~ | **dropped (1.4)** | The module and the separate "Tsukumo Home" app do not enter the product. §4.5 is superseded. | – | – | – |

### 2.6 iPhone and iPad as the Mac's Stream Deck (module `Windeck`)

> **Maintainer decision, 12 Nov 2026: Windeck is a web app served by Tsukumo, with no native app.** The parts of this section and of §7 that talk about iOS/watchOS apps, native Bonjour, MultipeerConnectivity or mTLS with a Secure Enclave key are superseded by this note; actions, data model, profiles, live feedback and security scope remain valid.
>
> - **Nothing is kept open on the Mac.** The server lives inside Tsukumo (in the background in the menu bar) as long as the Windeck module is on: HTTPS `NWListener` + WebSocket, local network only, event-driven, zero work with no connected clients.
> - **On the phone** (iPhone, iPad, also Android) the deck is a web page added to the Home Screen, which opens full screen. It needs to be in the foreground only while the deck is in use.
> - **First connection:** QR code shown by Tsukumo's Settings, scanned with the camera; confirmation on the Mac. The phone keeps a pairing token; **the pairing stays until it is revoked** from Settings. Note: a page used only in Safari (not added to the Home Screen) can lose its data after ~7 days of non-use and must be re-paired; added to the Home Screen it does not.
> - **Live connection:** WebSocket open as long as the deck is visible and the screen on. If the phone is locked, the app changes or the Mac goes to sleep, the connection drops and **reconnects by itself** (target < 1 s) on return, with the full state. The Mac is found by name (`<name>.local`, mDNS), not by IP; the same Wi‑Fi network is required.
> - **HTTPS:** needed for Wake Lock (screen on while the deck is in use) and for a secure context. Tsukumo generates a small local CA; the phone installs and enables it once (configuration profile). Without it, the deck works over HTTP but without Wake Lock.
> - **Accepted limits:** no vibration (except the native Safari switch trick), no background work on the phone.
> - **Shortcuts (optional):** a deck action can also be exposed as an HTTP request for the iPhone's Shortcuts (widget, Control Center, Action button, Apple Watch, Siri), without live state.
> - **Code:** the web client (HTML/JS/CSS) lives in `Companion/web/`, GPL‑3.0‑only like the rest of the project; the server lives in the Mac module.

| Function | Verdict | Approach | APIs / Permissions | Battery | Tools studied |
|---|---|---|---|---|---|
| Customizable deck on iPhone/iPad: buttons, toggles, sliders, knobs, folders, per-app profiles, live feedback | feasible | Mac side: event-driven Bonjour listener, action engine on the `Action` protocol, versioned JSON profiles, automatic profile switching on the frontmost app, subscriptions to state "topics" only while a visible page uses them. iOS/iPadOS side: SwiftUI grid inside Tsukumo Remote (§7.3), same pairing and same `CompanionLink`. Mini‑deck on the Watch. | Local network (Mac and iOS). Accessibility only for the "keys" actions; Automation (Apple Events) only for AppleScript actions; no permissions for apps, URLs and Shortcuts. | Mac ~0 with no phone connected / low with a phone connected | [douinc/deck](https://github.com/douinc/deck) (MIT, best Swift reference), [OpenDeck](https://github.com/nekename/OpenDeck) (GPL‑3.0‑or‑later), [Macro Deck](https://github.com/Macro-Deck-App/Macro-Deck) (Apache‑2.0), [Bitfocus Companion](https://github.com/bitfocus/companion) (license to be verified), Elgato Stream Deck Mobile (closed) |

**The name.** "Windeck" is the module that appeared in the early notes as "Windoc": a deck, not a dock.

**State of the art** (research verified on 2026‑11‑09; stars and activity must be recorded in the §8.2 matrix before using any code):
- **Elgato Stream Deck Mobile:** closed source. Free with 6 keys; Pro at $2.99 a month or $49.99 lifetime. QR pairing on the same Wi‑Fi network.
- **Touch Portal:** closed source, with a plugin API.
- **[Macro Deck](https://github.com/Macro-Deck-App/Macro-Deck):** Apache‑2.0.
- **[Bitfocus Companion](https://github.com/bitfocus/companion):** over 700 modules for broadcast hardware; license to be verified file by file before any reuse.
- **[OpenDeck](https://github.com/nekename/OpenDeck):** GPL‑3.0‑or‑later, Rust/Tauri. Runs Elgato SDK plugins and switches profile based on the active app.
- **StreamController:** GPL‑3.0, Linux only.
- **[douinc/deck](https://github.com/douinc/deck):** MIT, SwiftUI on Mac, iPhone and Watch, MultipeerConnectivity and `CGEvent`. It is only a presentation clicker, but it is the best Swift reference.
- **[elgatosf/streamdeck-kit-ipad](https://github.com/elgatosf/streamdeck-kit-ipad):** MIT, iPad only, for Elgato hardware via DriverKit.
- **The gap:** there is no open source, Mac‑first, native SwiftUI deck for the phone with sliders, per-app profiles and live feedback. That is Windeck's space.

**Actions.** A plugin-style Swift `Action` protocol (`id`, `Codable` parameter schema, `perform(context:) async throws`, required permissions and scopes). The v1 actions, compiled into the module:
- **keys and combinations:** `CGEvent`s posted with Accessibility;
- **open apps, files and URLs:** `NSWorkspace`;
- **Shortcuts:** the `shortcuts run <name>` CLI as a one‑shot `Process`; the picker is populated with `shortcuts list`, read only when the editor opens;
- **AppleScript:** with the Automation permission (TCC) for each target app;
- **shell:** `Process`, **opt‑in only** per device;
- **media keys:** synthetic `NX_SYSDEFINED` events;
- **volume:** CoreAudio (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`) on the default output device;
- **window layouts:** they reuse the `Snap` module's actions through the `EventBus`, without duplicating code;
- **OBS:** obs-websocket 5 client (scenes, recording, source mute);
- **Spotify and Music:** AppleScript, with the same backend as Island for the now-playing state.

**Data model.** `Codable` JSON with `schemaVersion` and explicit migrations. `Profile` → `Page` (`rows` × `cols` grid) → `Control`. A `Control` has a type (`button`, `toggle`, `slider`, `knob`, `folder`), a `frame` on the grid (also multi‑cell), an `appearance` (SF Symbol or image, colors, label) and the actions `onPress`, `onLongPress`, `onChange`. Icons live in a content-addressed cache (name = SHA‑256), so the phone downloads only the ones it does not have. Import and export of a profile as a zip (JSON plus icons).

**Automatic profile switching.** `NSWorkspace.didActivateApplicationNotification`, with a 150 ms debounce so it does not bounce during ⌘⇥. No polling.

**Live feedback.** A control subscribes to a *topic* (`volume`, `nowPlaying`, `obs.scene`, `toggle.<id>`…). The Mac sends only value changes, never at intervals; sliders are limited to 30 Hz in both directions. A topic exists only if a phone is connected **and** a visible page uses it: when the last subscription drops, its sources (CoreAudio listeners, media observers, OBS socket) are closed through the `ResourceBag`.

**Security.** It is remote command execution on the Mac, so the defaults are tight: pairing with QR and pinned mTLS (§7.1), confirmation on the Mac at the first connection of every device, revocable devices, **per-device scopes** (keys, apps, Shortcuts, media/volume, OBS can be enabled; **shell and AppleScript are off by default** and are turned on only from the Mac, with a sheet that explains the risk). The Mac validates every received action against the profile saved on the Mac: the phone sends "control X pressed", not an arbitrary command.

**Compatibility with Elgato plugins and hardware.** No compatibility with the Elgato SDK in v1. Possible v2: a separate, sandboxed process that hosts the plugins, inspired by OpenDeck's architecture but **written from scratch**. OpenDeck is GPL‑3.0‑or‑later, so it is compatible with our GPL‑3.0‑only: reuse would be legally possible (§8.3), but the choice remains to rewrite. USB Stream Deck hardware via `IOHIDManager` is a later module.

**Risks.** Security of remote execution (mitigated by scopes and Mac-side validation); permission friction (Accessibility and Automation requested only at the first action that uses them); fragile APIs for the "now playing" state and for brightness (same backends and same kill‑switches as Island, §2.1). Energy in §5.1, companion side in §7.3, phases and estimates in §9.

---

## 3. The stack

### 3.1 Language and UI

- **Swift 6.4** (the version included in Xcode 27) in language mode 6, with strict concurrency. Default `MainActor` isolation for UI targets (SE‑0466, *approachable concurrency*). Services are `actor`s or explicitly `nonisolated`.
- **SwiftUI first.** We move to AppKit for `NSPanel`, `NSStatusItem`, overlay `NSWindow`, event tap and AX. We do not use `MenuBarExtra` as the module's base: it has bugs on Tahoe and `openSettings` is unreliable from an LSUIElement app. We use `NSStatusItem` + `NSPanel` with `NSHostingView`, like Stats and Ice.
- **State:** `@Observable`. High-frequency values (monitor samples, pointer deltas) **do not go** through SwiftUI: they are drawn with `Canvas`/`TimelineView` only when the view is visible.
- **Persistence:** `Defaults` (sindresorhus, MIT) with one namespace per module. The shelf is saved as JSON in Application Support. **No SwiftData or Core Data**: they cost memory and startup time without a real benefit in this case.
- **Animations:** `phaseAnimator`, `keyframeAnimator`, `symbolEffect`, SwiftUI shaders (`.colorEffect`/`.layerEffect`). **No Lottie**: it costs weight and CPU and brings a non-Apple visual language.
- **Liquid Glass, only on the controls layer** (expanded notch pills, HUD, switcher, snap preview, popovers). Never on content and never on always-on surfaces: the collapsed notch is **solid black**. APIs used (SDK 26+, available on our deployment target 26.0):
  - SwiftUI: `glassEffect(_ glass: Glass = .regular, in shape: some Shape = .capsule)`. `Glass` has the variants `.regular`, `.clear` and `.identity`, with the modifiers `.tint(_ color: Color?)` and `.interactive(_ isEnabled: Bool = true)`.
  - Grouping: `GlassEffectContainer(spacing: CGFloat?) { … }`. Nearby shapes merge and share a single render pass.
  - Morph: `.glassEffectID(_ id: some Hashable & Sendable, in namespace: Namespace.ID)`, `.glassEffectUnion(id:namespace:)` to merge several views into a single shape, `.glassEffectTransition(.matchedGeometry)` or `.materialize`.
  - Buttons: `.buttonStyle(.glass)` and `.buttonStyle(.glassProminent)`.
  - AppKit, for `NSPanel` popovers and `NSStatusItem` panels: `NSGlassEffectView` (properties `contentView`, `cornerRadius`, `tintColor`) and `NSGlassEffectContainerView` (properties `contentView`, `spacing`).

  ```swift
  @Namespace private var island
  GlassEffectContainer(spacing: 10) {
    HStack(spacing: 10) {
      MediaPill()
        .glassEffect(.regular.tint(artworkTint.opacity(0.3)).interactive(), in: .capsule)
        .glassEffectID("media", in: island)
      if timer.isRunning {
        TimerPill()
          .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .glassEffectID("timer", in: island)
          .glassEffectTransition(.matchedGeometry)
      }
    }
  }
  Button("Join") { join() }.buttonStyle(.glassProminent)

  // AppKit: menu bar popover
  let glass = NSGlassEffectView()
  glass.cornerRadius = 18
  glass.contentView = NSHostingView(rootView: QuickPanel())
  panel.contentView = glass
  ```
  WWDC25 references: *Meet Liquid Glass*, *Get to know the new design system*, *Build a SwiftUI app with the new design*, *Build an AppKit app with the new design*. When building with the 27 SDK, the system chrome adopts 27's Liquid Glass refinements by itself. Snapshot tests (§3.4) catch any visual regressions on 26 and 27.
- **Glass fallback:** we do not support OSes older than 26, so the fallback depends only on the system state. With Reduce Transparency or Increase Contrast on we use the system's automatic behavior, plus `.regularMaterial` or a solid color. In Low Power Mode or under serious thermal state animated glass becomes static material.

### 3.2 Minimum version: **macOS 26.0, Apple Silicon only (arm64)**

Reasons:
1. Liquid Glass is native and there is no need for a double UI path for 14 and 15: there is only one developer.
2. Tahoe is the last release with Intel support and macOS 27 runs only on Apple Silicon. A new app has no reason to handle two architectures, and a single slice also halves the size and the test matrix.
3. Recent APIs are used without `#available`: `glassEffect` and the other glass APIs, `SCScreenshotManager`, `SMAppService`, SwiftUI springs.
4. The test matrix is already two OSes (26 and 27). Adding 14 and 15 would double it.
5. Whoever stays on Sequoia already has boring.notch, Stats and Rectangle.

The cost is losing users on Sequoia. It is an acceptable cost.

### 3.3 Packages (all verified)

| Package | Use | License |
|---|---|---|
| [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle) (release of 2026‑10‑25, verified on 2026‑11‑09; exact version pinned in `Package.resolved`, updates only with a dedicated PR) | updates, EdDSA, delta, channels | MIT‑style with multiple holders (reread the LICENSE before release) |
| `Hotkeys` (internal, `Packages/Core`) | configurable global hotkeys with direct Carbon `RegisterEventHotKey`, no permissions and no dependencies: the originally planned KeyboardShortcuts package was replaced by about 130 lines of our own, to avoid bringing in a dependency for a single API. Only combinations with ⌘ or ⌃: ⌥‑only combinations are unreliable since Sequoia (§4.3) | GPL‑3.0‑only (ours) |
| [Defaults](https://github.com/sindresorhus/Defaults) | typed settings | MIT |
| [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) | **vendored** in `Vendor/` to control levels, dynamic frame and energy | MIT |
| [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) | opt‑in "Island above the lock screen". Lives in the **main app**, behind the `Bridges/` wrapper: delegating our panel to the lock screen's space is per‑process (§4.1) | MIT |
| [ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter) | Now Playing backend | BSD‑3 |
| swift-collections, swift-async-algorithms (Apple) | ring buffer, stream merging | Apache‑2.0 |
| [swift-certificates](https://github.com/apple/swift-certificates) + [swift-crypto](https://github.com/apple/swift-crypto) (Apple) | self‑signed X.509 certificate for the pairing TLS identity, signed with the SE key (§7.1). Only in the `Protocol` package | Apache‑2.0 |
| [MenuBarExtraAccess/SettingsAccess](https://github.com/orchetect/SettingsAccess) | only if the Settings scene were needed | MIT |
| ~~LaunchAtLogin-Modern~~ | replaced by inline `SMAppService.mainApp` (10 lines) | – |
| ~~TelemetryDeck~~ | **not included** (see §3.6) | – |

### 3.4 Build and CI

- **Structure:** one local Swift package per module, plus a thin app generated with **XcodeGen** (`project.yml` in the repo, `.xcodeproj` in gitignore), like Itsyhome and HomeClaw. No Tuist: too much surface for a single developer.
- **Toolchain:** Xcode 27 with macOS 27 SDK, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `ARCHS = arm64`.
- **Quality:** `swift-format` (included in the toolchain), SwiftLint, Swift Testing, snapshot tests of the notch layouts on 3 geometries (14", 16", no notch).
- **CI on GitHub Actions, GitHub‑hosted runners** with labels `macos-26` and `macos-27`. **The availability of `macos-27` and of Xcode 27 in the hosted images is not verified as of 2026‑11‑09**: it must be checked on day 1 against the official `actions/runner-images` list. If `macos-27` is in preview, its job is `continue-on-error` until it becomes GA. If it does not exist, PRs run only on `macos-26` (with Xcode 27, if the image offers it) and the tests on 27 move to the self‑hosted Mac mini, post‑merge.
  - **Blocking on PRs**, deterministic checks only, on the 26 × 27 matrix: `lint` → `build` → `test` → **deterministic `zero-cost-test`** (§4.2) → layout snapshots → `manifest-check` (§3.8) → `reuse lint` + license check (§8.3).
  - **Informative on PRs**, published as a comment with the artifacts: footprint Δ and startup time Δ versus `CoreOnly`; snapshots with glass on. They block only beyond wide margins (§4.2).
  - **Snapshots:** on a paravirtual GPU Liquid Glass rendering is not deterministic. For this reason we use two levels. (1) **Layout** snapshots, blocking, rendered with the glass replaced by a solid color (`Glass.identity` or "reduce transparency" forced in the tests), with **per-OS** references (`__Snapshots__/macos26/`, `/macos27/`) and a perceptual tolerance (precision ≥ 0.98). (2) Snapshots with **glass on**, non-blocking on hosted runners; the authoritative ones run on the Mac mini post‑merge, with per-OS references. A difference opens a `visual-regression` issue.
  - On `v*` tags: archive → import of the p12 certificate into a temporary keychain → `codesign --options runtime` (perl adapter, frameworks, `pam_watchid.so.2`, rollback and helpers included) → `notarytool submit --wait` with an ASC API key → `stapler` → DMG with [create-dmg](https://github.com/create-dmg/create-dmg) → Sparkle's `sign_update` → appcast on GitHub Pages → Homebrew tap bump → SLSA attestation (`actions/attest-build-provenance`). **Release gate:** the workflow fails if there are open `zero-cost-regression`, `energy-regression` or `visual-regression` issues labeled `blocker`. The signing secrets exist only in this workflow, in a protected environment with maintainer approval, and never on the self‑hosted runner.
  - **Post‑merge and nightly on the self‑hosted Mac mini** (only already merged code, §5.3): tight zero‑cost thresholds, snapshots with glass, energy harness.
  - **Weekly, beta:** build and test of `main` on the latest 27.x beta installed on the Mac mini (GitHub images do not include macOS betas).
- **Localization:** String Catalog (`.xcstrings`, including `InfoPlist.xcstrings` for usage strings), English at launch; more languages through the catalog when contributors arrive.

### 3.5 Updates and distribution

- **Developer ID** ($99 a year, the first cost to be covered by donations), hardened runtime, notarization and stapling. It is a direct advantage over boring.notch: according to its README (read on 2026‑11‑09) it is distributed without notarization, because the project has no Apple Developer account. The app embeds a **Developer ID provisioning profile** (`Contents/embedded.provisionprofile`) with the App Groups and Keychain Sharing capabilities, required by the data protection keychain of the pairing identities (§7.1) and by Tsukumo Home's App Group (§4.5). The complete entitlements and Info.plist manifest is in §3.8.
- **Sparkle 2:** `stable` and `beta` channels, check every 24 h (asked at first launch), delta updates.
- **Homebrew:**
  - From launch: our own tap (`brew install --cask tsukumo-app/tap/tsukumo`, `auto_updates true`).
  - Then the official `homebrew/cask`. The app must be **signed and notarized**, and we are from the first release. The current homebrew/cask rules, that is the treatment of casks that do not pass Gatekeeper and the notability thresholds, must be **rechecked in the official documentation at submission time**: the values given here come from memory and are not verified. As an order of magnitude: about 225 stars, 90 forks or 90 watchers if the cask is proposed by the maintainer himself; about 75 stars, 30 forks or 30 watchers if proposed by a third party. A stable, non-beta version and a stable download URL (GitHub Releases) are also required.
- **GitHub Releases** with DMG + zip + checksum + attestation.
- **Not** the Mac App Store for the main app: private APIs, event tap, perl process and Accessibility rule it out. The exceptions are Tsukumo Home (Mac App Store) and Tsukumo Remote (iOS App Store, with an associated watchOS app).

### 3.6 Telemetry: **zero**. Diagnostics: **local only**

- No analytics SDK. The only network requests of the base app are `appcast.xml` and **`compat.json`** (§9), on the same host and in the same daily check.
- **Local collection of crashes and diagnostics**, which never leaves the Mac without a user action:
  - **MetricKit:** `MXMetricManager.shared.add(subscriber)` at launch. On macOS 12+ the `MXDiagnosticPayload`s (crashes, hangs, CPU exceptions, excessive disk writes) arrive almost immediately. The JSON (`jsonRepresentation()`) is saved in `~/Library/Application Support/Tsukumo/Diagnostics/` with rotation: 30 days, at most 50 files. **The daily `MXMetricPayload`s are not confirmed on macOS for a Developer ID app**: we save them if they arrive, but nothing depends on them.
  - **Energy panel, without MetricKit:** the data comes from `proc_pid_rusage(RUSAGE_INFO_V6)` on our process and on the children (`ri_billed_energy`, `ri_pkg_idle_wkups`, `ri_interrupt_wkups`, CPU time), a public and cheap API, sampled **only while the panel is open** (every 2 s) and compared with the previous reading. With the panel closed nothing runs.
  - **`.ips` crash logs:** on export, the files from the last 30 days of our processes are copied from `~/Library/Logs/DiagnosticReports/`: `Tsukumo`, `PrivateBridge`, `Converter`, and `perl` only if `MediaRemoteAdapter` appears in the report.
  - **Logs:** `log show --style ndjson --last 24h --predicate 'subsystem BEGINSWITH "<bundle id>"'`, run once as a child process at export time. It does not need root, but on some configurations `log show` requires an **administrator** user (or the `admin` group) to read the log archive: if it fails, the export continues without logs and says so in the preview.
  - **State:** OS version and build, chip model, enabled modules, each module's `health`, `ResourceBag` snapshots, permission state, applied `compat.json` version.
  - **"Export diagnostics"** creates a zip locally. First it shows a preview of the files with automatic redaction: home paths replaced by `~`, window names and media titles removed. The user attaches it to the issue only if they want. The issue template for "module broken after update" requires it.
- **Song lyrics in Island (opt‑in):** Music does not expose synced lyrics locally, so the only source is the network. With the option "Show the song lyrics in the island" or "Show the text next to the player" (lock screen, with the player on) turned on, Island asks LRCLIB (`https://lrclib.net/api/get`) for the lyrics, sending the track's title, artist, album and duration; ephemeral session, no cookies, no disk cache. The option is **off by default** and when off no request is made. It is a declared exception to the "zero network" rule, not telemetry.
- A `PRIVACY.md` lists every possible connection: Sparkle, compat, lyrics from LRCLIB (if on), HA (if configured), pandoc download (if requested, with a pinned SHA‑256 hash; ffmpeg instead is included in the app since the decision of 12 Nov 2026, no network), links with the companions and with Windeck (LAN only), OBS via obs-websocket (only if configured, usually on `localhost`).

### 3.7 License and funding

- The whole project is **GPL‑3.0‑only**.
- Contributions come in through pull requests with the **DCO** (`Signed-off-by`); no CLA is needed.
- Third-party code is accepted only under licenses compatible with GPL‑3.0 (MIT, BSD, Apache‑2.0, ISC, GPL‑3.0), with copyright and license notices preserved; never AGPL or unlicensed code.
- Funding: `.github/FUNDING.yml` with `github:`, `buy_me_a_coffee:` and `ko_fi:`.
  - In the app: the "Support Tsukumo" entry in *About* and in the menu.
  - **A single** polite card after 14 days of active use, dismissible forever. No paywall, no locked features.
  - Goal stated in the README: cover the Developer account, the domain and a test Mac for each new chip generation.

### 3.8 Entitlements and Info.plist manifest

The manifest lives in `App/manifest.yml`. The `Tools/manifest-check` script compares it with the compiled Info.plist and with `codesign -d --entitlements :-` of every signed binary, and is a deterministic block on PRs (§3.4). One key more or less fails the build.

**Mac app entitlements** (`Tsukumo.entitlements`, hardened runtime, **without** App Sandbox):

| Key | Value | Why | Source |
|---|---|---|---|
| `com.apple.security.automation.apple-events` | `true` | Now Playing's AppleScript backend (Music, Spotify) and Windeck's AppleScript actions (opt‑in per device). Without this key, under hardened runtime Apple Events to other apps fail without a prompt | entitlements |
| `com.apple.security.personal-information.calendars` | `true` | EventKit access under hardened runtime (Calendars; whether it also covers Reminders is to be confirmed in spike 6) | entitlements |
| `keychain-access-groups` | `[<TEAMID>.app.tsukumo.mac]` | data protection keychain: pairing identities and SPKI of Tsukumo Remote and Windeck (§7.1), Home Assistant and OBS tokens | authorized by the profile |
| `com.apple.security.application-groups` | `[<TEAMID>.app.tsukumo.shared]` | socket with Tsukumo Home (§4.5) | authorized by the profile |
| `com.apple.application-identifier`, `com.apple.developer.team-identifier` | `<TEAMID>.<bundle id>`, `<TEAMID>` | required for the embedded profile to be valid | from the profile |
| `com.apple.security.get-task-allow` | debug builds only | debugger | debug builds |

**Deliberately excluded:** `cs.disable-library-validation`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.allow-dyld-environment-variables`. The mediaremote-adapter framework is loaded inside `/usr/bin/perl`, not in our process, so no library validation exception is needed. `PrivateBridge` loads only private system frameworks signed by Apple. The XPC helpers (`PrivateBridge`, `Converter`) have hardened runtime and no additional entitlements.

**`do shell script … with administrator privileges` from NSAppleScript** (§2.4.1) runs inside our process and does not send Apple Events to other apps, so in theory it does not require the apple‑events entitlement (which we have anyway). The dialog goes through Authorization Services. It must be verified in spike 14, on a notarized LSUIElement build with hardened runtime, on 26 and 27: dialog in the foreground after `NSApp.activate()`, script executed, no unexpected Automation prompt. Fallback: `/usr/bin/osascript` as a `Process`, then the copyable command alone.

**Mac app Info.plist:**

| Key | Value / text  |
|---|---|
| `CFBundleIdentifier` | bundle id decided by 12 November (§1) |
| `LSUIElement` | `true` |
| `LSMinimumSystemVersion` | `26.0` |
| `CFBundleURLTypes` | `tsukumo` scheme |
| `SUFeedURL`, `SUPublicEDKey` | feed from §1, EdDSA public key |
| `NSAppleEventsUsageDescription` | "Tsukumo controls Music and Spotify (playback, favorites) only if you turn on Island's AppleScript backend, and runs Windeck's AppleScript actions only if you have enabled them." |
| `NSCalendarsFullAccessUsageDescription` | "Tsukumo shows the next event in the notch. Calendar data stays on this Mac." |
| `NSRemindersFullAccessUsageDescription` | "Tsukumo shows upcoming reminders in the notch. The data stays on this Mac." |
| `NSMotionUsageDescription` | "Tsukumo uses the head motion detected by AirPods to move the pointer, only in pointer mode." |
| `NSBluetoothAlwaysUsageDescription` | "Tsukumo reads the AirPods battery when they connect, to show it in the notch." (to be confirmed in spike 6 whether reading via IOBluetooth really requires the permission; otherwise the key is removed) |
| `NSLocalNetworkUsageDescription` | "Tsukumo finds and connects Tsukumo Remote, Windeck and Home Assistant on your local network." |
| `NSBonjourServices` | `[_tsukumo._tcp, _tsukumo._udp]`. **Mandatory since macOS 15**, with local network privacy: without this key, browsing and publishing Bonjour services fails silently. `_udp` is needed for QUIC. |

**Permissions without usage strings.** Accessibility, Input Monitoring and Screen Recording have a fixed system text: the explanations are given by our permissions sheet (§6.1).

**Tsukumo Remote (iOS and iPadOS, includes Windeck):** `NSLocalNetworkUsageDescription` and `NSBonjourServices` (same services), `NSCameraUsageDescription` (QR scanning). No `UIBackgroundModes`: the app works only in the foreground (§7.3). No Bluetooth and no Face ID since 1.3. Entitlement: the Team's `keychain-access-groups`. The multicast entitlement is not needed, because we use only Bonjour through `NWBrowser`/`NWListener`.
**Tsukumo Remote (watchOS):** `WKCompanionAppBundleIdentifier`. No usage string: without the gyroscopic pointer the Watch does not read motion sensors.
**Tsukumo Home:** App Sandbox, `com.apple.developer.homekit`, `NSHomeKitUsageDescription`, `com.apple.security.application-groups` (same group, §4.5).

---

## 4. Architecture

### 4.1 Processes

A **main app** (LSUIElement) hosts the UI, the modules and the shared services. Heavy conversions live in separate processes, started by launchd on‑demand. It is not true, however, that all private code can live in `PrivateBridge.xpc`: several calls work only in the process that owns the WindowServer connection, the window or the AX state. For those the isolation is **logical** (wrappers in `Bridges/`, per-module flag, `health`, kill‑switch via `compat.json`), not process-level, and a crash in them brings down the app. There is no permanent root helper: privileged operations (pam_watchid) are one‑shot and started by the user.

| Private API | Process that runs it | Why |
|---|---|---|
| `CGSSetSymbolicHotKeyEnabled` (⌘⇥) | main app | the state is per-session and could be set from any process, but the crash‑safe restore logic (§2.2.1) lives in the app and must stay with whoever disabled the hotkey |
| `_SLPSSetFrontProcessWithOptions` (cross‑Space focus) | main app | acts through the caller's WindowServer connection |
| `_AXUIElementGetWindow` (Snap, Switcher) | main app | needs the AX state and the `AXUIElement`s of the process that created them |
| SkyLight delegation of **our** panel to the lock screen's space (Island) | main app | the window is ours and the delegation is per‑process |
| `CGSHWCaptureWindowList` (thumbnails, behind a flag) | main app | same WindowServer connection as Switcher |
| Duo's hinge sensor and animated overlay | main app | must follow the physical state and the composition of the local display; at rest one read every 100 ms (none with the display off), at 60 Hz only during the motion |
| MediaRemote | `/usr/bin/perl` + adapter | the entitlement is perl's (§2.1, §10) |

```
                         ┌────────────────────────────────────────────────┐
                         │  Tsukumo.app  (LSUIElement, arm64, Developer ID)│
                         │  ┌────────────┐ ┌───────────┐ ┌────────────┐   │
  user ──hotkey/mouse────┤  │ ModuleHost │ │ Surfaces  │ │ Settings UI│   │
                         │  └─────┬──────┘ └─────┬─────┘ └────────────┘   │
                         │        │ EventBus (multicast broadcaster)      │
                         │  ┌─────┴─────────────────────────────────────┐ │
                         │  │ PermissionBroker · InputTapService ·       │ │
                         │  │ SharedSampler · CompanionLink · Compat ·   │ │
                         │  │ Diagnostics                                │ │
                         │  └──┬──────────┬───────────┬──────────┬──────┘ │
                         └─────┼──────────┼───────────┼──────────┼────────┘
              XPC (on-demand)  │          │ Process   │ XPC      │ one-shot, started by the user
        ┌──────────────────────┘          │           │          └───────────────┐
        ▼                                 ▼           ▼                          ▼
 ┌───────────────────┐      ┌───────────────────┐ ┌──────────────────┐ ┌──────────────────────┐
 │ PrivateBridge.xpc │      │ /usr/bin/perl     │ │ Converter.xpc    │ │ copied sudo command  │
 │ system APIs       │      │ + MediaRemote     │ │ AVFoundation/VT  │ │ or NSAppleScript with│
 │ behind a bridge   │      │   Adapter.fwk     │ │ └─▶ ffmpeg (LGPL)│ │ admin privileges:    │
 │ on-demand         │      │ (stdout JSON)     │ │     child proc   │ │ pam_watchid +        │
 │                  │      └───────────────────┘ └──────────────────┘ │ sudo_local + watchdog│
 └───────────────────┘                                                 └──────────────────────┘
 ┌───────────────────┐
 │ Duo (local)       │◀── lid-angle HID + frozen frame + Metal shader ──▶ built-in display
 └───────────────────┘
        Remote: LAN QUIC/TCP, TLS 1.3 pinned mTLS (Bonjour _tsukumo._udp/_tcp)
        Windeck: LAN WebSocket over TLS/TCP, same pinned identity (_tsukumo._tcp)
        │                                                    App Group socket (Team-ID group)
 ┌──────┴─────────────────────────────┐                ┌──────────────┴──────────────┐
 │ Tsukumo Remote (iOS app + watchOS app)│                │ Tsukumo Home (Catalyst, MAS) │
 │ trackpad·Windeck                     │                │ HMHomeManager → Unix socket │
 └──────────────────────────────────────┘                └─────────────────────────────┘
```

### 4.2 Module system and definition of "zero cost"

Every module is a **Swift Package target** statically linked. No dynamic bundles are loaded, which would complicate signing and notarization.

**What "zero cost" means, precisely.** A module that is off is not instantiated and registers no resources. Its code, however, is still in the binary, and a static binary pays some costs at startup even for code that is never run:
- registration of ObjC classes and Swift metadata present in `__objc_classlist`, and immediate realization of classes with `+load` (`__objc_nlclslist`);
- static C/ObjC initializers (`__mod_init_func`, `__init_offsets`) of vendored code;
- scanning of Swift conformance records, whose cost grows with the binary;
- SwiftUI type metadata, which is lazy but gets instantiated if a module that is off builds its views at startup.

For this reason "zero cost" is a set of **binding rules** plus **measurements**, divided between deterministic checks (blocking on PRs) and statistical measurements (on real hardware).

Rules, verified in code review and by scripts:
1. No global variable or `static let` with an initializer that has side effects: registering observers, `UserDefaults.register`, creating windows or items, starting tasks. Swift globals are lazy, but we forbid side effects anyway, because the first access could happen while the registry is being built.
2. No `+load`, no `+initialize` with effects, no `__attribute__((constructor))`, no `@objc`/`NSObject` subclass that registers itself on import (value transformers, `NSApplicationMain`, swizzling). A script analyzes the final Mach‑O with `otool -ov` and `otool -l` and fails if `__objc_nlclslist`, `__mod_init_func` or `__init_offsets` contain module symbols. Only `Core` is allowed, with an explicit allowlist.
3. `ModuleDescriptor` is a literal constant value, readable without touching other module code.
4. **`NSStatusItem` is created only inside `start()`**, never at app launch. A module's SwiftUI views and asset catalogs are built and loaded only after `start()`.
5. Every resource goes through the `ResourceBag`.

**Measurements, level 1: deterministic, blocking on PRs** (GitHub‑hosted runners):
- empty `ResourceBag`, no tap, no child process, `NSStatusItem` and windows back to their initial state after `start()` → `stop()` of every module;
- no `.mouseMoved` monitor registered (assertion in the `ResourceBag.addMonitor` wrapper);
- analysis of the Mach‑O sections of rule 2.

**Measurements, level 2: statistical, informative on PRs** (GitHub‑hosted runners). On virtualized, shared runners a Δ of 15 ms or 1.5 MB is below the noise, so these measurements are only a report:
- **physical footprint** of the "all off" app compared with a `CoreOnly` control build, which contains only `Core` and no modules;
- **startup time to idle** (from process start to the first runloop idle after `applicationDidFinishLaunching`, with `os_signpost`): 15 launches of `CoreOnly` and 15 of the app, alternated, in the same job;
- the PR fails **only** for gross regressions: median startup Δ > 50 ms **and** beyond 3σ of the `CoreOnly` distribution measured in the same job, or footprint Δ > 6 MB;
- binary size reported in every PR, for information only.

**Measurements, level 3: tight thresholds, post‑merge on the self‑hosted Mac mini** (real hardware, merged code only, §5.3):
- footprint Δ ≤ 1.5 MB and median startup Δ ≤ 15 ms, over 30 alternated launches per arm, with a 95% confidence interval in the report;
- an overrun opens or updates a `zero-cost-regression` issue with the guilty commit. With the `blocker` label the issue blocks the release (§3.4).

```swift
// Only our own types or Foundation types that are surely Sendable: no Color,
// LocalizedStringResource or OperatingSystemVersion (conformances vary between SDKs,
// and OperatingSystemVersion is not Hashable). The descriptor is NOT a dictionary key.
public struct ModuleDescriptor: Sendable {
  public let id: String                 // "island.media", registry key
  public let nameKey: String            // key in the String Catalog; the UI resolves it
  public let symbol: String             // SF Symbol
  public let tint: ModuleTint           // our own enum (.blue, .orange, ...) → Color only in the UI
  public let permissions: Set<Permission>   // our own enums: .accessibility, .inputMonitoring, ...
  public let energyClass: EnergyClass   // .zero, .low, .medium, .high (shown in the UI)
  public let requiresHelper: Set<HelperID>
  public let minOSMajor: Int            // e.g. 26
  public let minOSMinor: Int            // e.g. 0
}

@MainActor
public protocol TsukumoModule: AnyObject {
  nonisolated static var descriptor: ModuleDescriptor { get }   // constant, readable without instantiating and outside the MainActor
  init(context: ModuleContext)                      // no side effects
  func start() async throws      // registers resources ONLY through context.resources
  func stop() async              // the ResourceBag cancels everything automatically
  var settings: AnyView { get }  // built only when the page is visible
  var health: ModuleHealth { get async }   // canary for the private APIs
}
```

- **`ModuleRegistry`** is keyed on `id: String`: `[String: ModuleEntry]`, where `ModuleEntry` holds the `descriptor` and the factory `(ModuleContext) -> any TsukumoModule`. A duplicate id fails a deterministic test. A module that is off is **not instantiated**. The minimum version check compares `minOSMajor`/`minOSMinor` with `ProcessInfo.processInfo.operatingSystemVersion`.
- **Lazy start:**
  - when a module is turned on, permissions are requested first and then `start()` is called;
  - some modules start only at first real use: the Converter at the first conversion; Duo opens the sensor only with the module on and capture only during the motion.
- **`ResourceBag`:** all of a module's resources go through here (`NotificationCenter` observers, timers, subscriptions to `InputTapService` and to the `EventBus`, `Process`es, XPC connections, sockets, `NSEvent` monitors, `AXObserver`s, `NSStatusItem`s, windows). Every resource is a `Cancellable` token, and `stop()` closes them all. In debug an assert after `stop()` verifies that the bag is empty.
- **Crash isolation:** if `start()` throws an error or `health` reports a problem, the module goes to the `.suspended` state, a banner appears ("Apple changed something: module paused") and the rest of the app carries on. Before suspension the module's system-state restores are run, for example ⌘⇥ (§2.2.1).
- **Third-party modules:** out of v1. In phase 5 a module SDK arrives, with modules built in the repo through PRs, modeled on Raycast extensions. No loading of arbitrary code at runtime.

### 4.3 Shared services (`Core`)

| Service | Responsibility |
|---|---|
| `PermissionBroker` | TCC state (`AXIsProcessTrustedWithOptions`, `CGPreflightScreenCaptureAccess`, `IOHIDCheckAccess`/`CGPreflightListenEventAccess`, EventKit, Motion, Bluetooth, Local Network). Lazy requests, deep links to `x-apple.systempreferences:`, grant detection (1 s polling only while the sheet is open). **Functional check after the grant:** a "granted" permission is not enough, the broker tests the real resource. For an event tap it retries `CGEvent.tapCreate` for 3 s; for Screen Recording it calls `SCShareableContent`. If the test fails, which happens often because `CGEventTapCreate` stays `nil` until the process restarts, it proposes **"Restart Tsukumo"**: a one‑shot `Process` `/bin/sh -c 'sleep 1; open -b <bundle id>'` followed by `NSApp.terminate`. On restart the module starts again by itself. Diagnostics for Local Network, which fails silently. |
| `EventBus` | Typed channels (`.mediaChanged`, `.powerChanged`, `.dragEnteredNotch`, `.screenLocked`, `.windeckAction`...). Modules talk to each other only through here (for example, the Converter receives files from the shelf, Windeck calls Snap's layouts). **Multicast, not a shared `AsyncStream`:** an `AsyncStream` has a single consumer, and a second subscriber would steal elements from the first. Each channel is an `actor` broadcaster that keeps **one `Continuation` per subscriber** in a registry; `subscribe()` creates a new `AsyncStream`, registers its continuation and returns a `Cancellable` token that ends up in the module's `ResourceBag`, so `stop()` cancels it and `onTermination` removes it from the registry. **Explicit buffering:** `.bufferingNewest(1)` for state streams (only the latest value matters), `.bufferingNewest(n)` with a small, documented n for discrete events; **never** `.unbounded`. |
| `InputTapService` | **At most 2 taps for the whole app**. Each module subscribes with an event mask; the tap uses the **union** of the subscribers' masks and is recreated when the union changes. A tap with no subscribers is removed. <br>• **Listen tap** (`.cgSessionEventTap`, `.listenOnly`, dedicated thread): `keyDown/keyUp` for Clack. Permission: Input Monitoring. <br>• **Active tap** (`.cgSessionEventTap`, `.defaultTap`): `keyDown/keyUp/flagsChanged` for Switcher. Permission: Accessibility; on recent macOS versions an active tap that receives keyboard events requires **Input Monitoring too**. Until spike 6 confirms it on 26 and 27, the permission is **TBD**: the `PermissionBroker` checks both and the onboarding badges (§6.1) stay provisional. The callback is O(1): with the switcher closed it only compares the activation combination and returns the event unchanged; with the switcher open it consumes Tab, arrows and Esc and intercepts the modifier release. <br>• Re-enabling on `tapDisabledByTimeout`/`ByUserInput`. Callback with a 1 ms budget measured with `os_signpost`. |
| `SurfaceManager` | Island/notch per screen (with dynamic frame, §2.1.1), unified `NSStatusItem`s ("a single Tsukumo item" option or one item per module), overlay windows per screen (snap preview), switcher. **Level arbiter** between Island and Switcher, so they do not cover each other. Recalculation on `didChangeScreenParameters`. For status items it offers `updateIfChanged(_:)`, which redraws only if the displayed content has changed. |
| `SharedSampler` | A single `DispatchSourceTimer` with leeway, sampling for Monitor and Battery. Paused on `screensDidSleep`, lock and Low Power. |
| `Settings` | `Defaults` with a namespace per module, JSON export/import, per-module reset. |
| `Hotkeys` | Direct Carbon `RegisterEventHotKey` (internal implementation, §3.3) for module actions, with conflict detection. The recorder **rejects ⌥‑only and ⌥⇧ combinations** and explains why: since Sequoia they are blocked or intermittent. Combinations that require the modifier release go through `InputTapService`. |
| `CompanionLink` | Bonjour (event-driven `NWListener`), pairing, mTLS, device registry with scopes and revocation, per-module message routing (Windeck, Pointer; see §7). No Bluetooth since 1.3. |
| `Compat` | EdDSA-signed `compat.json`: module × macOS build combinations known to be broken → preventive suspension with a banner. |
| `Diagnostics` | MetricKit subscriber, payload rotation, `.ips` and log collection, redacted export (§3.6). |
| `Intents` | App Intents and the `tsukumo://module/action` URL scheme for Shortcuts and Raycast, with the security rules of §4.3.1. |
| `Telemetry` | **Does not exist.** Only local `os.Logger` and `os_signpost`. |

#### 4.3.1 URL scheme and App Intents: attack surface

The `tsukumo://` scheme and App Intents are **not authenticated**: any web page, app or Shortcut can invoke them. For this reason:
- **Allowlist of actions without side effects**, executed immediately: reading a state (for intents), opening a panel or a Settings page, showing or hiding Island, media play/pause, changing Windeck page. The list lives in the code as a closed `enum`; an action not on the list is rejected and logged.
- **Mandatory in‑app confirmation**, with a Tsukumo sheet in the foreground saying who asked for what, for everything that changes security or system state: pairing a device, changing Windeck's scopes, enabling ⌘⇥ (§2.2.1), installing or rolling back WatchSudo, turning a module on or off. None of these actions has a "no confirmation" variant.
- **Pairing:** the `tsukumo://pair?…` link is read **only** by Tsukumo Remote's camera. The Mac's URL handler always rejects the `pair` host and never accepts the QR secret from a URL: the secret lives only in the memory of the pairing sheet that generated it.
- **Parameters:** validated with strict types (enums, integers with limits), never passed to a shell or to AppleScript. Windeck's shell and AppleScript actions are not reachable from a URL or from an App Intent.

### 4.4 Repository layout

```
tsukumo/
├─ App/                         # thin app target (XcodeGen project.yml)
│  ├─ TsukumoApp.swift  Info.plist  InfoPlist.xcstrings  Tsukumo.entitlements  manifest.yml
│  ├─ embedded.provisionprofile (CI)  Assets/  Tsukumo.icon (Icon Composer)
├─ Packages/
│  ├─ Core/                     # ModuleKit, ResourceBag, EventBus, PermissionBroker, InputTapService, Surfaces, Settings, Diagnostics
│  ├─ DesignSystem/             # tokens, glass components, module icons, animations (Ripple, IslandMorph)
│  ├─ Modules/
│  │  ├─ Island/  (Media, Battery, Calendar, HUD, Shelf, AirDrop)
│  │  ├─ Snap/  Tile/  Switcher/  MenuBar/
│  │  ├─ Monitor/  Clack/
│  │  ├─ Pointer/  Remote/  WatchSudo/  Duo/
│  │  ├─ Windeck/  (Actions, Profiles, Topics, Editor)
│  │  └─ Convert/  Home/
│  ├─ Bridges/                  # private API wrappers: SkyLight, CGS, DisplayServices, IOReport, SMC
│  ├─ Protocol/                 # companion messages, pairing, mTLS, identity (swift-certificates), Windeck profile schema, shared with iOS
│  └─ Vendor/                   # DynamicNotchKit (MIT), mediaremote-adapter (BSD), pam-watchid (Unlicense) with their original LICENSE files
├─ Helpers/  PrivateBridge/  Converter/
├─ Companion/  iOS/  watchOS/  Home-Catalyst/
├─ Data/  sensors.json  soundpacks/ (only packs with an explicit license)
├─ Tools/  energy-harness/  battery-workload/  zero-cost/  manifest-check/  license-boundary/  release/  compat-sign/
├─ Docs/   ARCHITECTURE.md  ENERGY.md  PRIVACY.md  MODULE_GUIDE.md  NAME_CHECK.md  SECURITY.md
├─ CONTRIBUTING.md  LICENSE (GPL-3.0-only)  LICENSES/ (GPL-3.0-only, MIT, Unlicense…)  THIRD_PARTY_NOTICES.md  REUSE.toml
└─ .github/ workflows/  FUNDING.yml  CODEOWNERS  ISSUE_TEMPLATE/
```

Each file's license is declared explicitly with the [REUSE](https://reuse.software) standard (SPDX headers and per-path annotations in `REUSE.toml`), to keep the licenses of third-party code clearly tracked. The license rules are in §8.3.

### 4.5 Tsukumo Home: App Review risks and App Group rules

Tsukumo Home (Phase 5) is a Catalyst app on the Mac App Store that uses `HMHomeManager` and exposes the devices to Tsukumo (Developer ID) through a Unix socket in the shared App Group container. It is not a trivial integration.

**App Review risk: medium.** The guidelines that matter:
- **2.4.5 (Mac App Store requirements):** mandatory sandbox (Catalyst complies); self-contained app, which does not install code or resources in shared paths; no automatic launch at login without explicit consent; no process that keeps running after closing without consent. So Home neither installs nor launches Tsukumo, and its login item (`SMAppService`) is an explicit toggle, off by default.
- **2.5 (software requirements):** 2.5.1, public APIs only: no SPIs of the Home app, for example on hidden action sets. 2.5.2, no downloaded code. 2.5.4, background services must be justified.
- **4.2.3:** the app must work on its own, without requiring another installed app. This is the main risk: an app that "only serves to feed an external app" risks rejection.
- **5.1.2 (vi):** HomeKit data is not used for advertising or data mining. Sharing with another app by the same developer must be declared in the privacy policy and in the review notes.

Mitigation:
- Home is a **complete HomeKit menu bar app**, useful on its own (tiles, scenes, hotkeys), modeled on Itsyhome and HomeConMenu.
- The "Share with Tsukumo" integration is an option that is off by default, described in the review notes with a video.
- No data leaves the Mac.
- Plan B in case of rejection: Home stays a standalone app and Tsukumo uses only Home Assistant.

**App Group rules on macOS 15+:**
- **Identifier with a Team ID prefix:** `<TEAMID>.app.tsukumo.shared`, the form recommended on macOS (Mac style, it does not need to be registered in the portal). On macOS 15+ the prompt "“Tsukumo” would like to access data from other apps" appears if the app accesses a group container it is not authorized for: a Mac-style group is authorized if the prefix matches the signature's Team ID (and a Mac profile with App Groups already includes `<TEAMID>.*`); an iOS-style group (`group.…`) is authorized only by a profile.
- **Profile embedded in the Developer ID app:** Tsukumo must include a Developer ID profile with the App Groups capability for that group (`Contents/embedded.provisionprofile`, signed together with the app in CI). Tsukumo Home gets its own Mac App Store profile with the same group.
- **Catalyst:** spike 12 must verify that a Catalyst MAS app accepts the Team ID-prefixed group on 26 and 27. If it does not accept it, we use a `group.app.tsukumo.shared` group registered in the portal and authorized in **both** profiles.
- **Socket:** the path must stay within the 104 bytes of `sun_path`, so the name is short (`c.sock`). On the Home side the peer is validated: `LOCAL_PEERTOKEN` → audit token → `SecCodeCopyGuestWithAttributes` with the requirement `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "<Tsukumo's bundle id>"`. Any other process is rejected.

---

## 5. Energy and performance budget

### 5.1 Targets per module

Measurements are taken on Apple Silicon M1 (the slowest baseline), with the screen on. **Rest** = module on, user not interacting. Average CPU values over 120 s. RAM = incremental *physical footprint*. **Out-of-process costs** = difference from the baseline in the system processes that work on our behalf: WindowServer (composition, status item redraws, IPC such as `CGWindowListCopyWindowInfo`), GPU (`gpu_power`), coreaudiod (audio IO). These costs do not show up in the app's CPU, but weigh on the battery.

They are **design targets**, not measurements: they must be confirmed with the harness.

| Module | App CPU at rest | Wakeups/s at rest | App CPU in use | Out-of-process costs | Extra RAM | Key techniques |
|---|---|---|---|---|---|---|
| **Base app, all modules off** | **< 0.05%** | **0** | – | 0 | **≤ 35 MB** | no timers, App Nap respected, §4.2 rules |
| Island (collapsed) | 0.0% | 0 | expanded with music < 1.5% | rest: 0. In use: WindowServer Δ < 1%, GPU Δ < 20 mW (30 fps visualizer on a small area) | +8 MB | solid, static black when collapsed (no damage, no recomposition), `NSTrackingArea` and no `.mouseMoved` monitor; continuous animations (wave, equalizer, time bar) only in Core Animation, never per-frame SwiftUI redraws (§5.2, rule 12) |
| └ Media backend (perl child) | 0.0% | 0 | < 0.3% | – | +12 MB (perl process, to be measured) | stream on stdout; process terminated if the module is off |
| └ Shelf/AirDrop | 0.0% | 0 | burst during the drag | – | +3 MB + thumbnails | drag monitor with hit‑test limited to 60 Hz |
| Snap | 0.0% | 0 | burst | burst (preview) | +3 MB | AXObserver and monitor only during the drag |
| Tile (workspace) | < 0.2% | < 0.5 | < 1% | – | +10 MB | per-app AXObserver, incremental layout |
| Switcher | 0.0% (tap: µs per key) | 0 | burst on open | burst | +5 MB, cache ≤ 40 MB | capture only on open or on hover, LRU, 320 px |
| MenuBar (dividers) | 0.0% | 0 | – | – | +1 MB | `NSStatusItem` length trick; no redraws at rest |
| Monitor | < 0.3% | 0.2 (1 every 5 s) | popover open < 1% | **rest: WindowServer**, one item redraw only when the displayed value changes (at most 1 every 5 s; with stable values, fewer). WindowServer Δ target < 0.2% at rest, measured | +6 MB | one sampler, 25% leeway, no subprocess, `updateIfChanged` on the item |
| Clack | 0.0% | 0 | typing < 1% | **coreaudiod**: a running engine keeps the audio hardware awake and makes coreaudiod's IO loop run at every buffer. With the default buffer (512 frames at 48 kHz) that is about 94 cycles/s; with the low-latency option (256 frames) about 187 cycles/s, **and the smaller buffer applies to all of the device's clients**. Target: coreaudiod Δ < 1.5% CPU and package power Δ < 60 mW while typing; 0 after `pause()` | +15 MB (PCM packs) | `pause()` after 15 s, default buffer, 30 ms deadline, pre‑allocated voices |
| Pointer (AirPods) | 0.0% (off outside the mode) | 0 | < 1.5% | BT radio | +4 MB | 25‑50 Hz, pause when the user looks elsewhere |
| Remote / CompanionLink | 0.0% | 0 | < 1% | – | +4 MB | Bonjour only on‑demand |
| Windeck (Mac side) | 0.0% with no phone connected | 0 | tap: burst; with a phone connected and a page with feedback < 0.5% | – | +6 MB (+ icon cache on disk) | event-driven `NWListener`, no timers; keepalive every 10 s **only** with a phone connected; topics active only with a phone connected **and** a visible page that uses them; push only on change, sliders ≤ 30 Hz; profile switching from `didActivateApplicationNotification` with a 150 ms debounce, without polling |
| Duo (hinge animation) | sensor read every 100 ms (~0.5 ms each, to be measured with the harness) | 10/s with the display on, 0 with the display off | burst only while the hinge moves (60 Hz timer, Metal frame ~0.5-2 ms) | WindowServer/GPU during the overlay (to be measured) | a single frozen frame per session | **documented exception to the "events before polling" rule**: the sensor's only event arrives at ~1 Hz, too late to start (spike 7); no process, network or virtual display |
| Convert | 0 (no process) | 0 | job: QoS utility | media engine | XPC only during the job | hardware encoders, concurrency ≤ 2 |
| Home (HA) | 0.0% | 0 | panel open < 0.5% | – | +6 MB | WebSocket only with the panel open |

**Overall budget "everything on except Duo":** < 1% CPU at rest, ≤ 120 MB, no periodic wakeups except Monitor. At rest only one out-of-process cost remains, measured by the harness: the redraws of Monitor's item in WindowServer, only when the displayed value changes and at most once every 5 s. Windeck with no phone connected adds nothing; with a phone connected it adds the 10 s keepalive and only the topics of the visible pages. The harness compares WindowServer's Δ at rest with the budget of the Monitor row.

**Always-present overlays.** Every overlay window (Island, pill, snap preview) is also evaluated for out-of-process costs. A **static** overlay generates no damage and therefore costs no recompositions; an **animated** overlay costs at every frame, in proportion to the updated area. A full-screen overlay with transparent content can prevent direct scanout of full-screen video and the compositor's low-power mode. For this reason the collapsed Island never animates. **Deliberate exception (13 Nov 2026):** while music plays the island stays in the compact state with cover art and an animated indicator (wave or colored bars, your choice; "still" turns it off); this is a product choice, not to be "fixed" in review. The animation is a `CAKeyframeAnimation` on the bar layers, not a `symbolEffect`: the `symbolEffect` redrew the whole island at every frame (3.8% CPU and +50 MB of graphics surfaces, Docs/PERF.md). When the music stops the island goes back to collapsed and static. The same holds for menu bar items: every title or image change is WindowServer work, so no item updates if the visible content does not change.

### 5.2 Mandatory techniques (code review rules)

1. **No `Timer` or `DispatchSource` outside the `ResourceBag`.** Each has a `tolerance`/leeway ≥ 10% of the interval.
2. Event sources before polling: IOKit, `NSWorkspace`, `EKEventStoreChanged`, CoreAudio, `DistributedNotificationCenter`, stdout.
3. We work only if something is visible: `occlusionState`, open popovers, screen on (`screensDidSleep`, lock).
4. `CADisplayLink` with `preferredFrameRateRange` limited to 30‑60 Hz, **only during animations**. On macOS the iOS initializer `CADisplayLink(target:selector:)` does not exist: the link is obtained from `NSView.displayLink(target:selector:)`, `NSWindow.displayLink(target:selector:)` or `NSScreen.displayLink(target:selector:)` (macOS 14+). We use the animated view's, which follows the screen it is on by itself: `let link = view.displayLink(target: self, selector: #selector(step(_:)))`, then `link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)`, `link.add(to: .main, forMode: .common)`, and `link.invalidate()` at the end of the animation (token in the `ResourceBag`). No `CVDisplayLink`, which forces full refresh.
5. Glass goes only on small, lightly animated surfaces; a `GlassEffectContainer` groups nearby surfaces.
6. QoS `.utility`/`.background` for readers and conversions. No permanent `beginActivity`.
7. Adaptive profile: in Low Power Mode or under `.serious` thermal state Monitor samples every 10 s and animated glass becomes static.
8. No recurring subprocess (`top`, `ps`, `powermetrics`). The only children allowed are perl (Media), ffmpeg and pandoc (Converter jobs) and the user-started one‑shots (diagnostics export, restart, pam installation, `shortcuts run`/`shortcuts list` and Windeck's opt‑in shell actions, one per tap).
9. **No global `.mouseMoved` monitor** in any module. Hover and hot‑zones are handled with `NSTrackingArea` on our windows; the only mouse monitors allowed are `leftMouseDown/Dragged/Up`.
10. No audio engine running without a sound to play: `pause()` after 15 s. No change to the device's IO buffer without the explicit "low latency" opt‑in.
11. **No `NSStatusItem` redraw if the displayed content does not change** (`SurfaceManager.updateIfChanged`).
12. **Continuous animations in always-present overlays (island, lock screen) are Core Animation**: infinite `CABasicAnimation`/`CAKeyframeAnimation` on layers, which the render server computes without waking the process. Banned there: `TimelineView(.animation)`, time-driven `.animation(_:value:)`, repeating `symbolEffect`s and `ProgressView(timerInterval:)`: SwiftUI updates them at every frame and redoes layout and rendering of the whole window tree (the time bar alone kept a core at 100%, Docs/PERF.md). In windows opened by the user during an action (Convert previews) `TimelineView` remains allowed.

### 5.3 How it is measured

- **Zero‑cost test**, on three levels (§4.2): blocking deterministic checks on every PR, on GitHub‑hosted runners (empty `ResourceBag`, no leftover tap, child process, `NSStatusItem` or window, no `.mouseMoved` monitor, Mach‑O analysis); footprint and startup Δ only as a PR report, blocking only beyond the wide margins; tight Δ thresholds on the Mac mini, post‑merge.
- **`Tools/energy-harness`**, on the self‑hosted M1 Mac mini, **only with trusted code**. For each scenario (`all-off`, `essential`, `all-on`, one module at a time):
  1. launches the app with the profile;
  2. waits 60 s;
  3. samples for 120 s with `powermetrics --samplers tasks,cpu_power,gpu_power --show-process-energy --show-process-gpu -i 5000 -f plist`, and extracts wakeups/s and energy impact of Tsukumo and its children, the **WindowServer** and **coreaudiod** task rows, `gpu_power` and package power; in parallel `ps -o %cpu,rss` and `footprint -p`;
  4. subtracts the baseline (same scenario with Tsukumo not running, measured in the same session) and compares with `Docs/ENERGY.md` (budget in YAML, including the out-of-process columns, with WindowServer's Δ at rest for the Monitor scenario);
  5. also runs the tight zero‑cost thresholds (§4.2, level 3);
  6. **does not block PRs.** If a budget is exceeded by 20%, it opens or updates an `energy-regression` issue with the guilty commit and the charts.
- **Self‑hosted runner security.** Running PR code from forks on a persistent machine with sudo for `powermetrics` would be a hole. Rules:
  - Allowed triggers: only `push` to `main` (post‑merge), nightly/weekly `schedule` (27.x beta) and `workflow_dispatch` by a maintainer on a branch of the main repo, after review, in an `energy` environment with *required reviewers*. Never `pull_request` or `pull_request_target`.
  - The runner is registered only on this repo, in a runner group limited to `main` workflows. It runs with a dedicated non-administrator user (`tsukumo-ci`), with FileVault on, and has no secrets: no certificates or Sparkle keys.
  - `powermetrics` is never called directly, because options such as `-o` would write arbitrary files as root. It goes through a root‑owned wrapper with fixed arguments.
  ```sh
  # /usr/local/libexec/tsukumo-powermetrics   (root:wheel, 0755)
  #!/bin/sh
  case "$1" in ''|*[!0-9]*) exit 64;; esac
  [ "$1" -ge 10 ] && [ "$1" -le 600 ] || exit 64
  exec /usr/bin/powermetrics --samplers tasks,cpu_power,gpu_power \
       --show-process-energy --show-process-gpu -i 5000 -n $(( $1 / 5 )) -f plist
  ```
  ```
  # /etc/sudoers.d/tsukumo-energy   (root:wheel, 0440, validated with visudo -c)
  tsukumo-ci ALL=(root) NOPASSWD: /usr/local/libexec/tsukumo-powermetrics
  ```
  - Ephemeral VMs (Tart or Anka) are fine for builds and beta tests, but not for energy measurements or zero‑cost thresholds: in a VM `powermetrics` does not reflect the hardware and timings are noisy.
- **MVP battery criterion**, measured on a laptop and not on the Mac mini: §9.1. It uses the same `tsukumo-powermetrics` wrapper, installed on the test laptop.
- **"Energy" panel in Settings**, visible to users too: for each module it shows the active resources taken from the `ResourceBag` (timers, taps, observers, processes), the energy class and, only while the panel is open, billed energy, wakeups and CPU time from `proc_pid_rusage` (§3.6); daily MetricKit data is added only if macOS actually delivers it. No competitor offers this transparency.
- **Development:** Instruments (Time Profiler, System Trace, Allocations, Power Profiler where available), "Energy Impact" in Activity Monitor, per-module `os_signpost`.

---

## 6. UX

### 6.1 Onboarding: all permissions on one page, at first launch

> **Changed on 13 Nov 2026** (before: "zero permissions at launch", one sheet per module). In tests with real users, asking for the permission module by module meant turning a module on, seeing it stuck, going to System Settings, coming back, restarting, and doing it all again for the next module. Now they are requested once, together, right after the preset choice. It remains true that no permission is mandatory: "Continue without" leaves everything as is and the modules degrade as described below.

1. **Welcome:** "Tsukumo replaces up to 12 apps. Turn on only what you need. No accounts, no tracking." Animation of the notch expanding.
2. **Choose your tools:** cards with the presets *Essential* (Island, Snap, Monitor), *Power user* and *Customize*.
3. **Permissions (single page):** one row for every permission declared by **all** the modules built into the app and verifiable without using it (today Accessibility, Input Monitoring, Screen Recording), plus "Full Disk Access" as optional (needed only by MenuBar). Each row says why it is needed in one sentence, which modules use it and the state. "Request all permissions" starts the requests in a row; the row buttons also open the right System Settings page, because macOS shows its prompt only once. The state is reread when the app becomes active again, without polling. If a permission that applies only to a new process (tap, capture) has been granted, the final button becomes "Restart Tsukumo and start": the chosen modules are already saved and restart on relaunch. The same page reopens from *Settings → General → Review permissions…*. The permissions that macOS does not let us verify (Automation, Bluetooth, Local Network, System Audio Recording) are still requested by the system at first use.
4. **Menu bar warning (26 and 27):** if the Tsukumo icon is hidden by the *System Settings → Menu Bar* toggle, we show how to turn it back on, with a deep link. The detection method is spike 8.
5. **After onboarding.** A module turned on later without its permission shows the Permissions section on its page, which contains:
   - why it is needed, in one line and in plain words, plus what we **do not** do ("we read only key codes, never the text, no network");
   - an animated illustration of the toggle in System Settings;
   - the "Open Settings" button (deep link) and automatic grant detection with **functional verification**: the sheet turns ✓ and the module starts only when the resource really works (tap created, capture succeeded). If after 3 s the permission shows as granted but the tap is not created, the sheet says "macOS requires Tsukumo to restart to activate the permission" and offers **"Restart now"**, with automatic relaunch and module resume. The relaunch uses the path derived from `Bundle.main.bundleURL` (`open -n <path>` or `NSWorkspace.openApplication(at:configuration:)`), never `open -b <bundle id>`, which could launch another installed copy;
   - **for Screen Recording** (Switcher thumbnails, MenuBar backend B and Duo) the sheet explains that macOS may periodically ask for consent again and show the indicator during capture. For each module we indicate the alternative without the permission: Switcher with icons and titles, MenuBar backend A; Duo is not available without access to the frame;
   - **for Windeck**, the activation sheet explains that a paired phone can run actions on the Mac; it shows the device's scopes, with **shell and AppleScript off by default**, and asks for confirmation on the Mac at the first connection of every device (§2.6, §7.3). Accessibility and Automation are requested only at the first action that uses them;
   - "Not now": the module stays off, no nagging.

If the user refuses a permission, the module degrades where it can. Examples: MenuBar without Screen Recording uses the divider backend; Switcher without Screen Recording shows icons and titles obtained via AX.

### 6.2 Apple-style Settings window

- `NavigationSplitView` with a glass sidebar (automatic on 26 and 27) and content in `Form` with `.formStyle(.grouped)`: it is the same language as System Settings. In the toolbar there is a search field that indexes every option of every module.
- **Sidebar:**
  - General
  - *(Modules section)*: one row per module, with a white SF Symbol icon on a colored rounded square and an inline toggle
  - Permissions (dashboard of all TCC states, with "repair" and "restart" buttons)
  - Energy (§5.3)
  - Devices (companion pairing, per-device scopes, revocation)
  - Shortcuts (all hotkeys, conflicts highlighted)
  - About and support (includes "Export diagnostics")
- Every module page has at the top a **live preview** (the notch in miniature) and at the bottom "Reset module settings".
- The window opens as an `NSWindow` managed by us, not with the `Settings` scene, to avoid the known `openSettings` bugs from an LSUIElement app. On close it goes back to `.accessory`.
- **Menu bar item:** by default a single "Tsukumo" item, created lazily, which opens an `NSGlassEffectView` panel with the modules and quick actions. Option to have one item per module (Monitor, Home).
- **Accessibility:** VoiceOver labels on every control; with Reduce Motion ripples and morphs disappear; full keyboard support; Dynamic Type where AppKit allows it.

### 6.3 Design resources

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines): sections Materials/Liquid Glass, Menu bar, Settings, Sidebars, Motion, App icons.
- [Apple Design Resources](https://developer.apple.com/design/resources/): macOS 26 and 27 kits for Figma and Sketch, from which the mockups of all screens are made.
- **SF Symbols 7** (or the current version), used only as system symbols: no custom icon set except the logo. **SF Pro** through the system font.
- **Icon Composer** (Xcode 26+) for the layered Liquid Glass `.icon`, with light, dark and tinted variants.
- WWDC25 sessions: *Meet Liquid Glass*, *Get to know the new design system*, *Build a SwiftUI app with the new design*, *Build an AppKit app with the new design*, *Create icons with Icon Composer*.
- Sounds and feedback: system sounds and `NSHapticFeedbackManager` (`.alignment` on snap).
- `DesignSystem` gathers spacing, radii (the same as the physical notch), standard spring curves (`island = spring(0.4, 0.75)`, `fly = spring(0.45, 0.8)`) and the components `GlassPill`, `GlassHUD`, `ModuleIcon`.

---

## 7. Companion apps (iOS and watchOS): "Tsukumo Remote"

> **Superseded on 12 Nov 2026:** no native app on iPhone, iPad or Apple Watch, and `Pointer` is dropped. What remains (Windeck, passing files from the phone) uses the web app served by Tsukumo described in §2.6. The rest of this section is historical.

**An iOS app with an associated watchOS app**, GPL‑3.0‑only, free on the App Store and on TestFlight. On watchOS we no longer talk about an "extension": the watchOS app is a **separate single-target SwiftUI target** ("Tsukumo Remote Watch App"), associated with the iOS app through `WKCompanionAppBundleIdentifier` and installed along with it. The shared logic lives in the `Protocol` package. The Watch does not talk directly to the Mac: on watchOS low-level networking is allowed only in limited cases (TN3135), so it goes through WatchConnectivity to the iPhone, which acts as a relay. Because of this relay's latency (100‑300 ms and more, with jitter) the Watch only does discrete commands: **no gyroscopic pointer** since 1.3. Windeck is not a separate app: it is a section of Tsukumo Remote and shares pairing, identity and `CompanionLink` (§7.1, §7.3).

| Function | iPhone/iPad | Watch | Phase |
|---|---|---|---|
| Trackpad, keyboard, media keys, presentations | ✓ | media keys, volume with the Digital Crown and presentations (via iPhone), foreground only | 3 (Watch: 4) |
| **Windeck**: customizable deck (buttons, toggles, sliders, knobs, folders, per-app profiles, live feedback) | ✓ iPhone; iPad with a larger grid | mini‑deck of 4‑6 actions via WatchConnectivity, Digital Crown for volume | 3 (Watch: 4) |
| Tsukumo notifications (Converter jobs, etc.) | ✓ (local, via active LAN link) | ✓ (system mirroring) | 4 |

### 7.1 Secure pairing

The scheme uses only standard TLS 1.3 with **mutually pinned** self‑signed identities. Neither PSK nor PAKE is needed.

1. **Identity.** Each device generates once a **P‑256 key in the Secure Enclave** with `SecKeyCreateRandomKey`, `kSecAttrTokenIDSecureEnclave` and `kSecAttrIsPermanent`, in the data protection keychain and in the Team's access group. On Apple Silicon Macs and on iPhone the procedure is the same. To pass the key to `sec_protocol_options_set_local_identity` a `SecIdentity` is needed, that is a certificate paired with the key. **On iOS there is no public API to create a self‑signed X.509 certificate, nor `SecIdentityCreate`**, which exists only on macOS. For uniformity we use the same path on both platforms, inside the `Protocol` package:
   1. the self‑signed certificate is built with **[apple/swift-certificates](https://github.com/apple/swift-certificates) + [swift-crypto](https://github.com/apple/swift-crypto)** (Apache‑2.0): subject = device ID, long validity, `basicConstraints CA:false`, `keyUsage digitalSignature`, `extendedKeyUsage` serverAuth + clientAuth;
   2. it is **signed with the SE key**: with a `Certificate.PrivateKey` built from the SE `SecKey`, where the pinned swift-certificates version supports it; otherwise the `TBSCertificate` is serialized to DER, signed with `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` and the certificate is assembled. The private key never leaves the enclave;
   3. `SecCertificateCreateWithData` on the DER, then `SecItemAdd` with `kSecClassCertificate` in the same keychain and the same access group as the key;
   4. `SecItemCopyMatching` with `kSecClassIdentity` (filter on `kSecAttrApplicationLabel`, that is the public key hash) returns the `SecIdentity`, which the keychain composes by pairing certificate and key.
   The same curve on both sides eliminates mixing with Curve25519. Spike 4 verifies this path explicitly, first on iOS.
2. **QR on the Mac** (*Settings → Devices → Add*): `tsukumo://pair?svc=<Bonjour name>&fp=<SHA‑256 of the Mac's SPKI>&s=<32-byte secret>&exp=<ts>`. The secret is single-use and expires in 120 s. The QR is read only by Tsukumo Remote's camera: the Mac's URL handler **never accepts** `tsukumo://pair` or the secret (§4.3.1).
3. **Connection.** The iPhone opens TLS 1.3 over QUIC (`NWProtocolQUIC`) or over TCP (`NWProtocolTLS`) presenting its own client certificate. In `sec_protocol_options_set_verify_block` the iPhone accepts the server only if the SPKI matches the QR's `fp`. The Mac, in pairing mode, accepts the client certificate and records its SPKI.
4. **QR proof bound to the channel.** Inside the channel the iPhone sends `PairRequest{name, clientSpki, tag}`, where `tag = HMAC‑SHA256(HKDF(s, "tsukumo-pair-v1"), exporter ‖ clientSpki)` and `exporter` is the session's TLS exporter (`sec_protocol_metadata_create_secret`, label `EXPORTER-tsukumo-pair`, 32 bytes). The Mac recomputes the tag with its own exporter. This proves that the peer read the QR and that the channel is the same one, hence no MITM or relay. The Mac replies with its own confirmation HMAC and the secret is burned. It is a one-time authenticated key exchange: afterwards, the secret is of no use.
5. **Confirmation on the Mac and saving.** At the first connection of every device the Mac shows a sheet "Connect «…'s iPhone»?" with name and fingerprint: without a click on the Mac the pairing is not completed. Then each side saves the other's SPKI in the Keychain (`ThisDeviceOnly`, no iCloud sync). The Mac associates with each device its **scopes** (Remote: pointer and keys; Windeck: keys, apps and URLs, Shortcuts, media and volume, OBS; **shell and AppleScript off by default**, enabled only from the Mac).
6. **Subsequent sessions:** mTLS with mutual pinning in `sec_protocol_options_set_verify_block`. Forward secrecy comes from TLS 1.3's ECDHE. There is no additional application-level encryption. **Revocation** is done from both sides by deleting the SPKI (*Settings → Devices*): the open connection closes immediately. Every received message is checked against the device's scopes. No cloud.
7. **Transport:**
   - **Network.framework QUIC:** streams for reliable messages, QUIC datagrams (`isDatagram`) for pointer deltas. If QUIC is not available (some networks block UDP) TCP + TLS with `TCP_NODELAY` is used, and pointer deltas travel on the same stream with "last one wins" coalescing. There is no home-made encrypted UDP channel.
   - **Windeck:** WebSocket (`NWProtocolWebSocket`) over the same pinned TLS/TCP, on the `_tsukumo._tcp` service (§7.3).
   - No Bluetooth: the 1.2 BLE channel was used only for unlocking, which has been removed (§7.2).
   - The Watch always goes through WatchConnectivity to the iPhone.
8. **Network diagnostics** on iOS and on Mac: Local Network permission, Bonjour resolution, RTT, p95 latency of Windeck taps. It is the number one support problem.

### 7.2 Unlocking the Mac with the iPhone: why we do not do it

> **Why we do not do it.** Up to version 1.2 the document included "Unlock with iPhone": Face ID on the phone, then the Mac typed the login password by itself at the lock screen. To do that, Tsukumo would have had to **save the user's login password** in the Keychain and **type it with synthetic events** on a screen protected by Secure Event Input. It is a real attack surface: a reusable password on disk, a process with Accessibility that writes it, and the risk of typing it into the wrong app if the session state changes at the wrong instant. No convenience is worth this risk in a general-purpose toolkit. **Native alternatives already exist:** automatic unlock with the Apple Watch (*System Settings → Touch ID & Password → Apple Watch*) and Touch ID. With the feature the BLE channel, the automatic lock on walking away, the Face ID key in the phone's Secure Enclave and the related spikes also go away. For `sudo`, WatchSudo remains (§2.4.1), which goes through the system path and never touches the password.

### 7.3 Windeck in the companion: iPhone and iPad as a Stream Deck

Windeck is a section of Tsukumo Remote ("Deck" tab), not a separate app: it uses the same pairing, the same pinned identities and the same `CompanionLink` as the trackpad. The Mac part (actions, profiles, topics, security) is in §2.6.

**Discovery and transport.**
- **Discovery:** Bonjour with `NWListener` on the Mac and `NWBrowser` on the phone, `_tsukumo._tcp` service (already in `NSBonjourServices`, §3.8). The Mac's listener is event-driven and costs nothing until someone connects.
- **Transport:** WebSocket (`NWProtocolWebSocket`) over TLS 1.3 on TCP, with the pinned mTLS of §7.1 (`sec_protocol_options_set_verify_block`). Messages in JSON in v1; MessagePack as an option if measurements justify it, with the same schema.
- **Latency:** `TCP_NODELAY` (`NWProtocolTCP.Options.noDelay`), interactive service class on `NWParameters.serviceClass` (`.interactiveVoice` or `.responsiveData`, chosen in spike 18), target **p95 < 30 ms per tap** from the touch to the action on the Mac on home Wi‑Fi (measured with `os_signpost` on both sides, spike 18); **acceptable fallback: p95 < 50 ms**. The iPhone's Wi‑Fi power‑save can add tens of ms to the first packet after inactivity: mitigation, closely spaced keep‑alive (e.g. 2‑3 s) while the deck is visible, at rest the cadence goes back to 10 s.
- **Keepalive** every 10 s, only while the connection is open. **Full snapshot** of the state (active profile, values of visible topics) at every reconnection, so the phone does not have to rebuild anything.

**Pairing.** The same QR as §7.1: the Mac certificate's fingerprint plus a single-use secret, mTLS with mutual pinning, keys in the Keychain. Confirmation on the Mac at the first connection, revocable devices, per-device scopes with shell and AppleScript off by default.

**iOS limits and usage modes.**
- **Foreground only.** iOS does not keep an app alive in the background for this use, and we do not ask for it: the connection opens when the Deck tab is visible and closes when the app goes to the background.
- **Keeping the screen on:** "stay on" option (`isIdleTimerDisabled`) with **auto‑dim** after a configurable time, **OLED black mode** (pure black background, dimmed controls) and **dock mode** for a phone resting on the desk or charging.
- **iPad:** larger grid (up to 8 × 6 on 13"), same profile schema; the layout adapts to the page's `rows`/`cols`.
- **Editing:** profiles are edited on the Mac (editor in Settings, with drag&drop) and, from the beta phase, also on the phone; the Mac remains the source of truth and validates every change.
- **Apple Watch:** mini‑deck of 4‑6 user-chosen actions, sent via WatchConnectivity through the iPhone, and Digital Crown for volume. Given the relay latency (§7), on the Watch there are only discrete actions, never continuous sliders.

**Phone energy.** No background work; with the screen on the cost is dominated by the display, so auto‑dim and OLED mode are the default of dock mode. The CPU works only on touch and on receiving topic changes (≤ 30 Hz per slider).

---

## 8. Licenses and code reuse

### 8.1 Why GPL‑3.0 for the project

- The most mature references for notch, switcher, Dock previews and menu bar include GPL‑3.0 projects: boring.notch, Atoll, MewNotch, AltTab, DockDoor, Thaw and Loop (licenses verified with the GitHub API on 2026‑11‑09).
- With an MIT license we would have to rewrite everything clean‑room. Estimate: **+25‑35 weeks** for a single developer, with the risk of "contamination" from unintentional reading.
- MIT, BSD, Apache‑2.0, MPL‑2.0 and Unlicense enter a GPL‑3.0 work without problems. Apache‑2.0 is compatible only with GPL**v3**.
- **GPL‑3.0‑only versus "or later".** Several GPL references are probably **GPL‑3.0‑only**: the SPDX id returned by the GitHub API (`GPL-3.0`) does not distinguish the two variants, which can be read only in each file's header and in the LICENSE (the "or (at your option) any later version" clause). If we combine even a single GPL‑3.0‑only file, the **distributed binary is in effect GPL‑3.0‑only**, so **we adopt GPL‑3.0‑only for the whole project**: our files carry `SPDX-License-Identifier: GPL-3.0-only`, imported files `GPL-3.0-only` or `GPL-3.0-or-later` depending on origin (compatible in both cases). We state it in the README, in the release metadata (Homebrew cask `license`, appcast, About) and record it exactly: every imported file carries its own `SPDX-License-Identifier` (`GPL-3.0-only` or `GPL-3.0-or-later`) and `REUSE.toml` annotates it per path (default `GPL-3.0-only` for our directories). Verification is done row by row of the §8.2 matrix before the first import. OpenDeck (Windeck's reference) is declared GPL‑3.0‑or‑later, so it is compatible in both cases.
- The GPL also prevents a closed competitor (NotchNook, Alcove) from taking our work.
- **Limit:** the GPL does not coexist with the App Store's terms. This is why the Mac app is distributed with Developer ID outside the App Store, and why the phone side is a web app served by Tsukumo (§2.6) rather than a native App Store app.

### 8.2 Matrix

**Criterion for dependencies and vendoring.** A repo becomes a dependency or vendored code only if it has a confirmed OSI license, **at least 50 stars and a push in the last 12 months**, and if we audit it before inclusion. The others are **reference only**: the code is read to understand the behavior, but it is not tracked as an upstream. Any copied fragments, license permitting, become our code, with attribution and our own tests. Stars and last activity come from the GitHub API and from the research of 2026‑11‑09.

| Repo | License | Stars | Last activity | Use in Tsukumo |
|---|---|---|---|---|
| [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) | MIT | ~480 | 2026‑04‑24 | **vendor** + notice |
| [NotchDrop](https://github.com/Lakr233/NotchDrop) | MIT | ~2.1k | 2026‑05‑18 | direct reuse (drag, tray, sharing) |
| [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) | MIT | ~216 | 2026‑07‑12 | **dependency**, in the main app behind `Bridges/` (the panel delegation is per‑process, §4.1) |
| [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) | BSD‑3 | ~305 | 2026‑10‑17 | upstream of the Media backend |
| [ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter) | BSD‑3 | ~57 | 2026‑11‑04 | **dependency** (bundle + notice) |
| [boring.notch](https://github.com/TheBoredTeam/boring.notch) | GPL‑3.0 | ~11.3k | 2026‑11‑09 | reuse permitted (DragDetector, ShareServiceFinder, MediaKeyInterceptor, XPC helper patterns), with copyright and attribution |
| [Atoll](https://github.com/Ebullioscopic/Atoll) | GPL‑3.0 | ~5.2k | 2026‑11‑09 | reuse permitted (OSD, lock screen widgets) |
| [MewNotch](https://github.com/monuk7735/mew-notch) | GPL‑3.0 | ~556 | 2026‑10‑28 | reuse permitted (HUD) |
| [jackson-storm/dynamicnotch](https://github.com/jackson-storm/dynamicnotch) | GPL‑3.0 | ~647 | 2026‑11‑09 | reuse permitted |
| [SlimHUD](https://github.com/AlexPerathoner/SlimHUD) | GPL‑3.0 | n/a | n/a | reuse permitted (HUD layout) |
| [Rectangle](https://github.com/rxhanson/Rectangle) | MIT | ~30.3k | 2026‑11‑06 | direct reuse (snap, `AXExtension`) |
| [AeroSpace](https://github.com/nikitabobko/AeroSpace) | MIT | ~23.8k | 2026‑11‑06 | direct reuse (emulated workspaces) |
| [Amethyst](https://github.com/ianyh/Amethyst) | MIT | ~16.3k | 2026‑11‑06 | direct reuse |
| [Hidden Bar](https://github.com/dwarvesf/hidden) | MIT | ~15.4k | 2026‑10‑31 | direct reuse (dividers) |
| [Loop](https://github.com/MrKai77/Loop) | GPL‑3.0 | ~11.9k | 2026‑11‑09 | reuse permitted |
| [AltTab](https://github.com/lwouis/alt-tab-macos) | GPL‑3.0 | ~16.5k | 2026‑11‑04 | reuse permitted; reference for SkyLight bindings, the keyboard tap and the ⌘⇥ restore |
| [DockDoor](https://github.com/ejbills/DockDoor) | GPL‑3.0 | ~6.5k | 2026‑11‑08 | reuse permitted (Dock previews) |
| [Thaw](https://github.com/thaw-app/Thaw) | GPL‑3.0 + §7 exception for PlatformRuntimeKit (removable) | ~12.6k | 2026‑11‑09 | reuse permitted; reference for the menu bar backends |
| [Ice](https://github.com/jordanbaird/Ice) | GPL‑3.0 | ~30k | last commit 2025‑09‑20; last release 0.11.12 of 2024‑10‑29 | study only; open Tahoe issues #982, #985, #1019, #1028 (verified on 2026‑11‑09) |
| [Dozer](https://github.com/Mortennn/Dozer) | MPL‑2.0 | ~8.7k | 2023‑11‑30 | compatible, but not needed |
| [Stats](https://github.com/exelban/stats) | MIT | ~43.3k | 2026‑11‑09 | direct reuse (sensor tables, SMC, IOReport) |
| [socpowerbud](https://github.com/dehydratedpotato/socpowerbud) | MIT | 93 | archived | *reference* (IOReport without sudo) |
| [MonitorControl](https://github.com/MonitorControl/MonitorControl) | MIT | ~34.7k | 2026‑10‑14 | direct reuse (DDC) |
| [Clacky](https://github.com/jasonzh0/Clacky) | MIT | **4** | 2026‑09‑01 | **reference only**: audio engine architecture rewritten by us |
| [Mechvibes](https://github.com/hainguyents13/mechvibes) | MIT | ~375 | 2026‑11‑07 | pack format. **Every sound pack has its own license**: only those with an explicit license are included, the others the user downloads by themselves |
| [HeadOrbit](https://github.com/Cogria-AI/HeadOrbit) | MIT | ~256 | 2026‑10‑30 | direct reuse (`CMHeadphoneMotionManager`) |
| [AirPodsPro-Motion-Sampler](https://github.com/tukuyo/AirPodsPro-Motion-Sampler) | MIT | ~323 | 2023‑06‑10 | *reference* (inactive) |
| [MacMotionCues](https://github.com/Lospi/MacMotionCues) | GPL‑3.0 | 89 | 2026‑05‑07 | study only |
| [mostpinkest/pam-watchid](https://github.com/mostpinkest/pam-watchid) (chosen upstream) | Unlicense (verified on 2026‑11‑09) | ~88 | 2026‑09‑19 | **vendor** in `Vendor/`, built and signed by us, with a full source audit before inclusion |
| [biscuitehh/pam-watchid](https://github.com/biscuitehh/pam-watchid) (original) | Unlicense (verified) | ~735 | 2023‑07‑14 | historical *reference* |
| [pam_reattach](https://github.com/fabianishere/pam_reattach) | MIT | ~833 | 2023‑02‑16 | **not included**: installed by the user, detected by the UI (§2.4.1) |
| [sudo-touchid](https://github.com/artginzburg/sudo-touchid) | EPL‑2.0 | ~686 | 2026‑07‑30 | obsolete, history only |
| [Itsyhome](https://github.com/nickustinov/itsyhome-macos) | MIT | ~1.0k | 2026‑11‑09 | direct reuse (also in Tsukumo Home) |
| [HomeClaw](https://github.com/omarshahine/HomeClaw) | MIT | ~192 | 2026‑11‑03 | direct reuse (Catalyst + AppKit bridge pattern) |
| [HomeConMenu](https://github.com/sonsongithub/HomeConMenu) | MIT | ~53 | **2025‑03‑23** | **reference only** (no push in over 12 months) |
| [home-assistant/iOS](https://github.com/home-assistant/iOS) | Apache‑2.0 | ~2.4k | 2026‑11‑09 | direct reuse (HA API models) |
| [Homebridge](https://github.com/homebridge/homebridge) | Apache‑2.0 | ~25.5k | 2026‑11‑08 | external integration only |
| [connectedhomeip](https://github.com/project-chip/connectedhomeip) | Apache‑2.0 | ~9.0k | 2026‑11‑09 | study (Matter, phase 5) |
| [Gifski](https://github.com/sindresorhus/Gifski) | MIT | ~8.6k | 2026‑09‑11 | UX reference |
| [Deskreen](https://github.com/pavlobu/deskreen) | AGPL‑3.0 | ~21.7k | 2026‑07‑08 | study only: unwanted network obligations |
| [HandBrake](https://github.com/HandBrake/HandBrake) | GPL‑2.0 (check whether "only") | ~24.9k | 2026‑11‑09 | **do not link** (GPLv2‑only is incompatible with v3) |
| [pandoc](https://github.com/jgm/pandoc) | GPL‑2.0+ | ~46.9k | 2026‑11‑09 | separate binary downloaded on‑demand |
| ffmpeg 9.0.2 (our build, LGPL) | LGPL | – | – | static executable inside `Converter.xpc`, included in the app (+~29 MB); reproducible build with `Tools/ffmpeg/build.sh` (pinned hashes), licenses and source offer in the bundle (`Tools/ffmpeg/README.md`) |
| [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next) | LGPL‑3.0 (verified on 2026‑11‑09) | ~198 | 2026‑10‑24 | reference for the build scripts; separate executable |
| [libvips](https://github.com/libvips/libvips) | LGPL‑2.1 | ~11.8k | 2026‑11‑09 | possible separate executable |
| [douinc/deck](https://github.com/douinc/deck) | MIT | n/a | n/a | main Windeck **reference** (SwiftUI Mac + iPhone + Watch, MultipeerConnectivity, `CGEvent`); stars and activity to be verified before copying fragments |
| [OpenDeck](https://github.com/nekename/OpenDeck) | GPL‑3.0‑or‑later | n/a | n/a | study of the Elgato plugin host and per-app profile switching (Windeck v2); code rewritten from scratch |
| [Macro Deck](https://github.com/Macro-Deck-App/Macro-Deck) | Apache‑2.0 | n/a | n/a | study (plugin and action model) |
| [Bitfocus Companion](https://github.com/bitfocus/companion) | **to be verified** | n/a | n/a | study only until the license is verified file by file |
| StreamController | GPL‑3.0 | n/a | n/a | study only (Linux) |
| [elgatosf/streamdeck-kit-ipad](https://github.com/elgatosf/streamdeck-kit-ipad) | MIT | n/a | n/a | reference for Elgato hardware (DriverKit, iPad only) |
| [PodsControlMac](https://github.com/sumionochi/PodsControlMac), [SnowFlakes](https://github.com/twstokes/snowflakes), [remote_touchpad](https://github.com/Erickrus/remote_touchpad), [media-control](https://github.com/ungive/media-control) | **no license** | 2 / 4 / 1 / 132 | 2026‑01 / 2025‑12 / 2025‑03 / n/a | **copying forbidden**, not even in a GPL project; observable behavior only |
| NotchNook, Alcove, DynamicLake, Bartender, iStat Menus, Klack, BetterDisplay, WowMouse, Elgato Stream Deck Mobile, Touch Portal | proprietary | – | – | only observable behavior is studied |

Operating rule: every imported file keeps its own SPDX header and the original copyright, and ends up in `THIRD_PARTY_NOTICES.md`. A `reuse lint` check in CI blocks PRs with files without a license. The matrix is rechecked at every release (stars, activity, license): a repo that falls below the criterion becomes "reference only" and its vendored code remains ours to maintain.

### 8.3 Contributions and licensing rules

The whole project is GPL‑3.0‑only, and contributions come in through pull requests with the DCO and no CLA: the code a contributor writes is theirs and is licensed under GPL‑3.0‑only. Therefore:

1. **Every directory accepts contributions under GPL‑3.0‑only.** This includes `Packages/Protocol/`, the module SDK (phase 5) and `Companion/` (iOS, watchOS, Home‑Catalyst). The `Signed-off-by` of the DCO attests that the contribution may be distributed under the project's license. The root `CONTRIBUTING.md` applies to the whole repository.
2. **Automatic enforcement (REUSE):** `REUSE.toml` annotates licenses per path. `Tools/license-boundary`, blocking on PRs, verifies that:
   - every file carries an `SPDX-License-Identifier`: `GPL-3.0-only` for our code, or the identifier of a listed third-party license compatible with GPL‑3.0 (MIT, BSD, Apache‑2.0, ISC, GPL‑3.0), never AGPL or unlicensed;
   - every imported third-party file keeps its original copyright and license notice and is listed in `THIRD_PARTY_NOTICES.md`;
   - a PR that adds or changes third-party code is labeled `license-boundary` and requires the review of a CODEOWNER.
3. **Third-party code under compatible licenses only.** MIT, BSD, Apache‑2.0 (compatible only with GPL**v3**), ISC and GPL‑3.0 code may be imported, with notices preserved. Never AGPL code, code without a license, or GPL‑2.0‑only code.
4. GPL third-party code (boring.notch, AltTab…) enters with its own SPDX header and its copyright intact, as recorded in the §8.2 matrix.

---

## 9. Roadmap

**Rewritten in 1.4.** The maintainer wants **a single public release, 1.0, with all the modules present**, preceded by a phase of testing, verification and bug fixing. Phase 0.5, the 15 December launch with its checkpoints and the intermediate public releases (v0.1, v0.5, v0.8, v0.9) therefore disappear. The estimates in weeks from 1.3 no longer hold and **must be redone** when the scope of the new modules is closed.

**Where we are (12 Nov 2026).** Phases 0a and 0b: code done (`ModuleKit`, `ResourceBag`, `PermissionBroker`, `InputTapService`, `SurfaceManager`, `EventBus`, `tsukumo://` router, Energy panel); **missing** are onboarding, `Diagnostics` (MetricKit), `compat.json`, energy harness, signing, notarization, Sparkle and Homebrew. Of the modules, `Island`, `Snap`, `Monitor`, `MenuBar`, `Clack` exist, none closed.

| Phase | Content | Output |
|---|---|---|
| **A · Close what exists** | `Island`: Now Playing backend 1 and padlock done (12 Nov 2026); remaining are the AirDrop animation, **lock screen with Now Playing and synced lyrics**, spikes 5 and 17. `MenuBar`: **only** icon reordering and the Full Disk Access check (spike 21). Full parity with Ice is no longer a goal (maintainer decision, 12 Nov 2026). `Clack`: spike 16. `Snap` and `Monitor`: complete the §2 items. Missing foundations: onboarding, `Diagnostics`, `compat.json`, `Bridges/` for the private APIs. | internal |
| **B · Mac-only modules** | **`Convert`** with the ⌘‑drag flow (spike 25, then tier 0, then tier 1 ffmpeg). **`Duo`**, to be done with particular care: spike 7 first, on this MacBook. **`Switcher`** (spike 6, crash‑safe ⌘⇥ restore). **`Sound`** (§2.4.1): output switching and Music blocker, then mixer and per-app output after spike 27. | internal |
| **C · Windeck and phone** | No native app (12 Nov 2026). **`Windeck` as a web app served by Tsukumo** (§2.6): HTTPS server + WebSocket, local CA and QR pairing (spike 4), grid, actions, profiles, live feedback, iPad (spike 18). **Passing files from the phone "like AirDrop"** from the same web app, with animation from the phone's side and arrival on the Desktop (spike 26). | internal |
| **D · Stabilization** | No new features. Test plan per module, zero‑cost tests on the three levels, battery criterion (§9.1), spikes still open, a full bug-fixing round, security audit of Windeck and of `tsukumo://`, accessibility, IT + EN. Signing, notarization, Sparkle with appcast, Homebrew cask, release candidate tried on the final DMG. | release candidate |
| **E · Release** | **v1.0** on macOS; iOS/watchOS 1.0 apps on the App Store. | **public v1.0** |
| **F · Before release** (at the end of phase D) | **"Send feedback"** button in Settings, addressed to the maintainer: opens a prefilled email or a GitHub issue in the user's browser, with app and macOS versions and, only if the user chooses, the local diagnostics; the app makes no network request of its own (§3.6). **Buy Me a Coffee** button in Settings (external link, §3.7). **Removal of the sample module `Hello`**: done (0.1.1). | – |
| **Beyond** | Windeck v2 (Elgato plugin host written from scratch, USB Stream Deck hardware), module SDK, Convert tier 2 (pandoc), lock screen widgets. | – |

**Rules.**
- Within a phase the order of modules is the one written; a module is closed (green build, tests, zero‑cost verification) before opening the next.
- Phase D does not start while an incomplete module exists. A module that does not survive phase D leaves 1.0 as "Experimental", off by default.
- **Things only the maintainer can do** and that are worth anticipating: Developer account and Team ID (a stable signing identity avoids TCC resets between one build and the next), TCC permission tests, battery measurements, tests with real iPhone, Apple Watch and AirPods.

### 9.1 Release criteria for 1.0

Notarized, installable with `brew`, macOS 26 and 27. **All the modules in §1**, each turned on or off by the user. Onboarding with no initial permissions, with automatic relaunch when needed. Green zero‑cost test: deterministic checks on PRs and tight Δ footprint and Δ startup thresholds, with no open `zero-cost-regression` issues. Energy budget met on M1, out-of-process costs included. Clack latency within target (p95 < 20 ms on built-in and wired outputs). Local diagnostics working. IT + EN. In the battery criterion below, "MVP modules" should be read as "always-active modules of 1.0" (Island, Snap, Monitor, MenuBar, Clack, Switcher); Convert, Duo, Pointer and Windeck work only on user action and are measured separately.

**Battery success criterion** ("24 h cost less than 1%"), defined in a measurable way and with sufficient statistical power.

Why an A/B on the fuel gauge is not enough: with 3 runs per arm, 24 h tests and a resolution in mAh, the run-to-run variability (usually 2‑5%) is larger than the 1% threshold. Such a test would never distinguish a yes from a no. The primary measurement therefore becomes the **integrated energy**, over many short, alternating blocks; the battery test remains only as a coarse check.

- **Machine:** MacBook Air M1 13" (2020), 8 GB, 49.9 Wh nominal battery, battery health ≥ 90%, current macOS 26.x and 27.x, clean test account. We do not measure on the Mac mini: a desktop has no battery, and there only power in mW is measured.
- **Fixed conditions:** brightness at 50% with automatic brightness and True Tone off, Wi‑Fi always connected to the same network, Bluetooth on with no peripherals, Low Power Mode off, Spotlight indexing completed, same apps installed, charger unplugged during the measurements.
- **Workload block** (`Tools/battery-workload`, 60 min):
  - 20 min of Safari browsing on a fixed set of locally served pages;
  - 15 min of synthetic typing in TextEdit;
  - 10 min of 1080p video in QuickTime, windowed;
  - 10 min of music in Music, which exercises Island;
  - 5 min of idle with the screen on;
  - 20 window snaps per hour.
- **Primary measurement: energy per block.**
  - **Alternating A/B** blocks in the same session (A = Tsukumo not running; B = **all MVP modules on**: Island + Snap + Monitor + MenuBar‑A + **Clack**), with 5 min of thermal/idle settling between blocks (idle with the screen on, package temperature below a fixed threshold or at most 10 min), **charge window 80%→30%**: blocks are run only with charge between 80% and 30%, and at 30% the Mac is recharged at rest up to 80% (adapter connected) and settling is awaited before resuming; charge points at the start of the session and every ~5 blocks, with the same number of A and B blocks for each charge cycle. Alternating eliminates the drift due to temperature and charge level. Clack is in arm B because it is the one that costs the most out of process: while typing it keeps coreaudiod and the audio hardware awake (§5.1). The workload's synthetic typing goes through `CGEventPost`, and these events also reach the listen tap: so the block really exercises Clack, but only if Clack is on in B. In addition, an optional **arm C** (B without Clack) separates Clack's cost from that of the other modules when the criterion is exceeded.
  - During each block, `tsukumo-powermetrics` (5 s interval) integrates the **package power** (CPU + GPU + ANE, from the IOReport Energy Model) and the per-process energy of Tsukumo and its children. In parallel the harness integrates the battery-side **system power** (`Voltage × InstantAmperage` from `ioreg -rn AppleSmartBattery`, every 10 s), which includes display and radios, that is the costs the package does not see. powermetrics runs in both arms, so its cost cancels out.
  - **Sample:** at least 12 blocks per arm (in practice 2 days of testing). The mean power Δ B − A is reported with its **95% confidence interval** (Welch's t, with bootstrap verification).
  - **Threshold:** the upper end of the CI, projected over 24 h of typical use (8 h active + 16 h of sleep), must stay within **1% of the nominal capacity**: 0.50 Wh over 24 h, that is about 62 mW average Δ over the 8 active hours, if sleep costs zero. The criterion applies to system power; the package Δ is reported for diagnosis.
- **Sleep:** 16 h of sleep (`pmset sleepnow`, wake with `pmset schedule wake`), for each arm. Criterion: **no DarkWake attributed to Tsukumo** in `pmset -g log`, and capacity Δ (`AppleRawCurrentCapacity`) within the fuel gauge's noise.
- **Sanity check (not decisive):** the original 24 h A/B, 3 alternating runs per arm, with `AppleRawCurrentCapacity` and `DesignCapacity` read at the start and end. It flags only gross regressions: a median Δ above 3% of `DesignCapacity` blocks the release even if the primary measurement passes, until the discrepancy is explained.
- The test is run on every release candidate, by hand, by the maintainer; the raw data ends up in `Docs/ENERGY.md`.

### 9.2 Risks and mitigations

| Risk | Probability | Mitigation |
|---|---|---|
| Apple closes the perl/MediaRemote trick | high | Multiple backends, `test` health check at startup, suspension via `compat.json`, fallback to notifications and AppleScript (fewer supported apps, but working) |
| SkyLight/CGS change (switcher, Island on the lock screen) | high | All private code behind the `Bridges/` wrappers; in `PrivateBridge.xpc` only what can live outside the app, while the calls tied to the WindowServer connection, windows or AX state stay in the app and a crash in them brings it down (table in §4.1), so `health`, per-module flags and kill‑switches matter; public SCK path as the default; per-module flags; weekly CI on the 27.x betas and, from June 2027, on the betas of the next release |
| Crash with the system ⌘⇥ disabled | medium | Multi-level crash‑safe restore (§2.2.1); default ⌥⇥, which does not touch the native switcher |
| Hinge sensor missing or HID access/capture not available on some MacBooks or macOS versions | high | Duo is enabled only on verified models; go/no-go spike before implementation and an unavailable state on other devices |
| The menu bar changes in 27 and beyond | certain | OS-specific backends, with ICE functional parity as the acceptance criterion for every supported version |
| Incomplete MenuBar management on new macOS versions | high | Per-version backend, ICE behavior as the acceptance criterion and a clear alternative when an API/permission is not available |
| Keyboard tap: requires relaunch or is blocked by Secure Input | high | Functional verification and guided relaunch (§4.3); limit declared in password fields |
| Screen Recording re‑prompts that annoy the user | certain | Thumbnails and backend B optional; Duo clearly explains the permission needed to capture the local frame |
| PAM installation that locks the user out of sudo | low | Backup, mandatory A/B tests, root watchdog with automatic rollback, restore via Authorization Services (§2.4.1) |
| PAM installation exploited for privilege escalation (TOCTOU on the user-writable bundle) | medium | Copy into a root 0700 directory, `codesign -R` verification on the copy, embedded SHA‑256 of the rollback, `# BEGIN tsukumo`/`# END tsukumo` block rewritten atomically (§2.4.1); audit before v1.0 |
| PAM module not loaded by `sudo` (arm64 versus arm64e) | medium | arm64e build of the PAM target only; first point of spike 11 |
| Third-party arm64e ABI in preview, not guaranteed stable: a macOS major can break module loading | medium | Post‑update health check at every major release (`dlopen` in the log + `sudo` test); if it fails: rebuild and reinstall the module, or clean deactivation of WatchSudo with rollback |
| URL scheme and App Intents used by a web page or another app | medium | Allowlist of actions without effects, in‑app confirmation for the rest, `tsukumo://pair` never accepted by the Mac (§4.3.1) |
| Windeck: remote command execution from a paired or compromised phone | medium | Pinned mTLS, confirmation on the Mac at first connection, revocation, per-device scopes with shell and AppleScript off by default, Mac-side validation against the saved profile (§2.6, §7.1) |
| Windeck: permission friction (Accessibility, Automation for each app) | high | Permissions requested only at the first action that uses them; the app, URL, Shortcuts and media actions work without permissions |
| Windeck: fragile APIs for now-playing state and brightness | high | Same backends, health‑check and kill‑switch as Island (§2.1); the control shows "unavailable" instead of a wrong value |
| Pairing: SE identity not usable in TLS on iOS | medium | Spike 4; fallback to a TLS key in the data protection keychain (not SE), `ThisDeviceOnly` |
| Tsukumo Home rejected in App Review | medium | App useful on its own, optional integration, review notes (§4.5); plan B HA only |
| TCC resets between builds | medium | Signing with a stable identity even in debug, Team ID and bundle id fixed by 12 November, documentation for contributors |
| Name or trademark not available | medium | Check by 12 November, alternatives ready; 15 December launch conditional (§9) |
| Notarization of the framework loaded in perl or of the PAM module | medium | Explicit signing in CI, end‑to‑end test on the notarized DMG before every release |
| Unstable CI on timing measurements | high | On PRs only deterministic checks block; tight thresholds and snapshots with glass on the Mac mini, post‑merge (§3.4, §4.2) |
| Compromised self‑hosted runner | low | Merged code only, non-admin user, sudoers limited to a wrapper, no secrets (§5.3) |
| Small or abandoned dependencies | medium | Dependency criterion (§8.2); minor repos are reference only; recheck at every release |
| Scope creep and burnout (10 modules, all in 1.0) | **high** | Feature freeze per phase; cut list for v0.1; per-module `CODEOWNERS` to delegate to contributors; a module that is not ready stays "Experimental" and off by default |
| License problems | low | REUSE + SPDX + `reuse lint` and `license-boundary` in CI; GPL‑3.0‑compatible third-party code only, never AGPL or unlicensed code (§8.3) |

The `compat.json` channel is EdDSA-signed, is downloaded together with the appcast and contains only the list `{module, osBuildRange, action: suspend|warn, message}`. It sends nothing and allows reacting within a few hours to a point release that breaks something, without publishing a new build.

---

## 10. Real limits: what Apple does not allow and what we do instead

| Limit | Chosen workaround |
|---|---|
| **AirDrop:** no API to list nearby devices, nor to show progress or a picker inside our UI | We use the system service `NSSharingService`; our animation accompanies Apple's picker and says "Choose the recipient". |
| **Unlocking the Mac from the iPhone:** no public API; the only way would be to save the login password and type it at the lock screen | **We do not do it** (§7.2): it would be a real attack surface. We point to the native alternatives, automatic unlock with the Apple Watch and Touch ID. For sudo we use the Watch through the system path (pam_watchid, §2.4.1). |
| **MediaRemote** reserved to processes with an Apple entitlement since 15.4 | We go through the entitlement of `/usr/bin/perl` (BSD adapter), with fallback and kill‑switch. It can disappear at any time, and we declare it. |
| **Carbon ⌥‑only hotkeys** blocked or intermittent since Sequoia | Switcher uses the active tap with Accessibility; the hotkey recorder rejects ⌥‑only combinations. |
| **System switcher:** no public API to replace ⌘⇥ | Private `CGSSetSymbolicHotKeyEnabled`, opt‑in only, with crash‑safe restore (§2.2.1). |
| **Screen Recording:** periodic re‑prompts and visible indicator | We say so in the permissions sheet; thumbnails and backend B optional; for Duo we verify in the spike how to capture the frame and which indicator/prompt macOS shows. |
| **TCC permissions** often active only after the process restarts | Functional verification and guided relaunch. |
| **Shared audio buffer:** the smallest IO buffer applies to all of the device's clients | Clack uses the default buffer; low latency is an opt‑in with a warning about the system-wide cost. |
| **HomeKit** not available with Developer ID | Separate Tsukumo Home app on the Mac App Store (with the risks of §4.5); Home Assistant as the main backend. |
| **Matter** outside the Store: unclear entitlements | We go through HA until we verify. |
| **Duo's sensor and local frame:** the lid-angle sensor and screen capture may depend on HID/private APIs and on TCC permissions | Spike on real models; support limited to verified devices, explicit consent and an explanation of the capture indicator. |
| **Certificates on iOS:** no public API to create a self‑signed X.509 or a `SecIdentity` | swift-certificates + swift-crypto to build the certificate, signed with the SE key; identity obtained from the keychain (§7.1). |
| **Menu bar:** Apple and Control Center items are not controllable; there is the privacy toggle introduced with Tahoe | We focus on organization and search; onboarding on the toggle; specific backends for each OS version. |
| **Spaces:** no public API | Emulated virtual workspaces (AeroSpace); no SIP and no injection into the Dock (yabai style). |
| **Fan writing** fragile on Apple Silicon | Fans read-only in v1. |
| **Lock screen:** drawing over it requires private APIs | Opt‑in SkyLight, flagged as experimental. |
| **Watch in background:** `WKExtendedRuntimeSession` limited to specific types; direct networking limited (TN3135) | No gyroscopic pointer: WatchConnectivity latency (100‑300 ms and more, with jitter) does not allow it. The Watch is a media and presentation remote and a Windeck mini‑deck, foreground only, with relay via iPhone; no abuse of workout sessions. |
| **iOS app in background:** no public way to keep an interactive connection open for long | Windeck works only in the foreground, with a "stay on" option, auto‑dim, OLED mode and dock mode (§7.3); full snapshot at every reconnection. |
| **Full-screen overlay** expensive for WindowServer and GPU | Budget and out-of-process measurements; pause with full-screen content; Island static when collapsed; status items redrawn only on value change. |
| **Bluetooth audio latency** (100‑200 ms) for Clack | We declare it and suggest the built-in or wired output; the latency target applies only to those. |
| **AV1/VP9 encode:** VideoToolbox does not offer it | LGPL ffmpeg with SVT‑AV1/libvpx in software, with a warning about consumption. |
| **Mac App Store** ruled out for the main app | Developer ID + notarization + Sparkle + Homebrew: it is the same model as Stats, Loop, AltTab and Thaw. |
| **Local network:** the permission fails silently, and without `NSBonjourServices` Bonjour does not work since macOS 15 | Manifest of §3.8 verified in CI; diagnostics screen on Mac and iOS. |

---

### Spikes to run on real hardware (with go/no‑go criterion)

Spikes 1, 2, 3 and 15 of version 1.2 concerned "Unlock with iPhone" and are **retired** with the feature (§7.2). Spike 5 (replacing the system HUDs) is retired: volume and brightness stay native. Spike 20 on Duo mirroring is retired; the new spike 7 verifies the local hinge animation. The other numbers do not change, so the references in the document remain valid.

| # | Spike | When | Criterion |
|---|---|---|---|
| 4 | **Windeck web app over HTTPS (revised on 12 Nov 2026):** local CA generated by Tsukumo, installed as a profile on iPhone/iPad and enabled in About → Certificate Trust Settings; Safari accepts it for `<name>.local`; Wake Lock and secure context work in the web app added to the Home Screen; the pairing token survives restarts and weeks of non-use | Phase C, before Windeck | Go if pairing takes < 1 minute and stays valid after 14 days; otherwise HTTP without Wake Lock |
| 6 | Keyboard active tap: permissions required (Accessibility only, or Input Monitoring too) on 26 and 27; Reminders coverage with the calendars entitlement; whether the Bluetooth permission is needed to read AirPods battery via IOBluetooth; restoring ⌘⇥ after `kill -9` and after a simulated crash | Phase 0b | `PermissionBroker` requests exactly what is needed; onboarding badges and the texts of §2.2 go from TBD to final; system ⌘⇥ comes back at the next relaunch in 10/10 tries |
| 7 | Lid-angle sensor via HID and frame capture for Duo on real MacBooks and macOS 26/27: model coverage, rate/latency, TCC permissions, capture indicator, Metal overlay and behavior on wake/close | Phase B, first step of Duo | Go if sensor and capture follow the hinge without blocking sleep/close, with acceptable permission and indicator UX; otherwise Duo is excluded from the unsupported models/OSes or from the release |
| 8 | Detection of Tahoe's "Menu Bar" toggle | Phase 0b | Reliable detection or a generic message |
| 9 | Window levels between Island, Switcher and full-screen apps in the Spaces of 26 and 27 | Phase B | No wrong overlap in the 6 test scenarios |
| 11 | ~~`pam_watchid` arm64e in `sudo`~~ | – | **Retired (1.4)** with the WatchSudo module |
| 12 | ~~App Group with a Catalyst MAS app~~ | – | **Retired (1.4)** with the Home module |
| 13 | mediaremote-adapter on final 27.x | Phase 1 | `test` green, otherwise backend 2 becomes the default |
| 14 | ~~Administrator prompt from a notarized LSUIElement app~~ | – | **Retired (1.4)** with the WatchSudo module |
| 16 | Clack key→sound latency with the device's default buffer, on built-in speakers and wired output, M1 | Phase 1 | p95 < 20 ms and no sound beyond the 30 ms deadline with the engine active; otherwise the "low latency" opt‑in is documented with its cost |
| 17 | Click‑through of the expanded Island: frame tracking the shape at every keyframe of the morph (§2.1.1), on 14" and 16" notch, 26 and 27 | Phase 0b | Click on a menu bar item adjacent to the expanded island received by the item in 20/20 tries, at rest and during the morph; no visible artifacts; WindowServer Δ within the §5.1 budget. Otherwise switch to `ignoresMouseEvents` toggled by `NSTrackingArea` |
| 18 | Windeck: tap→action latency on home Wi‑Fi (Safari on iPhone and iPad ↔ Mac), WebSocket over TLS from the web app with `TCP_NODELAY` and interactive service class; reconnection with snapshot | Phase 3, week 1 of Windeck | p95 < 30 ms per tap (acceptable fallback < 50 ms); check with and without power‑save and with keep‑alive while the deck is visible; reconnection with full state < 1 s; no Mac wakeup without a connected phone |
| 19 | MetricKit on macOS for a Developer ID app: do the daily `MXMetricPayload`s arrive, besides the `MXDiagnosticPayload`s? | Phase 0b | Informative only: the Energy panel uses `proc_pid_rusage` anyway (§3.6) |
| 21 | Per-app management of status items on macOS 27 via the native `trackedApplications` preference: reading, changing only `isAllowed`, immediate reaction of MenuBarAgent, exclusion of Apple items and fallback when the protected container is not readable | Phase 1 | Toggle in Settings updates only the selected app; system items stay clickable and unchanged; unrelated preferences preserved byte-for-byte |
| 23 | ~~Retired with `Pointer` (12 Nov 2026).~~ Pointer from Apple Watch: motion → cursor latency with (a) direct Bluetooth LE Watch → Mac and (b) relay from the iPhone via WatchConnectivity; reliability of the double-tap gesture as a click; how to keep the session alive with the wrist lowered | Phase C, before the Watch code | p95 < 50 ms with at least one of the two transports and click recognized in 19/20 tries; otherwise the limit is documented and the Watch stays "Experimental" |
| 24 | ~~Retired with `Pointer` (12 Nov 2026).~~ Pointer from AirPods held in hand: does `CMHeadphoneMotionManager` deliver data with the earbuds out of the ears, in or out of the case? | Phase C | Continuous data at ≥ 25 Hz for 60 s; otherwise the AirPods source leaves 1.0 |
| 25 | Convert: detecting ⌘ during a file drag (from the drag events' `modifierFlags` and with a `flagsChanged` monitor active only during the drag), without Accessibility or Input Monitoring; radial panel as a drag destination above Finder and full-screen apps | Phase B, first step of Convert | Picker visible within 100 ms of pressing ⌘ in 20/20 tries, drop received, no permissions; otherwise the required permission is declared |
| 26 | Passing files from the phone: phone direction from the gesture on the companion (and BLE RSSI as a proximity threshold), latency and throughput on `CompanionLink`, animation from the right edge, arrival on the Desktop | Phase C, before file passing | Go if the file arrives intact in < 2 s for a 5 MB photo on Wi‑Fi and the animation starts from the correct edge in 10/10 tries; otherwise only sending without direction is kept |
| 27 | Sound: process tap for per-app volume and output (added latency, AirPods/AirPlay, apps and devices that disappear, cost with audio stopped) | Phase B/C, before the mixer | Go if added latency < 30 ms, no glitch in 10 minutes of playback and zero CPU with audio stopped; otherwise only output switching and Music blocker are kept |

---

## Appendix A. Unverified leads (excluded from decisions)

These items emerged during research but were not verified. They drive no choice in the document and must be checked before being cited as a reference.

- **VolumeGrid, VolumeGlass, volumeHUD:** HUD replacers for Tahoe cited by aggregators. Repo URLs and licenses not verified.
- **WowMouse (Doublepoint):** Apple Watch app for gestures toward the Mac. It is proprietary; the press spoke of the companions' code being opened, but no repository was found.
- **Thock, Kbsim, Keyboard Sounds Pro:** possible keyboard sound apps; repos and licenses not verified.
- **Permute, Morph, Shutter Encoder, Adapter, FFmate:** listing information only; the internal use of AVFoundation is not confirmed.
- **Bartender:** current ownership status and behavior on 26 and 27 not rechecked.
- **Matter.framework outside the App Store:** entitlement and client profile requirements for Developer ID not clarified.
- **brc-dd/pam-watchid** (MIT, 1 star): fork not chosen as upstream. The research cited it together with a "macOS 26 + Apple Silicon" requirement that is not correct (the `LAPolicy` API for the Watch has existed since 10.15).
- **Full list of AirPods models with head tracking** (Pro, Max, third generation and later): to be verified in the `CMHeadphoneMotionManager` documentation.
- **Exact frequency of Screen Recording re‑prompts** on 26 and 27: to be measured during development.
- **`macos-27` label and Xcode 27 on GitHub‑hosted runners:** availability not verified as of 2026‑11‑09; checked on day 1 (§3.4).
- **homebrew/cask notability rules and thresholds:** reported from memory in §3.5; to be rechecked at submission time.
- **Windeck references:** license of Bitfocus Companion (to be verified file by file), stars and last activity of douinc/deck, OpenDeck, Macro Deck, StreamController and streamdeck-kit-ipad (to be recorded in the §8.2 matrix), GPL‑3.0‑only or or‑later headers of OpenDeck and StreamController.
- **`SecKey` support in swift-certificates' `Certificate.PrivateKey`:** to be confirmed on the pinned version; the fallback (signing the TBS with `SecKeyCreateSignature`) is described in §7.1.
