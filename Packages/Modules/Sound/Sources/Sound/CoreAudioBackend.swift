// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AudioToolbox
import CoreAudio
import Foundation

/// The real `AudioBackend`, on top of Core Audio. Stateless: every call reads the
/// system, and listeners exist only inside `observe(_:)`.
@MainActor
final class CoreAudioBackend: AudioBackend {
  private var observer: CoreAudioObserver?

  func outputDevices() -> [AudioOutputDevice] {
    let ids: [AudioObjectID] = CoreAudioProperty.array(
      of: AudioObjectID(kAudioObjectSystemObject), CoreAudioProperty.address(kAudioHardwarePropertyDevices))
    return ids.compactMap(makeDevice).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func defaultOutputID() -> AudioObjectID? {
    CoreAudioProperty.read(
      AudioObjectID(kAudioObjectSystemObject), CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice),
      initial: AudioObjectID(kAudioObjectUnknown)
    ).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
  }

  func setDefaultOutput(_ id: AudioObjectID, includingSystemEffects: Bool) -> Bool {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var done = CoreAudioProperty.write(
      system, CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice), value: id)
    if includingSystemEffects {
      done =
        CoreAudioProperty.write(
          system, CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice), value: id) && done
    }
    return done
  }

  func volume(of id: AudioObjectID) -> Double? {
    let addresses = CoreAudioProperty.controls(of: id, selectors: Self.volumeSelectors)
    let values = addresses.compactMap { CoreAudioProperty.read(id, $0, initial: Float32(0)) }
    guard !values.isEmpty else { return nil }
    return VolumeScale.clamped(Double(values.reduce(0, +)) / Double(values.count))
  }

  func setVolume(_ value: Double, of id: AudioObjectID) {
    for address in CoreAudioProperty.controls(of: id, selectors: Self.volumeSelectors) {
      _ = CoreAudioProperty.write(id, address, value: VolumeScale.scalar(value))
    }
  }

  func isMuted(_ id: AudioObjectID) -> Bool? {
    let addresses = CoreAudioProperty.controls(of: id, selectors: [kAudioDevicePropertyMute])
    return addresses.compactMap { CoreAudioProperty.read(id, $0, initial: UInt32(0)) }.first.map { $0 != 0 }
  }

  func setMuted(_ muted: Bool, of id: AudioObjectID) {
    for address in CoreAudioProperty.controls(of: id, selectors: [kAudioDevicePropertyMute]) {
      _ = CoreAudioProperty.write(id, address, value: UInt32(muted ? 1 : 0))
    }
  }

  func observe(_ onChange: @escaping @MainActor (AudioChange) -> Void) -> @MainActor () -> Void {
    let observer = CoreAudioObserver(backend: self, onChange: onChange)
    self.observer = observer
    observer.start()
    return { [weak self] in
      observer.stop()
      self?.observer = nil
    }
  }

  func runningAudioProcesses(keeping: Set<AudioObjectID>) -> [AudioProcess] {
    CoreAudioProcessList.current(keeping: keeping)
  }

  /// String UID of a device, used as the identifier in the dictionaries of
  /// `AudioHardwareCreateAggregateDevice`.
  func outputUID(of id: AudioObjectID) -> String? {
    CoreAudioProperty.string(of: id, CoreAudioProperty.address(kAudioDevicePropertyDeviceUID))
  }

  /// First the system's virtual volume, then the master's, then channels 1 and 2.
  private static let volumeSelectors: [AudioObjectPropertySelector] = [
    kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar,
  ]

  /// Aggregate devices created by Core Audio for a process's internal use.
  nonisolated static func isInternalAggregate(uid: String) -> Bool {
    uid.hasPrefix("CADefaultDeviceAggregate")
  }

  private func makeDevice(_ id: AudioObjectID) -> AudioOutputDevice? {
    let hidden = CoreAudioProperty.read(id, CoreAudioProperty.address(kAudioDevicePropertyIsHidden), initial: UInt32(0))
    guard hidden != 1 else { return nil }
    let streams = CoreAudioProperty.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    guard CoreAudioProperty.dataSize(of: id, streams) > 0 else { return nil }
    guard
      let uid = CoreAudioProperty.string(of: id, CoreAudioProperty.address(kAudioDevicePropertyDeviceUID))
    else { return nil }
    // The per-app mixer's aggregate devices are internal stuff: they must not
    // appear among the selectable outputs (DESIGN §2.4.1, feedback 13 Nov).
    if #available(macOS 14.4, *), uid.hasPrefix(ProcessTap.aggregateUIDPrefix) { return nil }
    // Core Audio creates `CADefaultDeviceAggregate-<pid>-<n>` inside our own
    // process (audio engines of Clack and of the taps): it is visible only to us and
    // choosing it as the system output sends the audio into the void.
    if Self.isInternalAggregate(uid: uid) { return nil }
    let name = CoreAudioProperty.string(of: id, CoreAudioProperty.address(kAudioObjectPropertyName)) ?? uid
    let transport =
      CoreAudioProperty.read(
        id, CoreAudioProperty.address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
    return AudioOutputDevice(id: id, uid: uid, name: name, kind: AudioDeviceKind(transportType: transport))
  }
}
