// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Typed local preferences, separated by module ID (DESIGN.md §4.3).
/// Versionable JSON values; a module cannot read another one's space.
@MainActor
public final class ModuleSettingsStore {
  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let prefix: String

  public static let shared: ModuleSettingsStore = .init()

  public init(defaults: UserDefaults = .standard, prefix: String = "dev.local.tsukumo.settings") {
    self.defaults = defaults
    self.prefix = prefix
  }

  public func value<Value: Decodable>(forKey key: String, moduleID: String, as type: Value.Type = Value.self) -> Value?
  {
    guard let data = defaults.data(forKey: storageKey(key, moduleID: moduleID)) else { return nil }
    return try? decoder.decode(type, from: data)
  }

  public func set<Value: Encodable>(_ value: Value?, forKey key: String, moduleID: String) throws {
    let storageKey = storageKey(key, moduleID: moduleID)
    guard let value else { defaults.removeObject(forKey: storageKey); return }
    defaults.set(try encoder.encode(value), forKey: storageKey)
  }

  public func reset(moduleID: String) {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(modulePrefix(moduleID)) {
      defaults.removeObject(forKey: key)
    }
  }

  /// Exports only the requested module's data, without global preferences.
  public func export(moduleID: String) throws -> Data {
    let values = defaults.dictionaryRepresentation().reduce(into: [String: Data]()) { result, entry in
      guard entry.key.hasPrefix(modulePrefix(moduleID)), let data = entry.value as? Data else { return }
      result[String(entry.key.dropFirst(modulePrefix(moduleID).count))] = data
    }
    return try encoder.encode(values)
  }

  /// Imports a typed JSON archive and rejects malformed or oversized files.
  public func `import`(_ data: Data, moduleID: String, maximumBytes: Int = 1_000_000) throws {
    guard data.count <= maximumBytes else { throw ModuleSettingsError.archiveTooLarge }
    let values = try decoder.decode([String: Data].self, from: data)
    for (key, value) in values { defaults.set(value, forKey: storageKey(key, moduleID: moduleID)) }
  }

  private func modulePrefix(_ moduleID: String) -> String { "\(prefix).\(moduleID)." }
  private func storageKey(_ key: String, moduleID: String) -> String { modulePrefix(moduleID) + key }
}

public enum ModuleSettingsError: Error, Equatable {
  case archiveTooLarge
}
