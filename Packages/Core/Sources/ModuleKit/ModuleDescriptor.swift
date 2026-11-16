// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

/// Identifying color of a module. The UI translates it to `Color` (DesignSystem).
public enum ModuleTint: String, Sendable, CaseIterable {
  case blue, cyan, green, indigo, mint, orange, pink, purple, red, teal, yellow, gray
}

/// System permissions a module may request (DESIGN.md §4.3, `PermissionBroker`).
public enum Permission: String, Sendable, CaseIterable {
  case accessibility
  case inputMonitoring
  case screenRecording
  case calendars
  case reminders
  case motion
  case bluetooth
  case localNetwork
  case automation
}

/// Consumption class declared by the module and shown in Settings.
public enum EnergyClass: String, Sendable, CaseIterable {
  case zero, low, medium, high
}

/// On-demand XPC helper a module may need (DESIGN.md §4.1).
public enum HelperID: String, Sendable, CaseIterable {
  case privateBridge
  case converter
}

/// Outcome of a module's canary, used for fault isolation.
public enum ModuleHealth: Sendable, Equatable {
  case ok
  case degraded(String)
  case broken(String)
}

/// Static description of a module: a literal constant value, readable
/// without instantiating the module and without touching any of its other code (DESIGN.md §4.2,
/// rule 3). Contains only our own types or Foundation ones that are surely `Sendable`.
/// It is not a dictionary key: the registry is keyed on `id`.
public struct ModuleDescriptor: Sendable {
  /// Registry key, e.g. `"island.media"`.
  public let id: String
  /// Key in the String Catalog; the UI resolves it.
  public let nameKey: String
  /// Name of an SF Symbol.
  public let symbol: String
  public let tint: ModuleTint
  public let permissions: Set<Permission>
  public let energyClass: EnergyClass
  public let requiresHelper: Set<HelperID>
  public let minOSMajor: Int
  public let minOSMinor: Int

  public init(
    id: String,
    nameKey: String,
    symbol: String,
    tint: ModuleTint,
    permissions: Set<Permission> = [],
    energyClass: EnergyClass,
    requiresHelper: Set<HelperID> = [],
    minOSMajor: Int = 26,
    minOSMinor: Int = 0
  ) {
    self.id = id
    self.nameKey = nameKey
    self.symbol = symbol
    self.tint = tint
    self.permissions = permissions
    self.energyClass = energyClass
    self.requiresHelper = requiresHelper
    self.minOSMajor = minOSMajor
    self.minOSMinor = minOSMinor
  }

  /// `true` if the module can run on the given system version.
  public func supports(osMajor: Int, osMinor: Int) -> Bool {
    (osMajor, osMinor) >= (minOSMajor, minOSMinor)
  }
}
