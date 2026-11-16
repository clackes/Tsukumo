// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-FileCopyrightText: 2026 fx-xf
// SPDX-License-Identifier: GPL-3.0-only
//
// Adapted from fx-xf/duo (MIT), see THIRD-PARTY-NOTICES.md.

import AppKit
import ModuleKit
import OSLog
import QuartzCore

/// Duo preferences, saved as JSON in the module's store.
struct DuoPrefs: Codable, Equatable, Sendable {
  /// Fold scale: the degrees of closing that bring progress to 100%.
  /// The fold is always dynamic (it starts from where the lid came to rest).
  var startAngle: Double = 80
  /// The fold starts only if the lid drops below this angle: above it,
  /// moving the screen does nothing. 140° = always.
  var activationAngle: Double = 140
  /// Degrees of closing ignored before the fold begins: they absorb
  /// jolts of the hand on the lid.
  var deadZone: Double = 8
  var perspective: Double = 1
  var blur: Double = 0.65
  var shadow: Double = 0.35
  /// How much the desktop follows the fold: 0 still on the screen, 1 anchored in space.
  var motion: Double = 0

  static let activationRange: ClosedRange<Double> = 40...140
  static let startAngleRange: ClosedRange<Double> = 20...120
  static let deadZoneRange: ClosedRange<Double> = 0...25

  init() {}

  /// Preferences saved before a new key stay valid: each
  /// missing field takes its default value.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = DuoPrefs()
    startAngle = try container.decodeIfPresent(Double.self, forKey: .startAngle) ?? defaults.startAngle
    activationAngle = try container.decodeIfPresent(Double.self, forKey: .activationAngle) ?? defaults.activationAngle
    deadZone = try container.decodeIfPresent(Double.self, forKey: .deadZone) ?? defaults.deadZone
    perspective = try container.decodeIfPresent(Double.self, forKey: .perspective) ?? defaults.perspective
    blur = try container.decodeIfPresent(Double.self, forKey: .blur) ?? defaults.blur
    shadow = try container.decodeIfPresent(Double.self, forKey: .shadow) ?? defaults.shadow
    motion = try container.decodeIfPresent(Double.self, forKey: .motion) ?? defaults.motion
  }
}

/// Sensor → model → overlay. At rest there is only one sensor read every
/// 100 ms (exception documented in DESIGN.md §5.1: the kernel event arrives at
/// ~1 Hz), stopped when the display is off; no capture. When the hinge moves
/// a *session* starts (a frozen frame + 60 Hz timer) that ends by itself
/// when the lid is still, with fuses that remove the overlay regardless.
@MainActor
final class BendEngine {
  var prefs = DuoPrefs()
  /// Every rest-time read (5-10 Hz, the same as the quiet check): it is used
  /// by Settings to show the current angle. No extra reads.
  var onAngle: ((Double) -> Void)?

  private let resources: ResourceBag
  private let sensor: LidAngleSensor
  private var overlay: OverlayController?
  private var overlayKey: String?
  private var snapshot: ScreenSnapshot?
  private var model: LidModel
  private var timer: ResourceBag.Token?

  private var restAngle: Double
  private var foldSince: Double?
  private var lastMotion = CACurrentMediaTime()
  private var sessionStart = CACurrentMediaTime()
  private var lastReading: Double
  private var lastTick = CACurrentMediaTime()
  private var quietFor: Double = 0
  private var bendActive = false
  private var displayAsleep = false
  private var previewStart: CFTimeInterval?
  private var tokens: [ResourceBag.Token] = []
  private let log = Logger(subsystem: "dev.local.tsukumo", category: "duo")
  private var stats = FrameStats()
  private var idleWatch: ResourceBag.Token?
  private var idleWatchInterval = Duration.zero
  private var idleAngle = 0.0
  private var idleStillSince = 0.0
  private var predictor = AnglePredictor()

  /// Radius of action of the starting angle for isolated hits: a lid
  /// open at 100-130° that jolts must not start a session.
  private static let armDegrees = 4.0
  /// The animation appears only if the closing lasts: from 0.2 s to 0.4 s from the start
  /// it fades in. Short flicks (down and up) never get to show.
  private static let intentDelay = 0.2
  private static let intentFade = 0.2
  /// Fuses: the overlay must never remain if the lid is still or the session lasts too long.
  private static let stillLimit = 1.5
  private static let sessionLimit = 30.0
  private static let quietLimit = 1.5
  private static let frameInterval = Duration.milliseconds(16)
  /// Quiet check at 10 Hz (the sensor step): the sensor notifies by itself only at ~1 Hz, too
  /// late to start in time (DESIGN.md §2.4, documented exception). A read
  /// costs ~0.5 ms; it stops when the display is off.
  private static let idleInterval = Duration.milliseconds(100)
  /// Lid still for `restfulAfter`: half the reads. A movement of
  /// at least 1° immediately goes back to 10 Hz; closing always starts from rest, so
  /// at worst it shows 100 ms later, within `intentDelay`.
  private static let restfulInterval = Duration.milliseconds(200)
  private static let restfulAfter = 5.0

  var isSessionActive: Bool { timer != nil }

  init?(resources: ResourceBag) {
    guard let sensor = LidAngleSensor() else { return nil }
    self.resources = resources
    self.sensor = sensor
    let angle = sensor.read() ?? 130
    restAngle = angle
    lastReading = angle
    model = LidModel(angle: angle)
    rebuildOverlay()
    // Without a built-in display (clamshell) it starts anyway and waits for it to
    // come back; with the display but without an overlay (no Metal) it does not.
    guard overlay != nil || NSScreen.builtIn == nil else {
      sensor.invalidate()
      return nil
    }

    sensor.observe { [weak self] angle in self?.sensorReported(angle) }
    let center = NSWorkspace.shared.notificationCenter
    tokens.append(
      resources.addObserver(NSApplication.didChangeScreenParametersNotification) { [weak self] in
        self?.rebuildOverlay()
      })
    tokens.append(
      resources.addObserver(NSWorkspace.screensDidSleepNotification, center: center) { [weak self] in
        self?.displayAsleep = true
        self?.stopIdleWatch()
        self?.endSession()
      })
    tokens.append(
      resources.addObserver(NSWorkspace.screensDidWakeNotification, center: center) { [weak self] in
        self?.displayAsleep = false
        self?.startIdleWatch()
      })
    startIdleWatch()
  }

  private func startIdleWatch(every interval: Duration = idleInterval) {
    guard idleWatch == nil, overlay != nil else { return }
    idleWatchInterval = interval
    idleStillSince = CACurrentMediaTime()
    idleWatch = resources.addTimer(every: interval, tolerance: interval * 0.15) { [weak self] in
      guard let self, !self.isSessionActive, let angle = self.sensor.read() else { return }
      self.adaptIdleRate(to: angle)
      self.sensorReported(angle)
    }
  }

  private func adaptIdleRate(to angle: Double) {
    let now = CACurrentMediaTime()
    if abs(angle - idleAngle) >= 1 {
      idleAngle = angle
      idleStillSince = now
      if idleWatchInterval != Self.idleInterval { restartIdleWatch(every: Self.idleInterval) }
    } else if idleWatchInterval == Self.idleInterval, now - idleStillSince >= Self.restfulAfter {
      restartIdleWatch(every: Self.restfulInterval)
    }
  }

  private func restartIdleWatch(every interval: Duration) {
    let still = idleStillSince
    stopIdleWatch()
    startIdleWatch(every: interval)
    idleStillSince = still
  }

  private func stopIdleWatch() {
    if let idleWatch { resources.cancel(idleWatch) }
    idleWatch = nil
  }

  func shutdown() {
    stopIdleWatch()
    endSession()
    sensor.invalidate()
    for token in tokens { resources.cancel(token) }
    tokens = []
    overlay?.close()
    overlay = nil
  }

  /// Plays the fold with a simulated angle, without touching the lid.
  func preview() {
    previewStart = CACurrentMediaTime()
    beginSession(from: 110)
  }

  // MARK: Session

  /// Starts when the angle moves at least 3° away from the rest angle, which
  /// slowly follows the angle: a jolt returns, a slow movement adds up.
  private func sensorReported(_ angle: Double) {
    onAngle?(angle)
    guard !isSessionActive, !displayAsleep else { return }
    // Only closing folds the screen: opening the lid does not start
    // sessions or needless captures.
    if restAngle - angle >= Self.armDegrees, angle <= prefs.activationAngle {
      beginSession(from: restAngle)
    } else if angle - restAngle >= Self.armDegrees {
      // Lid opened further: the new rest is that straight away.
      restAngle = angle
    } else {
      restAngle += (angle - restAngle) * 0.02
    }
  }

  private func beginSession(from angle: Double) {
    guard timer == nil, overlay != nil else { return }
    model = LidModel(angle: sensor.read() ?? angle)
    predictor = AnglePredictor()
    lastReading = model.springAngle
    lastTick = CACurrentMediaTime()
    quietFor = 0
    lastMotion = lastTick
    sessionStart = lastTick
    takeSnapshot()
    timer = resources.addTimer(every: Self.frameInterval) { [weak self] in self?.tick() }
  }

  private func endSession() {
    if stats.frames > 0 { log.notice("\(self.stats.summary, privacy: .public)") }
    stats = FrameStats()
    if let timer { resources.cancel(timer) }
    timer = nil
    snapshot?.cancel()
    overlay?.forceHide()
    overlay?.renderer.releaseFrame()
    bendActive = false
    previewStart = nil
    restAngle = lastReading
  }

  private func takeSnapshot() {
    guard let overlay else { return }
    if snapshot == nil {
      let renderer = overlay.renderer
      snapshot = ScreenSnapshot { renderer.submit(frame: $0) }
    }
    snapshot?.capture(displayID: overlay.displayID, pixelSize: overlay.pixelSize, hiding: [overlay.windowID])
  }

  /// A new overlay only if the built-in panel really changed: screen
  /// parameter events also arrive on sleep and wake.
  private func rebuildOverlay() {
    let screen = NSScreen.builtIn
    let key = screen.map { "\($0.displayID) \($0.frame) \($0.backingScaleFactor)" }
    guard key != overlayKey || overlay == nil else { return }
    overlayKey = key
    let wasActive = isSessionActive
    endSession()
    snapshot = nil
    overlay?.close()
    overlay = screen.flatMap(OverlayController.init(screen:))
    if wasActive { beginSession(from: lastReading) }
    // The quiet check is only needed if there is somewhere to draw.
    if overlay == nil {
      stopIdleWatch()
    } else if !displayAsleep {
      startIdleWatch()
    }
  }

  private func previewAngle(at elapsed: Double) -> Double {
    // 110° → 0° in 1.2 s, still 0.3 s, up again in 1.0 s.
    func ease(_ phase: Double) -> Double { phase * phase * (3 - 2 * phase) }
    switch elapsed {
    case ..<1.2: return 110 * (1 - ease(elapsed / 1.2))
    case ..<1.5: return 0
    case ..<2.5: return 110 * ease((elapsed - 1.5) / 1.0)
    default: return 110
    }
  }

  private func tick() {
    guard let overlay else { return }
    let now = CACurrentMediaTime()
    let dt = min(now - lastTick, 0.05)
    lastTick = now

    let target: Double
    if let start = previewStart {
      target = previewAngle(at: now - start)
    } else {
      target = predictor.predict(raw: sensor.read(), at: now) ?? lastReading
    }
    let lidMoving = abs(target - lastReading) > 0.25
    lastReading = target

    // Always dynamic: the fold dissolves by itself as soon as the lid stops.
    model.startAngle = prefs.startAngle
    model.deadZone = prefs.deadZone
    model.dynamic = true
    if lidMoving || previewStart != nil { lastMotion = now }
    // `step` writes `model.tilt`; the return value matches `model.tilt`
    // and is read further down, so we do not need it here.
    model.step(target: target, dt: dt)

    // Intent: the fold counts only after the lid has kept
    // closing for a while; a short flick returns first and is not seen.
    if model.tilt > 0 { foldSince = foldSince ?? now } else { foldSince = nil }
    let gate = foldSince.map { smoothStep((now - $0 - Self.intentDelay) / Self.intentFade) } ?? 0
    let shownTilt = model.tilt * gate

    // A bit of hysteresis: sensor jitter at the threshold must not cause flicker.
    let active = shownTilt / max(prefs.startAngle, 1) > (bendActive ? 0.0005 : 0.002)
    if active != bendActive {
      bendActive = active
      if !active {
        overlay.hide()
        takeSnapshot()
      }
    }
    if active, !displayAsleep {
      let renderStart = CACurrentMediaTime()
      defer { stats.record(interval: dt, render: CACurrentMediaTime() - renderStart) }
      overlay.render(
        BendParams(
          tilt: shownTilt * .pi / 180, perspective: prefs.perspective, blur: prefs.blur, shadow: prefs.shadow,
          motion: prefs.motion))
    }

    if now - lastMotion > Self.stillLimit || now - sessionStart > Self.sessionLimit {
      log.error("fuse: overlay removed (idle or session too long)")
      endSession()
      return
    }

    let previewing = previewStart.map { now - $0 < 2.8 } ?? false
    if !previewing { previewStart = nil }
    let busy = lidMoving || abs(model.springVelocity) > 0.5 || model.tilt > 0 || previewing
    quietFor = busy ? 0 : quietFor + dt
    if quietFor > Self.quietLimit { endSession() }
  }
}

/// Timings of a session, for local diagnostics: interval between ticks and draw duration.
struct FrameStats {
  private(set) var frames = 0
  private var intervalSum = 0.0
  private var intervalMax = 0.0
  private var renderSum = 0.0
  private var renderMax = 0.0

  mutating func record(interval: Double, render: Double) {
    frames += 1
    intervalSum += interval
    intervalMax = max(intervalMax, interval)
    renderSum += render
    renderMax = max(renderMax, render)
  }

  var summary: String {
    guard frames > 0 else { return "no frames" }
    let count = Double(frames)
    return String(
      format: "session: %d frames, mean interval %.1f ms (max %.1f), mean draw %.1f ms (max %.1f)",
      frames, intervalSum / count * 1000, intervalMax * 1000, renderSum / count * 1000, renderMax * 1000)
  }
}

/// The sensor changes every ~100 ms and in whole degrees: between one sample and the next
/// we extrapolate with the velocity of the last step, so the screen does not follow
/// the lid in steps.
struct AnglePredictor {
  private var last: (angle: Double, time: Double)?
  private var previous: (angle: Double, time: Double)?
  private var velocity = 0.0

  /// Maximum lead: beyond it, the estimate is just noise.
  private static let horizon = 0.12
  private static let maxVelocity = 400.0

  mutating func predict(raw: Double?, at now: Double) -> Double? {
    guard let raw else { return nil }
    if let current = last {
      if raw != current.angle {
        previous = current
        last = (raw, now)
        let span = now - (previous?.time ?? now)
        let step = span > 0.02 && span < 0.4 ? (raw - current.angle) / span : 0
        // A ±1° jitter changes direction constantly: only a coherent push is extrapolated.
        velocity = step * velocity > 0 || abs(step) >= 30 ? step : step * 0.25
        velocity = min(max(velocity, -Self.maxVelocity), Self.maxVelocity)
      } else if now - current.time > 0.4 {
        velocity = 0
      }
    } else {
      last = (raw, now)
    }
    guard let current = last else { return raw }
    // If the new sample is late, the lid has probably stopped: the
    // push fades out in 80 ms instead of overshooting and then coming back.
    let age = now - current.time
    let fade = max(0, min(1, 1 - (age - 0.12) / 0.08))
    return current.angle + velocity * fade * min(age + 0.03, Self.horizon)
  }
}

private func smoothStep(_ value: Double) -> Double {
  let clamped = min(max(value, 0), 1)
  return clamped * clamped * (3 - 2 * clamped)
}
