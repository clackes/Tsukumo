// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AudioToolbox
import CoreAudio
import Foundation

/// Core Audio listeners: device list, default output, volume and
/// mute of that output. They exist only between `start()` and `stop()`; there is no polling.
@MainActor
final class CoreAudioObserver {
  private struct Registration {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
  }

  private unowned let backend: CoreAudioBackend
  private let onChange: @MainActor (AudioChange) -> Void
  private var hardware: [Registration] = []
  private var device: [Registration] = []
  /// `IsRunningOutput` of every audio process: the process list changes
  /// only when an app opens or closes Core Audio, not when it starts or stops
  /// playing. Without these listeners the mixer would not see Music restart.
  private var processes: [AudioObjectID: Registration] = [:]

  init(backend: CoreAudioBackend, onChange: @escaping @MainActor (AudioChange) -> Void) {
    self.backend = backend
    self.onChange = onChange
  }

  func start() {
    let system = AudioObjectID(kAudioObjectSystemObject)
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
      if let item = register(system, CoreAudioProperty.address(selector), change: .devices) { hardware.append(item) }
    }
    if let item = register(
      system, CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList), change: .processes)
    {
      hardware.append(item)
    }
    watchDefaultDevice()
    watchProcesses()
  }

  func stop() {
    for item in hardware + device + Array(processes.values) { unregister(item) }
    hardware = []
    device = []
    processes = [:]
  }

  /// Aligns the `IsRunningOutput` listeners with the current process list.
  private func watchProcesses() {
    let ids = Set(
      CoreAudioProperty.array(
        of: AudioObjectID(kAudioObjectSystemObject),
        CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)) as [AudioObjectID])
    for (id, item) in processes where !ids.contains(id) {
      unregister(item)
      processes.removeValue(forKey: id)
    }
    for id in ids where processes[id] == nil {
      if let item = register(id, CoreAudioProperty.address(kAudioProcessPropertyIsRunningOutput), change: .processes) {
        processes[id] = item
      }
    }
  }

  /// Volume and mute are listened to on the default device of the moment: when it
  /// changes, the listeners move to the new one.
  private func watchDefaultDevice() {
    for item in device { unregister(item) }
    device = []
    guard let id = backend.defaultOutputID() else { return }
    let selectors = [
      kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar,
      kAudioDevicePropertyMute,
    ]
    for selector in selectors {
      for element in 0...2 {
        let address = CoreAudioProperty.address(
          selector, scope: kAudioObjectPropertyScopeOutput, element: AudioObjectPropertyElement(element))
        var probe = address
        guard AudioObjectHasProperty(id, &probe) else { continue }
        if let item = register(id, address, change: .levels) { device.append(item) }
      }
    }
  }

  private func register(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, change: AudioChange
  ) -> Registration? {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      MainActor.assumeIsolated { self?.fired(change) }
    }
    var mutable = address
    guard AudioObjectAddPropertyListenerBlock(object, &mutable, .main, block) == noErr else { return nil }
    return Registration(object: object, address: address, block: block)
  }

  private func unregister(_ item: Registration) {
    var address = item.address
    AudioObjectRemovePropertyListenerBlock(item.object, &address, .main, item.block)
  }

  private func fired(_ change: AudioChange) {
    if change == .devices { watchDefaultDevice() }
    if change == .processes { watchProcesses() }
    onChange(change)
  }
}
