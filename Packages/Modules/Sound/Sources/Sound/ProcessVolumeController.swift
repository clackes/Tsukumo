// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Foundation
import OSLog

/// Per-app mixer and routing: every app with a volume other than 100% or
/// an output other than the default has its own `ProcessTap` connected
/// to the chosen device. Apps with a neutral mix have no Core Audio
/// resource (DESIGN.md §2.4.1, §4.2). The controller sits on top of Core Audio and
/// does **not** enter the `AudioBackend` protocol: this way the rest of the module can
/// run even without the audio-capture permission.
@MainActor
protocol ProcessVolumeController: AnyObject {
  /// Per-app volume, 1.0 = pass-through.
  func volume(for processID: AudioObjectID) -> Double
  /// UID of the output chosen for this app, `nil` = follows the system output.
  func outputUID(for processID: AudioObjectID) -> String?
  /// Sets the volume. Returns `false` if Core Audio refused.
  @discardableResult
  func setVolume(_ value: Double, for processID: AudioObjectID) -> Bool
  /// Routes the app to a specific output. `nil` = back to the system
  /// output. Returns `false` if the tap creation was refused.
  @discardableResult
  func setOutputUID(_ uid: String?, for processID: AudioObjectID) -> Bool
  /// Frees all the taps. Called when the module turns off.
  func tearDown()
  /// The device list or the system output has changed: taps tied to
  /// an old or vanished output must be realigned.
  func devicesChanged(availableUIDs: Set<String>)
  /// The audio process list has changed: drop the taps of the apps that quit.
  func processesChanged()
  /// Recreates all the taps with the current settings (after unlock or wake).
  func rebuildAll()
}

extension ProcessVolumeController {
  func devicesChanged(availableUIDs: Set<String>) {}
  func processesChanged() {}
  func rebuildAll() {}
}

/// What to do with an existing tap after a device change.
enum TapRealignment: Equatable {
  case keep
  /// Recreates the tap on `uid`; `dropOutput` = the output chosen for the app no longer exists.
  case rebuild(uid: String, dropOutput: Bool)
  case remove

  static func decide(
    outputUID: String?, volume: Double, tapUID: String, defaultUID: String?, available: Set<String>
  ) -> TapRealignment {
    var explicit = outputUID
    var dropped = false
    if let chosen = explicit, !available.contains(chosen) {
      explicit = nil
      dropped = true
    }
    // Without its own output and at full volume no tap is needed anymore.
    if explicit == nil, volume >= 0.999 { return .remove }
    guard let target = explicit ?? defaultUID else { return .remove }
    return target == tapUID && !dropped ? .keep : .rebuild(uid: target, dropOutput: dropped)
  }
}

/// Per-app settings, all optional: the pair `(nil, 1.0)` = no tap.
private struct ProcessSettings: Equatable {
  var volume: Double = 1.0
  var outputUID: String?

  var isNeutral: Bool { volume >= 0.999 && outputUID == nil }
}

/// Real implementation on Core Audio. The state lives in here: the
/// module's `ResourceBag` cancels the controller in `stop()` and that
/// is enough to tear everything down through the deinits.
@available(macOS 14.4, *)
@MainActor
final class CoreAudioProcessVolume: ProcessVolumeController {
  private let log = Logger(subsystem: "dev.local.tsukumo", category: "sound.mixer")
  /// Key: the process object's `AudioObjectID`, not the PID: stable between two
  /// reads of the Core Audio list.
  private var taps: [AudioObjectID: ProcessTap] = [:]
  private var settings: [AudioObjectID: ProcessSettings] = [:]
  /// Last attempt to recreate an app's tap: two close failures
  /// mean it does not work, and then the app goes back to playing on its own.
  private var lastRecovery: [AudioObjectID: ContinuousClock.Instant] = [:]
  private static let recoveryWindow = Duration.seconds(30)
  /// Several wakes and unlocks arrive together: a single rebuild.
  private var rebuildScheduled = false
  /// How to find the UID of the default output device on the fly. We
  /// pass it as a closure so the controller does not depend on the backend.
  private let currentOutputUID: @MainActor () -> String?

  init(currentOutputUID: @escaping @MainActor () -> String?) {
    self.currentOutputUID = currentOutputUID
  }

  func volume(for processID: AudioObjectID) -> Double {
    settings[processID]?.volume ?? 1
  }

  func outputUID(for processID: AudioObjectID) -> String? {
    settings[processID]?.outputUID
  }

  @discardableResult
  func setVolume(_ value: Double, for processID: AudioObjectID) -> Bool {
    var state = settings[processID] ?? ProcessSettings()
    state.volume = VolumeScale.clamped(value)
    return apply(state, for: processID)
  }

  @discardableResult
  func setOutputUID(_ uid: String?, for processID: AudioObjectID) -> Bool {
    var state = settings[processID] ?? ProcessSettings()
    state.outputUID = uid
    return apply(state, for: processID)
  }

  func tearDown() {
    taps.removeAll()
    settings.removeAll()
  }

  func devicesChanged(availableUIDs: Set<String>) {
    let defaultUID = currentOutputUID()
    for (processID, state) in settings {
      guard let tap = taps[processID] else { continue }
      let decision = TapRealignment.decide(
        outputUID: state.outputUID, volume: state.volume, tapUID: tap.outputDeviceUID,
        defaultUID: defaultUID, available: availableUIDs)
      switch decision {
      case .keep:
        continue
      case .remove:
        // The tap mutes the app: without a valid output it would stay silent.
        taps.removeValue(forKey: processID)
        settings.removeValue(forKey: processID)
      case .rebuild(_, let dropOutput):
        var next = state
        if dropOutput { next.outputUID = nil }
        if !apply(next, for: processID) {
          taps.removeValue(forKey: processID)
          settings.removeValue(forKey: processID)
        }
      }
    }
  }

  func processesChanged() {
    guard !taps.isEmpty || !settings.isEmpty else { return }
    let alive = Set(
      CoreAudioProperty.array(
        of: AudioObjectID(kAudioObjectSystemObject),
        CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)) as [AudioObjectID])
    for processID in Set(taps.keys).union(settings.keys) where !alive.contains(processID) {
      taps.removeValue(forKey: processID)
      settings.removeValue(forKey: processID)
    }
  }

  func rebuildAll() {
    guard !settings.isEmpty, !rebuildScheduled else { return }
    rebuildScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.rebuildScheduled = false
        self.rebuildNow()
      }
    }
  }

  private func rebuildNow() {
    for (processID, state) in settings {
      taps.removeValue(forKey: processID)
      if !apply(state, for: processID) {
        // Better the app at full volume than muted forever.
        settings.removeValue(forKey: processID)
      }
    }
  }

  /// The tap's IO did not restart: recreate it once; if it fails again the
  /// tap goes away and the app goes back to playing on its own, without staying muted.
  private func recover(_ processID: AudioObjectID) {
    guard let state = settings[processID] else { return }
    let now = ContinuousClock.now
    taps.removeValue(forKey: processID)
    if let last = lastRecovery[processID], now - last < Self.recoveryWindow {
      // Second failure within a few seconds: drop the tap, the app plays again.
      log.error("App \(processID, privacy: .public) tap stalled again: removing it")
      settings.removeValue(forKey: processID)
      lastRecovery.removeValue(forKey: processID)
      return
    }
    log.error("App \(processID, privacy: .public) tap stalled: recreating it")
    lastRecovery[processID] = now
    if !apply(state, for: processID) {
      settings.removeValue(forKey: processID)
    }
  }

  // MARK: - Applying the settings

  /// Aligns tap + aggregate to the latest state for this app:
  /// - neutral state → tap destroyed;
  /// - only volume changed → scale factor updated on the existing tap;
  /// - output changed or tap missing → tap rebuilt with the new UID.
  private func apply(_ state: ProcessSettings, for processID: AudioObjectID) -> Bool {
    if state.isNeutral {
      taps.removeValue(forKey: processID)
      settings.removeValue(forKey: processID)
      return true
    }
    let targetUID = state.outputUID ?? currentOutputUID()
    guard let targetUID else {
      log.error("No output for app \(processID, privacy: .public): tap not created")
      return false
    }
    if let existing = taps[processID], existing.outputDeviceUID == targetUID {
      existing.setScale(state.volume)
      settings[processID] = state
      return true
    }
    // Output changed or tap missing: destroy the old one before
    // creating the new one, otherwise there would be two active IOProcs on the
    // same app for a moment.
    taps.removeValue(forKey: processID)
    guard
      let tap = ProcessTap(
        processObjectID: processID, outputDeviceUID: targetUID, initialScale: state.volume)
    else { return false }
    let identity = ObjectIdentifier(tap)
    tap.onFailure = { [weak self] in
      // A late notice from an already replaced tap does not touch the new one.
      guard let self, let current = self.taps[processID], ObjectIdentifier(current) == identity else { return }
      self.recover(processID)
    }
    taps[processID] = tap
    settings[processID] = state
    return true
  }
}
