// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Foundation

/// Type of an output device, derived from its transport type.
enum AudioDeviceKind: Sendable, Equatable {
  case builtIn
  case bluetooth
  case usb
  case airPlay
  case display
  case other

  /// Classifies Core Audio's `kAudioDevicePropertyTransportType`.
  init(transportType: UInt32) {
    switch transportType {
    case UInt32(kAudioDeviceTransportTypeBuiltIn): self = .builtIn
    case UInt32(kAudioDeviceTransportTypeBluetooth), UInt32(kAudioDeviceTransportTypeBluetoothLE): self = .bluetooth
    case UInt32(kAudioDeviceTransportTypeUSB): self = .usb
    case UInt32(kAudioDeviceTransportTypeAirPlay): self = .airPlay
    case UInt32(kAudioDeviceTransportTypeHDMI), UInt32(kAudioDeviceTransportTypeDisplayPort): self = .display
    default: self = .other
    }
  }

  /// Name of the SF Symbol shown next to the device.
  var symbol: String {
    switch self {
    case .builtIn: "laptopcomputer"
    case .bluetooth: "headphones"
    case .usb: "cable.connector"
    case .airPlay: "airplayaudio"
    case .display: "display"
    case .other: "hifispeaker"
    }
  }
}

/// An audio output device, as the popover sees it.
struct AudioOutputDevice: Identifiable, Sendable, Equatable {
  let id: AudioObjectID
  let uid: String
  let name: String
  let kind: AudioDeviceKind
}

/// Volume conversions between Core Audio (scalar 0…1) and the interface.
enum VolumeScale {
  static func clamped(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }

  /// Whole percentage for labels: 0…100.
  static func percent(_ value: Double) -> Int {
    Int((clamped(value) * 100).rounded())
  }

  /// The scalar value to write to the device.
  static func scalar(_ value: Double) -> Float32 {
    Float32(clamped(value))
  }
}

/// What changed in Core Audio.
enum AudioChange: Sendable, Equatable {
  /// List of devices or default output device.
  case devices
  /// Volume or mute of the default device.
  case levels
  /// List of processes playing audio, or the "is running output" state
  /// of one of them.
  case processes
}

/// Boundary between the module's logic and Core Audio: tests use a fake version.
///
/// Extension point for per-app volume and output (DESIGN.md §2.4.1, spike 27):
/// process taps will have their own protocol next to this one, without touching it.
@MainActor
protocol AudioBackend: AnyObject {
  func outputDevices() -> [AudioOutputDevice]
  func defaultOutputID() -> AudioObjectID?
  /// `false` if the system refused the change.
  func setDefaultOutput(_ id: AudioObjectID, includingSystemEffects: Bool) -> Bool
  /// `nil` if the device has no adjustable volume.
  func volume(of id: AudioObjectID) -> Double?
  func setVolume(_ value: Double, of id: AudioObjectID)
  /// `nil` if the device has no mute.
  func isMuted(_ id: AudioObjectID) -> Bool?
  func setMuted(_ muted: Bool, of id: AudioObjectID)
  /// Starts listening for changes; the returned closure removes every listener.
  func observe(_ onChange: @escaping @MainActor (AudioChange) -> Void) -> @MainActor () -> Void
  /// The apps emitting audio right now. Stable order (by name).
  func runningAudioProcesses(keeping: Set<AudioObjectID>) -> [AudioProcess]
}
