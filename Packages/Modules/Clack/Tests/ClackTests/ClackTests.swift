// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Carbon.HIToolbox
import Foundation
import Testing

@testable import Clack

@Suite("Clack")
struct ClackTests {
  @Test("every sound is short, within [-1, 1], audible and ends at zero")
  func samplesAreWellFormed() {
    for pack in ClackPack.allCases {
      for kind in [ClackSoundKind.down, .downWide, .up] {
        for variant in 0..<ClackSynth.variantsPerKind {
          let samples = ClackSynth.samples(pack: pack, kind: kind, variant: variant)
          #expect(samples.count > 1_000 && samples.count < 14_400)
          let peak = samples.map(abs).max() ?? 0
          #expect(peak > 0.05 && peak <= 1)
          #expect(abs(samples[0]) < 0.01)
          #expect(abs(samples[samples.count - 1]) < 0.01)
        }
      }
    }
  }

  @Test("synthesis is deterministic and the variants differ from each other")
  func deterministicVariants() {
    let first = ClackSynth.samples(pack: .linear, kind: .down, variant: 0)
    #expect(first == ClackSynth.samples(pack: .linear, kind: .down, variant: 0))
    #expect(first != ClackSynth.samples(pack: .linear, kind: .down, variant: 1))
    #expect(first != ClackSynth.samples(pack: .tactile, kind: .down, variant: 0))
  }

  @Test("pan follows the key position and stays moderate")
  func panFollowsKeyPosition() {
    #expect(ClackKeyboard.pan(for: 12) < 0)  // Q on the left
    #expect(ClackKeyboard.pan(for: 35) > 0)  // P on the right
    #expect(ClackKeyboard.pan(for: 49) == 0)  // space in the centre
    #expect(ClackKeyboard.pan(for: 999) == 0)  // unknown key
    for key in UInt16(0)...130 { #expect(abs(ClackKeyboard.pan(for: key)) <= 0.6) }
    #expect(ClackKeyboard.isWide(49) && !ClackKeyboard.isWide(0))
  }

  @Test("samples become a stereo buffer of the same length")
  func bufferConversion() throws {
    let samples = ClackSynth.samples(pack: .muffled, kind: .up, variant: 2)
    let buffer = try #require(ClackEngine.buffer(from: samples))
    #expect(Int(buffer.frameLength) == samples.count)
    #expect(buffer.format.channelCount == 2)
    #expect(ClackEngine.buffer(from: []) == nil)
  }

  @Test("any audio file becomes a 48 kHz stereo buffer, trimmed to the maximum duration")
  func customFileLoading() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clack-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    // Mono at 22.05 kHz, 3 seconds: format and length different from the engine's.
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
    let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 66_150))
    source.frameLength = 66_150
    let channel = try #require(source.floatChannelData?[0])
    for index in 0..<66_150 { channel[index] = sin(Float(index) * 0.2) * 0.5 }
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: source)
    }

    let buffer = try #require(ClackEngine.buffer(fromFile: url))
    #expect(buffer.format.sampleRate == 48_000 && buffer.format.channelCount == 2)
    let seconds = Double(buffer.frameLength) / 48_000
    #expect(seconds > 1.4 && seconds <= ClackEngine.customMaxSeconds + 0.05)
    #expect(ClackEngine.buffer(fromFile: URL(fileURLWithPath: "/nonexistent.wav")) == nil)
  }
}

@Suite("Clack: Mechvibes pack")
struct MechvibesTests {
  private func makePack(config: String, seconds: Double = 1) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-mv-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(config.utf8).write(to: folder.appendingPathComponent("config.json"))
    // One second of a 44.1 kHz mono sine: the engine converts it to 48 kHz stereo.
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let frames = AVAudioFrameCount(44_100 * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)[0]
    for index in 0..<Int(frames) { samples[index] = sin(Float(index) * 0.05) * 0.5 }
    let file = try AVAudioFile(forWriting: folder.appendingPathComponent("sound.wav"), settings: format.settings)
    try file.write(from: buffer)
    return folder
  }

  private let single = """
    {"name": " Test ", "key_define_type": "single", "sound": "sound.wav",
     "defines": {"30": [100, 200], "57": [400, 300], "31": null, "x": [0, 1], "32": [5000, 100]}}
    """

  @Test("single config: valid slices kept, null or malformed entries skipped")
  func parseSingle() throws {
    let pack = try MechvibesPack.parse(Data(single.utf8))
    #expect(pack.name == "Test")
    #expect(pack.sounds[30] == .slice(file: "sound.wav", startMs: 100, durationMs: 200))
    #expect(pack.sounds[31] == nil && pack.sounds.count == 3)
    #expect(pack.files == ["sound.wav"])
  }

  @Test("multi config: one file per key; paths outside the folder are rejected")
  func parseMulti() throws {
    let config = #"{"defines": {"1": "a.ogg", "2": "../../etc/passwd", "3": "sub/b.ogg"}}"#
    let pack = try MechvibesPack.parse(Data(config.utf8))
    #expect(pack.sounds == [1: .file("a.ogg")])
    #expect(pack.name == "Mechvibes")
    #expect(throws: MechvibesError.noSounds) { try MechvibesPack.parse(Data(#"{"defines": {}}"#.utf8)) }
    #expect(throws: MechvibesError.invalidConfig) { try MechvibesPack.parse(Data("[]".utf8)) }
  }

  @Test("macOS keys map to Mechvibes codes")
  func scancodes() {
    #expect(MechvibesPack.scancodes[kVK_ANSI_A] == 30)
    #expect(MechvibesPack.scancodes[kVK_Space] == 57)
    #expect(MechvibesPack.scancodes[kVK_Return] == 28)
    #expect(Set(MechvibesPack.scancodes.values).count == MechvibesPack.scancodes.count)
  }

  @Test("import, per-key buffer loading and removal")
  func importAndLoad() throws {
    let folder = try makePack(config: single)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-mv-root-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: folder)
      try? FileManager.default.removeItem(at: root)
    }
    let imported = try MechvibesStore.importPack(from: folder.appendingPathComponent("config.json"), into: root)
    #expect(imported.name == "Test")

    let buffers = MechvibesBuffers.load(directory: MechvibesStore.directory(for: imported.id, in: root))
    let keyA = try #require(buffers.byKeyCode[UInt16(kVK_ANSI_A)])
    #expect(keyA.format.sampleRate == ClackEngine.sampleRate && keyA.format.channelCount == 2)
    #expect(abs(Double(keyA.frameLength) - 0.2 * ClackEngine.sampleRate) < 50)
    #expect(buffers.byKeyCode[UInt16(kVK_Space)] != nil)
    // A slice past the end of the file is dropped; an undefined key uses a sound from the pack.
    #expect(buffers.fallback.count == 2)
    #expect(buffers.buffer(for: UInt16(kVK_ANSI_Z)) != nil)

    MechvibesStore.remove(id: imported.id, in: root)
    #expect(MechvibesBuffers.load(directory: MechvibesStore.directory(for: imported.id, in: root)).isEmpty)
  }

  @Test("a pack without its audio file is not imported")
  func importFailures() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-mv-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(throws: MechvibesError.invalidConfig) { try MechvibesStore.importPack(from: folder, into: folder) }
    try Data(single.utf8).write(to: folder.appendingPathComponent("config.json"))
    #expect(throws: MechvibesError.missingFile("sound.wav")) {
      try MechvibesStore.importPack(from: folder, into: folder)
    }
  }
}
