// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AudioToolbox
import CoreAudio
import Foundation

/// Audio output selectable from the lock screen player.
struct LockAudioOutput: Identifiable, Equatable, Sendable {
  let id: AudioObjectID
  let name: String
  let symbol: String
}

/// Reading and choosing the system audio output for the lock screen.
/// Read only when the user opens the list: no listener, no timer.
enum LockAudioOutputs {
  static func list() -> [LockAudioOutput] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = Self.address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap(makeOutput).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  static func defaultID() -> AudioObjectID? {
    let value: AudioObjectID? = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    return value == kAudioObjectUnknown ? nil : value
  }

  /// Changes the system output, sound effects included.
  @discardableResult
  static func select(_ id: AudioObjectID) -> Bool {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var ok = true
    for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
      var address = Self.address(selector)
      var value = id
      ok =
        AudioObjectSetPropertyData(
          system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr && ok
    }
    return ok
  }

  /// Volume of the system output, from 0 to 1; `nil` if the device does not have
  /// an adjustable volume (some digital outputs).
  static func volume() -> Float? {
    guard let device = defaultID() else { return nil }
    var address = volumeAddress
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
  }

  static func setVolume(_ value: Float) {
    guard let device = defaultID() else { return }
    var address = volumeAddress
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
    var level = Float32(min(max(value, 0), 1))
    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
    // At volume 0 many outputs still play quietly: like the Mac's keys,
    // zero turns on the mute and any other value removes it.
    var mute = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
    var canMute: DarwinBoolean = false
    guard AudioObjectHasProperty(device, &mute),
      AudioObjectIsPropertySettable(device, &mute, &canMute) == noErr, canMute.boolValue
    else { return }
    var muted: UInt32 = level == 0 ? 1 : 0
    AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
  }

  private static var volumeAddress: AudioObjectPropertyAddress {
    address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
  }

  /// Name and symbol of the current output, for the player's button.
  static func current() -> LockAudioOutput? {
    guard let id = defaultID() else { return nil }
    return makeOutput(id)
  }

  /// Internal aggregates (Sound's mixer, `CADefaultDeviceAggregate`) are not
  /// real outputs: choosing them would send the audio into nothing.
  static func isSelectable(uid: String) -> Bool {
    !uid.hasPrefix("CADefaultDeviceAggregate") && !uid.hasPrefix("dev.local.tsukumo.")
  }

  private static func makeOutput(_ id: AudioObjectID) -> LockAudioOutput? {
    let hidden: UInt32? = read(id, kAudioDevicePropertyIsHidden)
    guard hidden != 1 else { return nil }
    var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }
    guard let uid = string(id, kAudioDevicePropertyDeviceUID), isSelectable(uid: uid) else { return nil }
    let name = string(id, kAudioObjectPropertyName) ?? uid
    let transport: UInt32 = read(id, kAudioDevicePropertyTransportType) ?? 0
    return LockAudioOutput(id: id, name: name, symbol: symbol(for: transport))
  }

  private static func symbol(for transport: UInt32) -> String {
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
    case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
    default: "hifispeaker"
    }
  }

  private static func address(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T?
  where T: FixedWidthInteger {
    var address = address(selector)
    var value: T = 0
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
  }

  private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }
}
