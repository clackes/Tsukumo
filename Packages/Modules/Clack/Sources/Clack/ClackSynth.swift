// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Built-in sounds, generated at load time: no third-party audio files in the repo.
public enum ClackPack: String, CaseIterable, Codable, Sendable {
  /// Dry, full hit, like a linear switch.
  case linear
  /// Sharper, more pronounced click, like a tactile switch.
  case tactile
  /// Bright double click, like a "blue" switch.
  case clicky
  /// Low, round hit ("thock").
  case deep
  /// Soft and muffled.
  case muffled
  /// Hammer with a metallic tail.
  case typewriter
  /// Wooden block.
  case legno
  /// Drop: falling tone.
  case bolla
  /// High-pitched tinkle.
  case vetro
  /// Square beep like an old computer.
  case retro
}

public enum ClackSoundKind: Sendable, Hashable {
  case down
  /// Wide keys (space, return, backspace): lower and longer.
  case downWide
  case up
}

/// Synthesis of a keyboard click: a burst of filtered noise, a damped resonance
/// of the "case" and, depending on the pack, a metallic tail, a second
/// click or a sliding tone. Pure, deterministic function (seeded generator).
public enum ClackSynth {
  public static let variantsPerKind = 5

  struct Profile {
    var noiseLevel = 1.0
    var noiseDecay = 420.0
    /// 0 = heavily filtered noise (dark), 1 = nearly white (bright).
    var brightness = 0.45
    var toneFrequency = 190.0
    var toneDecay = 70.0
    var toneLevel = 0.55
    /// Ratio between final and initial tone frequency (1 = fixed).
    var sweep = 1.0
    var square = false
    var ringFrequency = 0.0
    var ringDecay = 60.0
    var ringLevel = 0.0
    /// Second click after `clickDelay` seconds (0 = absent).
    var clickDelay = 0.0
    var clickLevel = 0.0
    var duration = 0.09
  }

  static func baseProfile(_ pack: ClackPack) -> Profile {
    switch pack {
    case .linear: Profile()
    case .tactile:
      Profile(noiseDecay: 650, brightness: 0.8, toneFrequency: 320, toneDecay: 110, toneLevel: 0.4, duration: 0.07)
    case .clicky:
      Profile(
        noiseDecay: 900, brightness: 0.95, toneFrequency: 520, toneDecay: 160, toneLevel: 0.25,
        ringFrequency: 3_400, ringDecay: 220, ringLevel: 0.18, clickDelay: 0.012, clickLevel: 0.7, duration: 0.07)
    case .deep:
      Profile(
        noiseLevel: 0.7, noiseDecay: 260, brightness: 0.22, toneFrequency: 105, toneDecay: 45, toneLevel: 0.9,
        duration: 0.13)
    case .muffled:
      Profile(noiseDecay: 300, brightness: 0.18, toneFrequency: 140, toneDecay: 55, toneLevel: 0.6, duration: 0.11)
    case .typewriter:
      Profile(
        noiseDecay: 520, brightness: 0.7, toneFrequency: 240, toneDecay: 90, toneLevel: 0.5,
        ringFrequency: 2_150, ringDecay: 28, ringLevel: 0.22, duration: 0.19)
    case .legno:
      Profile(
        noiseLevel: 0.35, noiseDecay: 800, brightness: 0.5, toneFrequency: 760, toneDecay: 85, toneLevel: 0.8,
        ringFrequency: 1_830, ringDecay: 140, ringLevel: 0.2, duration: 0.08)
    case .bolla:
      Profile(
        noiseLevel: 0.08, noiseDecay: 900, brightness: 0.3, toneFrequency: 880, toneDecay: 38, toneLevel: 0.85,
        sweep: 0.35, duration: 0.1)
    case .vetro:
      Profile(
        noiseLevel: 0.25, noiseDecay: 1_200, brightness: 1, toneFrequency: 1_900, toneDecay: 45, toneLevel: 0.45,
        ringFrequency: 4_370, ringDecay: 60, ringLevel: 0.25, duration: 0.14)
    case .retro:
      Profile(
        noiseLevel: 0.05, noiseDecay: 900, brightness: 1, toneFrequency: 660, toneDecay: 45, toneLevel: 0.4,
        sweep: 0.8, square: true, duration: 0.06)
    }
  }

  static func profile(_ pack: ClackPack, _ kind: ClackSoundKind) -> Profile {
    var profile = baseProfile(pack)
    switch kind {
    case .down: break
    case .downWide:
      profile.noiseDecay *= 0.7
      profile.toneFrequency *= 0.72
      profile.toneDecay *= 0.7
      profile.toneLevel = min(1, profile.toneLevel * 1.15)
      profile.brightness *= 0.8
      profile.duration *= 1.35
    case .up:
      profile.noiseDecay *= 1.5
      profile.toneFrequency *= 1.6
      profile.toneDecay *= 1.6
      profile.toneLevel *= 0.45
      profile.ringLevel *= 0.4
      profile.clickLevel = 0
      profile.brightness = min(1, profile.brightness * 1.3)
      profile.duration *= 0.6
    }
    return profile
  }

  /// Mono samples in [-1, 1]. Each variant slightly changes pitch and attack,
  /// so repetition does not sound mechanical.
  public static func samples(
    pack: ClackPack, kind: ClackSoundKind, variant: Int, sampleRate: Double = 48_000
  ) -> [Float] {
    let profile = profile(pack, kind)
    var generator = SplitMix(seed: UInt64(pack.hashSeed &* 131 &+ kind.hashSeed &* 31 &+ variant &* 977 &+ 1))
    let detune = 1 + (generator.unit() - 0.5) * 0.12
    let level = (kind == .up ? 0.5 : 0.85) * (0.9 + generator.unit() * 0.2)
    let count = Int(profile.duration * sampleRate)
    var output = [Float](repeating: 0, count: count)
    var filtered = 0.0
    var phase = 0.0
    let smoothing = 0.02 + profile.brightness * 0.9
    for index in 0..<count {
      let time = Double(index) / sampleRate
      // White noise through a one-pole low-pass: the pack's "brightness".
      filtered += smoothing * ((generator.unit() * 2 - 1) - filtered)
      var value = filtered * exp(-profile.noiseDecay * time) * profile.noiseLevel
      if profile.clickDelay > 0, time >= profile.clickDelay {
        value += filtered * exp(-profile.noiseDecay * (time - profile.clickDelay)) * profile.clickLevel
      }
      // The frequency slides exponentially from `toneFrequency` to `toneFrequency * sweep`.
      let frequency = profile.toneFrequency * detune * pow(profile.sweep, time / profile.duration)
      phase += 2 * .pi * frequency / sampleRate
      let wave = profile.square ? (sin(phase) >= 0 ? 1.0 : -1.0) : sin(phase)
      value += wave * exp(-profile.toneDecay * time) * profile.toneLevel
      if profile.ringLevel > 0 {
        value +=
          sin(2 * .pi * profile.ringFrequency * detune * time) * exp(-profile.ringDecay * time) * profile.ringLevel
      }
      // Half-millisecond attack and closing to zero: no digital "tick" at the edges.
      let attack = min(1, time / 0.0005)
      let release = min(1, Double(count - index) / (0.004 * sampleRate))
      output[index] = Float(max(-1, min(1, value * level * attack * release)))
    }
    return output
  }
}

extension ClackPack {
  fileprivate var hashSeed: Int { Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 1 }
}

extension ClackSoundKind {
  fileprivate var hashSeed: Int {
    switch self {
    case .down: 3
    case .downWide: 5
    case .up: 7
    }
  }
}

/// Small, reproducible pseudo-random generator.
struct SplitMix {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  /// Uniform value in [0, 1).
  mutating func unit() -> Double {
    Double(next() >> 11) / Double(1 << 53)
  }
}

/// Key positions on the keyboard, for stereo pan and for wide keys.
public enum ClackKeyboard {
  private static let rows: [[UInt16]] = [
    [53, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111],
    [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24, 51],
    [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42],
    [57, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 36],
    [56, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 60],
    [63, 59, 58, 55, 49, 54, 61, 123, 125, 124],
  ]

  private static let positions: [UInt16: Float] = {
    var result: [UInt16: Float] = [:]
    for row in rows {
      for (index, key) in row.enumerated() {
        result[key] = Float(index) / Float(row.count - 1) * 2 - 1
      }
    }
    result[49] = 0  // space bar: centre
    result[126] = result[125]  // up arrow above the down arrow
    return result
  }()

  private static let wide: Set<UInt16> = [49, 36, 51, 48, 57, 56, 60, 76]

  /// Pan in [-0.6, 0.6]: enough to hear the position, without being annoying in headphones.
  public static func pan(for keyCode: UInt16) -> Float {
    (positions[keyCode] ?? 0) * 0.6
  }

  public static func isWide(_ keyCode: UInt16) -> Bool { wide.contains(keyCode) }
}
