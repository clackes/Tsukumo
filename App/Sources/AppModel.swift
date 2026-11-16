// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Clack
import Convert
import Duo
import Foundation
import Island
import MenuBar
import ModuleKit
import Monitor
import Observation
import ServiceManagement
import Snap
import Sound
import Switcher
import os

/// Pages of the Settings window.
enum SettingsPage: Hashable {
  case general
  case module(String)
}

/// App state: the module registry and persistence of the turned-on modules.
@Observable
final class AppModel {
  let permissions: PermissionBroker
  let registry: ModuleRegistry
  let settings: ModuleSettingsStore
  let sampler: SharedSampler
  var launchesAtLogin: Bool
  var showsMenuBarIcon: Bool
  var onMenuBarIconVisibilityChange: (@MainActor (Bool) -> Void)?
  /// Reopens the page with all permissions (the same as on first launch).
  var onReviewPermissions: (@MainActor () -> Void)?
  /// Page shown by the Settings window.
  var settingsPage: SettingsPage = .general
  /// Permissions that prevented the last turn-on, per module.
  private(set) var missingPermissions: [String: [Permission]] = [:]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let log = Logger(subsystem: "dev.local.tsukumo", category: "app")
  private static let enabledKey = "enabledModules"
  private static let showsMenuBarIconKey = "showsMenuBarIcon"

  init(defaults: UserDefaults = .standard, permissions: PermissionBroker = PermissionBroker()) {
    Self.migrateRenamedModules(in: defaults)
    self.defaults = defaults
    self.permissions = permissions
    settings = ModuleSettingsStore(defaults: defaults)
    sampler = SharedSampler()
    launchesAtLogin = SMAppService.mainApp.status == .enabled
    showsMenuBarIcon = defaults.object(forKey: Self.showsMenuBarIconKey) as? Bool ?? true
    registry = ModuleRegistry(permissions: permissions, settings: settings, sampler: sampler)
  }

  /// Module ids renamed in 0.1.6 ("converti" became "convert", "suono" became "sound"):
  /// moves their settings and the enabled flag once, so an update keeps the user's setup.
  static func migrateRenamedModules(in defaults: UserDefaults) {
    let renames = ["converti": "convert", "suono": "sound"]
    let marker = "migratedModuleIDs.v1"
    guard !defaults.bool(forKey: marker) else { return }
    for (key, value) in defaults.dictionaryRepresentation() {
      for (old, new) in renames where key.contains(".\(old).") {
        let renamed = key.replacingOccurrences(of: ".\(old).", with: ".\(new).")
        if defaults.object(forKey: renamed) == nil { defaults.set(value, forKey: renamed) }
        defaults.removeObject(forKey: key)
      }
    }
    if let enabled = defaults.stringArray(forKey: enabledKey) {
      defaults.set(enabled.map { renames[$0] ?? $0 }, forKey: enabledKey)
    }
    defaults.set(true, forKey: marker)
  }

  func setShowsMenuBarIcon(_ visible: Bool) {
    showsMenuBarIcon = visible
    defaults.set(visible, forKey: Self.showsMenuBarIconKey)
    onMenuBarIconVisibilityChange?(visible)
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchesAtLogin = SMAppService.mainApp.status == .enabled
    } catch {
      launchesAtLogin = SMAppService.mainApp.status == .enabled
      log.error("Launch at login not changed: \(String(describing: error), privacy: .public)")
    }
  }

  /// List of modules compiled into the app. Registering instantiates nothing.
  func registerModules() {
    let entries: [ModuleEntry] = [
      ModuleEntry(MonitorModule.self),
      ModuleEntry(MenuBarModule.self),
      ModuleEntry(SnapModule.self),
      ModuleEntry(ClackModule.self),
      ModuleEntry(IslandModule.self),
      ModuleEntry(ConvertModule.self),
      ModuleEntry(DuoModule.self),
      ModuleEntry(SwitcherModule.self),
      ModuleEntry(SoundModule.self),
    ]
    for entry in entries {
      do {
        try registry.register(entry)
      } catch {
        log.fault("Registration failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  /// Turns the modules that were on at the last quit back on.
  func restoreEnabledModules() async {
    // System ⌘⇥ left disabled by a previous crash (DESIGN.md §2.2.1, point 2).
    NativeSwitcherGuard.restoreIfNeeded()
    for id in enabledIDs where registry.entries.contains(where: { $0.descriptor.id == id }) {
      await setEnabled(true, id: id, persist: false)
    }
  }

  /// Retries modules left stopped by a missing permission (after a grant).
  func retryBlockedModules() async {
    for id in missingPermissions.keys.sorted() {
      await setEnabled(true, id: id, persist: false)
    }
  }

  func setEnabled(_ enabled: Bool, id: String, persist: Bool = true) async {
    var shouldRememberEnable = false
    if enabled {
      do {
        try await registry.enable(id)
        missingPermissions[id] = nil
        shouldRememberEnable = registry.isRunning(id)
      } catch .missingPermissions(_, let missing) {
        missingPermissions[id] = missing
        // Keeps the intent: after granting TCC and relaunching, the module restarts.
        shouldRememberEnable = true
      } catch {
        log.error("Turning on \(id, privacy: .public) was refused: \(String(describing: error), privacy: .public)")
      }
    } else {
      await registry.disable(id)
      missingPermissions[id] = nil
    }
    guard persist else { return }
    var ids = Set(enabledIDs)
    if enabled, shouldRememberEnable {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    defaults.set(ids.sorted(), forKey: Self.enabledKey)
  }

  func name(of descriptor: ModuleDescriptor) -> String {
    String(localized: String.LocalizationValue(descriptor.nameKey))
  }

  private var enabledIDs: [String] {
    defaults.stringArray(forKey: Self.enabledKey) ?? []
  }
}
