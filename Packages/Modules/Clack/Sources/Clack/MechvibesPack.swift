// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

@preconcurrency import AVFoundation
import Carbon.HIToolbox
import Foundation

/// Pack imported by the user, as remembered by the preferences.
public struct ImportedPack: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
}

enum MechvibesError: Error, Equatable {
  case invalidConfig
  case noSounds
  case missingFile(String)
  case tooLarge
  case unreadableAudio(String)
}

/// `config.json` of a Mechvibes pack: one sound per key, sliced from a
/// single file ("single") or one file per key ("multi").
struct MechvibesPack: Sendable, Equatable {
  enum Sound: Sendable, Equatable {
    case slice(file: String, startMs: Double, durationMs: Double)
    case file(String)

    var file: String {
      switch self {
      case .slice(let file, _, _), .file(let file): file
      }
    }
  }

  var name: String
  /// Mechvibes key code (PC scancode) → sound.
  var sounds: [Int: Sound]

  var files: Set<String> { Set(sounds.values.map(\.file)) }

  /// Reads the configuration tolerantly: `null` or malformed entries are skipped.
  static func parse(_ data: Data) throws(MechvibesError) -> MechvibesPack {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let defines = root["defines"] as? [String: Any]
    else { throw .invalidConfig }
    let single = (root["sound"] as? String).flatMap(safeFileName)
    var sounds: [Int: Sound] = [:]
    for (key, value) in defines {
      guard let code = Int(key) else { continue }
      if let range = value as? [NSNumber], range.count == 2, let single, range[1].doubleValue > 0 {
        sounds[code] = .slice(file: single, startMs: max(0, range[0].doubleValue), durationMs: range[1].doubleValue)
      } else if let name = (value as? String).flatMap(safeFileName) {
        sounds[code] = .file(name)
      }
    }
    guard !sounds.isEmpty else { throw .noSounds }
    let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return MechvibesPack(name: name.isEmpty ? "Mechvibes" : String(name.prefix(80)), sounds: sounds)
  }

  /// Only a plain file name: no paths, so a pack cannot read outside its folder.
  static func safeFileName(_ name: String) -> String? {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0")
    else { return nil }
    return name
  }

  /// macOS key → Mechvibes code (libuiohook "set 1" scancode).
  static let scancodes: [Int: Int] = [
    kVK_Escape: 1, kVK_ANSI_1: 2, kVK_ANSI_2: 3, kVK_ANSI_3: 4, kVK_ANSI_4: 5, kVK_ANSI_5: 6, kVK_ANSI_6: 7,
    kVK_ANSI_7: 8, kVK_ANSI_8: 9, kVK_ANSI_9: 10, kVK_ANSI_0: 11, kVK_ANSI_Minus: 12, kVK_ANSI_Equal: 13,
    kVK_Delete: 14, kVK_Tab: 15, kVK_ANSI_Q: 16, kVK_ANSI_W: 17, kVK_ANSI_E: 18, kVK_ANSI_R: 19, kVK_ANSI_T: 20,
    kVK_ANSI_Y: 21, kVK_ANSI_U: 22, kVK_ANSI_I: 23, kVK_ANSI_O: 24, kVK_ANSI_P: 25, kVK_ANSI_LeftBracket: 26,
    kVK_ANSI_RightBracket: 27, kVK_Return: 28, kVK_ANSI_A: 30, kVK_ANSI_S: 31, kVK_ANSI_D: 32, kVK_ANSI_F: 33,
    kVK_ANSI_G: 34, kVK_ANSI_H: 35, kVK_ANSI_J: 36, kVK_ANSI_K: 37, kVK_ANSI_L: 38, kVK_ANSI_Semicolon: 39,
    kVK_ANSI_Quote: 40, kVK_ANSI_Grave: 41, kVK_ANSI_Backslash: 43, kVK_ANSI_Z: 44, kVK_ANSI_X: 45, kVK_ANSI_C: 46,
    kVK_ANSI_V: 47, kVK_ANSI_B: 48, kVK_ANSI_N: 49, kVK_ANSI_M: 50, kVK_ANSI_Comma: 51, kVK_ANSI_Period: 52,
    kVK_ANSI_Slash: 53, kVK_Space: 57, kVK_F1: 59, kVK_F2: 60, kVK_F3: 61, kVK_F4: 62, kVK_F5: 63, kVK_F6: 64,
    kVK_F7: 65, kVK_F8: 66, kVK_F9: 67, kVK_F10: 68, kVK_F11: 87, kVK_F12: 88, kVK_Home: 3655, kVK_PageUp: 3657,
    kVK_End: 3663, kVK_PageDown: 3665, kVK_ForwardDelete: 3667, kVK_UpArrow: 57416, kVK_LeftArrow: 57419,
    kVK_RightArrow: 57421, kVK_DownArrow: 57424, kVK_ANSI_KeypadEnter: 3612,
  ]
}

/// Imported packs: copies inside Application Support, never the original files.
enum MechvibesStore {
  static let maxConfigBytes = 1_000_000
  static let maxFileBytes = 25_000_000
  static let maxTotalBytes = 60_000_000
  static let maxFiles = 200

  static var directory: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Tsukumo/Clack/Packs", isDirectory: true)
  }

  static func directory(for id: String, in root: URL = directory) -> URL {
    root.appendingPathComponent(id, isDirectory: true)
  }

  /// Validates a pack (folder or `config.json`) and copies only what is needed.
  static func importPack(from url: URL, into root: URL = directory) throws -> ImportedPack {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw MechvibesError.invalidConfig }
    let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    let configURL = folder.appendingPathComponent("config.json")
    guard let size = fileSize(configURL), size <= maxConfigBytes, let data = try? Data(contentsOf: configURL) else {
      throw MechvibesError.invalidConfig
    }
    let pack = try MechvibesPack.parse(data)
    let files = pack.files.sorted()
    guard files.count <= maxFiles else { throw MechvibesError.tooLarge }
    var total = 0
    for name in files {
      guard let size = fileSize(folder.appendingPathComponent(name)) else { throw MechvibesError.missingFile(name) }
      total += size
      guard size <= maxFileBytes, total <= maxTotalBytes else { throw MechvibesError.tooLarge }
    }
    // It is enough for the first file to be readable audio; the others are dropped at load time if broken.
    if let first = files.first, (try? AVAudioFile(forReading: folder.appendingPathComponent(first))) == nil {
      throw MechvibesError.unreadableAudio(first)
    }

    let id = UUID().uuidString
    let destination = directory(for: id, in: root)
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    do {
      try data.write(to: destination.appendingPathComponent("config.json"))
      for name in files {
        try manager.copyItem(at: folder.appendingPathComponent(name), to: destination.appendingPathComponent(name))
      }
    } catch {
      try? manager.removeItem(at: destination)
      throw error
    }
    return ImportedPack(id: id, name: pack.name)
  }

  static func remove(id: String, in root: URL = directory) {
    guard MechvibesPack.safeFileName(id) != nil else { return }
    try? FileManager.default.removeItem(at: directory(for: id, in: root))
  }

  private static func fileSize(_ url: URL) -> Int? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true
    else { return nil }
    return values.fileSize
  }
}

/// Buffers ready for the engine: one per key, plus the list for keys the pack does not define.
struct MechvibesBuffers {
  var byKeyCode: [UInt16: AVAudioPCMBuffer] = [:]
  var fallback: [AVAudioPCMBuffer] = []

  var isEmpty: Bool { byKeyCode.isEmpty && fallback.isEmpty }

  func buffer(for keyCode: UInt16) -> AVAudioPCMBuffer? {
    if let buffer = byKeyCode[keyCode] { return buffer }
    return fallback.isEmpty ? nil : fallback[Int(keyCode) % fallback.count]
  }

  /// Decodes the pack's files once and slices the sound of each key.
  static func load(directory: URL) -> MechvibesBuffers {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
      let pack = try? MechvibesPack.parse(data)
    else { return MechvibesBuffers() }

    var decoded: [String: AVAudioPCMBuffer] = [:]
    for name in pack.files {
      let url = directory.appendingPathComponent(name)
      // A "single" file contains all the keys; a "multi" file is a single hit.
      decoded[name] = ClackEngine.buffer(fromFile: url, maxSeconds: ClackEngine.packMaxSeconds)
    }
    var byScancode: [Int: AVAudioPCMBuffer] = [:]
    for (code, sound) in pack.sounds {
      guard let source = decoded[sound.file] else { continue }
      switch sound {
      case .slice(_, let startMs, let durationMs):
        byScancode[code] = ClackEngine.slice(source, startMs: startMs, durationMs: durationMs)
      case .file:
        byScancode[code] = ClackEngine.slice(source, startMs: 0, durationMs: ClackEngine.customMaxSeconds * 1000)
      }
    }
    var result = MechvibesBuffers()
    for (keyCode, scancode) in MechvibesPack.scancodes {
      if let buffer = byScancode[scancode] { result.byKeyCode[UInt16(keyCode)] = buffer }
    }
    // Stable order: the same undefined key always sounds the same.
    result.fallback = byScancode.keys.sorted().compactMap { byScancode[$0] }
    return result
  }
}
