// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Observation

/// Audio state shown by the popover. Exists only with the module on.
@MainActor
@Observable
final class SoundModel {
  private(set) var devices: [AudioOutputDevice] = []
  private(set) var defaultID: AudioObjectID?
  /// `nil` if the current output has no adjustable volume.
  private(set) var volume: Double?
  /// `nil` if the current output has no mute.
  private(set) var isMuted: Bool?
  /// The current mute was set by `enforceSilenceAtZero`, not by the user.
  private var mutedAtZero = false
  /// Per-app mixer (DESIGN.md §2.4.1): the apps that are playing audio
  /// right now.
  private(set) var runningAudioProcesses: [AudioProcess] = []
  /// The popover is open: only then is it necessary to re-read the list of apps that
  /// play at every play or pause (opening re-reads it anyway).
  var isPresented = false
  /// Per-app volumes read from the tap controller; updated on write
  /// so SwiftUI redraws the slider. Key = the process's `AudioObjectID`.
  private(set) var processVolumes: [AudioObjectID: Double] = [:]
  /// Per-app output, for those who changed it. `nil` = follows the system output.
  private(set) var processOutputs: [AudioObjectID: String] = [:]
  /// `true` when the system refused the last tap creation (usually
  /// means the system audio recording permission was denied).
  private(set) var mixerBlocked = false
  var includeSystemEffects = true

  @ObservationIgnored private let backend: any AudioBackend
  @ObservationIgnored private let mixer: (any ProcessVolumeController)?

  init(backend: any AudioBackend, mixer: (any ProcessVolumeController)? = nil) {
    self.backend = backend
    self.mixer = mixer
  }

  func refresh() {
    devices = backend.outputDevices()
    defaultID = backend.defaultOutputID()
    refreshLevels()
    enforceSilenceAtZero()
    refreshRunningAudioProcesses()
  }

  func handle(_ change: AudioChange) {
    switch change {
    case .devices:
      refresh()
      mixer?.devicesChanged(availableUIDs: Set(devices.map(\.uid)))
      syncMixerState()
    case .levels:
      refreshLevels()
      enforceSilenceAtZero()
    case .processes:
      mixer?.processesChanged()
      syncMixerState()
      if isPresented { refreshRunningAudioProcesses() }
    }
  }

  /// After a realignment the mixer may have removed taps or outputs: the displayed
  /// state follows the real one.
  private func syncMixerState() {
    guard let mixer, !processVolumes.isEmpty || !processOutputs.isEmpty else { return }
    for id in Array(processOutputs.keys) where mixer.outputUID(for: id) == nil {
      processOutputs.removeValue(forKey: id)
    }
    for id in Array(processVolumes.keys) where mixer.volume(for: id) >= 0.999 {
      processVolumes.removeValue(forKey: id)
    }
  }

  private func refreshRunningAudioProcesses() {
    let adjusted = Set(processVolumes.keys).union(processOutputs.keys)
    runningAudioProcesses = backend.runningAudioProcesses(keeping: adjusted)
  }

  func select(_ device: AudioOutputDevice) {
    guard device.id != defaultID else { return }
    if backend.setDefaultOutput(device.id, includingSystemEffects: includeSystemEffects) {
      defaultID = device.id
      refreshLevels()
      // The taps of apps that follow the system output are tied to the UID
      // of the old output: they are recreated on the new one keeping the chosen volume.
      // The Core Audio listener will arrive later and will find everything already aligned.
      mixer?.devicesChanged(availableUIDs: Set(devices.map(\.uid)))
      syncMixerState()
    }
  }

  /// After unlock or wake the aggregate devices may be stopped or
  /// orphaned: all are recreated, otherwise the app would stay muted at the source.
  func rebuildMixer() {
    mixer?.rebuildAll()
    syncMixerState()
    refreshRunningAudioProcesses()
  }

  /// Per-app volume to show in the slider: 1.0 = pass-through.
  func processVolume(for process: AudioProcess) -> Double {
    processVolumes[process.id] ?? mixer?.volume(for: process.id) ?? 1
  }

  /// The user moved the slider for a single app.
  func setProcessVolume(_ value: Double, for process: AudioProcess) {
    guard let mixer else { return }
    let clamped = VolumeScale.clamped(value)
    let ok = mixer.setVolume(clamped, for: process.id)
    if ok {
      mixerBlocked = false
      if clamped >= 0.999 {
        processVolumes.removeValue(forKey: process.id)
      } else {
        processVolumes[process.id] = clamped
      }
    } else {
      mixerBlocked = true
    }
  }

  /// `true` if the writable mixer is available (on macOS 14.4+).
  var mixerAvailable: Bool { mixer != nil }

  /// UID of the output chosen for this app; `nil` = use the system output.
  func processOutputUID(for process: AudioProcess) -> String? {
    processOutputs[process.id] ?? mixer?.outputUID(for: process.id)
  }

  /// Routes the app to a specific device, or to the system one if
  /// `device` is `nil`.
  func setProcessOutput(_ device: AudioOutputDevice?, for process: AudioProcess) {
    guard let mixer else { return }
    let uid = device?.uid
    let ok = mixer.setOutputUID(uid, for: process.id)
    if ok {
      mixerBlocked = false
      if let uid {
        processOutputs[process.id] = uid
      } else {
        processOutputs.removeValue(forKey: process.id)
      }
    } else {
      mixerBlocked = true
    }
  }

  func setVolume(_ value: Double) {
    guard let defaultID, volume != nil else { return }
    let clamped = VolumeScale.clamped(value)
    volume = clamped
    backend.setVolume(clamped, of: defaultID)
    // Like the Mac's keys: at zero the mute is activated, because many outputs
    // (built-in speakers included) at volume 0 still play quietly;
    // raising the volume from mute re-enables it.
    if clamped == 0, isMuted == false {
      setMuted(true)
    } else if clamped > 0, isMuted == true {
      setMuted(false)
    }
  }

  func toggleMute() {
    setMuted(!(isMuted ?? false))
  }

  /// Symbol for the menu bar item.
  var statusSymbol: String {
    isMuted == true ? "speaker.slash" : "speaker.wave.2"
  }

  private func setMuted(_ muted: Bool) {
    guard let defaultID, isMuted != nil else { return }
    isMuted = muted
    backend.setMuted(muted, of: defaultID)
  }

  /// Master volume at zero = silence for all apps, whoever
  /// brought it to zero (keys, Control Center, another app). The slider at 0
  /// does not really zero the output, so the device's mute is activated, which
  /// applies to every app; as soon as the volume rises the mute set from here is removed.
  /// A mute chosen by the user at high volume is not touched.
  private func enforceSilenceAtZero() {
    guard let volume, let isMuted else { return }
    let atZero = VolumeScale.percent(volume) == 0
    if atZero, !isMuted {
      mutedAtZero = true
      setMuted(true)
    } else if !atZero {
      if isMuted, mutedAtZero { setMuted(false) }
      mutedAtZero = false
    }
  }

  private func refreshLevels() {
    guard let defaultID else {
      volume = nil
      isMuted = nil
      return
    }
    volume = backend.volume(of: defaultID)
    isMuted = backend.isMuted(defaultID)
  }
}
