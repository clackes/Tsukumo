// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AudioToolbox
import CoreAudio
import PrivateBridges
import Synchronization

/// What the island's HUD shows.
enum HUDKind: Sendable, Equatable {
  case volume, brightness
}

/// Media key read from a system event (`NX_SYSDEFINED`, subtype 8).
enum MediaKey: Int, Sendable {
  case soundUp = 0
  case soundDown = 1
  case brightnessUp = 2
  case brightnessDown = 3
  case mute = 7

  var kind: HUDKind { self == .brightnessUp || self == .brightnessDown ? .brightness : .volume }
}

struct MediaKeyPress: Sendable, Equatable {
  let key: MediaKey
  let isDown: Bool
  /// ⌥⇧: quarter steps, like the system.
  let fine: Bool
  /// ⌥ alone opens System Settings: that key is left to the system.
  let opensSettings: Bool

  /// Interprets `data1` and the modifiers of a `systemDefined` event with subtype 8.
  static func parse(subtype: Int, data1: Int, modifiers: NSEvent.ModifierFlags) -> MediaKeyPress? {
    guard subtype == 8, let key = MediaKey(rawValue: (data1 & 0xFFFF_0000) >> 16) else { return nil }
    let state = (data1 & 0xFF00) >> 8
    let option = modifiers.contains(.option)
    let shift = modifiers.contains(.shift)
    return MediaKeyPress(key: key, isDown: state == 0xA, fine: option && shift, opensSettings: option && !shift)
  }
}

enum HUDMath {
  static let steps: Float = 16
  static let fineSteps: Float = 64

  /// Next level on a grid of 16 (or 64) steps, always within [0, 1].
  static func stepped(_ level: Float, up: Bool, fine: Bool) -> Float {
    let count = fine ? fineSteps : steps
    let current = (min(max(level, 0), 1) * count).rounded()
    return min(max(current + (up ? 1 : -1), 0), count) / count
  }

  /// Steps of the brightness ramp (about 150 ms in total).
  static let rampSteps = 12

  /// Intermediate value of the ramp, with a soft exit toward the target.
  static func ramp(from start: Float, to target: Float, step: Int) -> Float {
    let progress = min(max(Float(step) / Float(rampSteps), 0), 1)
    let eased = 1 - (1 - progress) * (1 - progress)
    return start + (target - start) * eased
  }

  static func symbol(for kind: HUDKind, level: Float, muted: Bool) -> String {
    switch kind {
    case .brightness: return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
    case .volume:
      if muted || level <= 0 { return "speaker.slash.fill" }
      if level < 0.34 { return "speaker.wave.1.fill" }
      return level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
  }
}

/// Which keys the island handles in place of the system. Read from the tap thread.
final class HUDPolicy: Sendable {
  struct State: Sendable {
    var volume = false
    var brightness = false
  }

  private let state = Mutex(State())

  func set(_ new: State) { state.withLock { $0 = new } }

  /// `true` if the key must be consumed: we handle it ourselves and the system HUD does not appear.
  func handles(_ press: MediaKeyPress) -> Bool {
    guard !press.opensSettings else { return false }
    let current = state.withLock { $0 }
    return press.key.kind == .volume ? current.volume : current.brightness
  }
}

/// Volume of the default output device, via CoreAudio (public API).
enum AudioVolume {
  private static func address(_ selector: AudioObjectPropertySelector, output: Bool = true)
    -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  static func defaultDevice() -> AudioObjectID? {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var property = address(kAudioHardwarePropertyDefaultOutputDevice, output: false)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
  }

  /// `false` for outputs without adjustable volume (for example HDMI): there the keys stay with the system.
  static func canSetVolume(_ device: AudioObjectID) -> Bool {
    var property = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    var settable: DarwinBoolean = false
    guard AudioObjectHasProperty(device, &property),
      AudioObjectIsPropertySettable(device, &property, &settable) == noErr
    else { return false }
    return settable.boolValue
  }

  static func volume(_ device: AudioObjectID) -> Float? {
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    var property = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr ? value : nil
  }

  @discardableResult
  static func setVolume(_ value: Float, device: AudioObjectID) -> Bool {
    var value = Float32(min(max(value, 0), 1))
    var property = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    let size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectSetPropertyData(device, &property, 0, nil, size, &value) == noErr
  }

  static func isMuted(_ device: AudioObjectID) -> Bool {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var property = address(kAudioDevicePropertyMute)
    return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr && value != 0
  }

  static func setMuted(_ muted: Bool, device: AudioObjectID) {
    var value: UInt32 = muted ? 1 : 0
    var property = address(kAudioDevicePropertyMute)
    AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
  }
}

/// Brightness of the built-in display. The real access to the private symbol lives
/// in `PrivateBridges.DisplayServicesBridge`: only the names that this module's
/// callers already use remain here.
enum DisplayBrightness {
  static func builtInDisplay() -> CGDirectDisplayID? { DisplayServicesBridge.builtInDisplay() }
  static func get(_ display: CGDirectDisplayID) -> Float? { DisplayServicesBridge.brightness(of: display) }
  @discardableResult
  static func set(_ value: Float, display: CGDirectDisplayID) -> Bool {
    DisplayServicesBridge.setBrightness(value, display: display)
  }
}

/// Makes the panel appear on the lock screen too, moving it to a
/// SkyLight Space at absolute level (private APIs, opt-in: DESIGN.md §2.1).
/// The real access to the symbol lives in `PrivateBridges.SkyLightBridge`.
@MainActor
enum LockScreenSpace {
  @discardableResult
  static func attach(_ windows: [NSWindow]) -> Bool {
    SkyLightBridge.attachWindowsToLockScreenSpace(windows)
  }
}
