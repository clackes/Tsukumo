// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import Darwin
import DesignSystem
import ModuleKit
import Observation
import SwiftUI

enum MenuBarPreferenceKeys {
  static let hiddenApplications = "menuBar.hiddenApplications"
  static let revealEnabled = "menuBar.revealEnabled"
}

@MainActor
@Observable
final class MenuBarSettingsModel {
  private(set) var applications: [MenuBarApplication] = []
  private(set) var systemItems: [MenuBarSystemItem: Bool] = [:]
  private(set) var errorMessage: String?
  private(set) var needsFullDiskAccess = false
  private let preferences = MenuBarPreferences()

  func setSystemItem(_ item: MenuBarSystemItem, shown: Bool) {
    var hidden = MenuBarSystemItems.userHidden()
    if shown { hidden.remove(item) } else { hidden.insert(item) }
    MenuBarSystemItems.setUserHidden(hidden)
    MenuBarSystemItems.setShown(shown, item)
    systemItems[item] = shown
  }

  // swiftlint:disable:next function_body_length
  func refresh() async {
    // An element turned off here stays "off" even while the arrow is showing it.
    let hiddenSystemItems = MenuBarSystemItems.userHidden()
    systemItems = Dictionary(
      uniqueKeysWithValues: MenuBarSystemItem.allCases.map {
        ($0, !hiddenSystemItems.contains($0) && MenuBarSystemItems.isShown($0))
      })
    guard #available(macOS 27.0, *) else {
      applications = []
      errorMessage = String(localized: "Per-app management requires macOS 27.")
      return
    }

    var processes = NSWorkspace.shared.runningApplications.compactMap { application -> MenuBarProcess? in
      guard
        let bundleID = application.bundleIdentifier,
        !bundleID.hasPrefix("com.apple."),
        bundleID != Bundle.main.bundleIdentifier
      else { return nil }
      return MenuBarProcess(
        bundleID: bundleID,
        processID: application.processIdentifier,
        bundleURL: application.bundleURL,
        displayName: nil
      )
    }
    let knownPIDs = Set(processes.map(\.processID))
    processes.append(
      contentsOf: LaunchAgentProcessDiscovery.runningProcesses().filter { process in
        !knownPIDs.contains(process.processID)
      })
    let hiddenIDs = Set(
      UserDefaults.standard.stringArray(forKey: MenuBarPreferenceKeys.hiddenApplications) ?? [])
    needsFullDiskAccess = !preferences.canAccessContainer
    let states: [String: Bool]
    do {
      states = try preferences.read()
      errorMessage = nil
    } catch {
      states = [:]
      errorMessage =
        needsFullDiskAccess
        ? String(localized: "Tsukumo needs Full Disk Access to change menu bar items.")
        : String(localized: "macOS has not registered any menu bar apps yet.")
    }
    let runningIDs = await MenuBarItemDiscovery.bundleIDs(in: processes)
    let registeredIDs = Set(
      processes.filter { runningIDs.contains($0.bundleID) }.map { process in
        switchIdentifier(for: process, registeredIDs: Set(states.keys))
      })
    let installedIDs = Set(
      states.keys.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
      })
    let knownIDs = registeredIDs.union(installedIDs)
    // Only what macOS no longer knows is pruned. Without reading the preferences
    // (Full Disk Access missing) or with the app merely closed, the entry stays:
    // otherwise the arrow could no longer bring that icon back.
    let staleHiddenIDs = hiddenIDs.subtracting(knownIDs).subtracting(states.keys)
    if !states.isEmpty, !staleHiddenIDs.isEmpty {
      let currentHiddenIDs = hiddenIDs.subtracting(staleHiddenIDs)
      UserDefaults.standard.set(
        currentHiddenIDs.sorted(), forKey: MenuBarPreferenceKeys.hiddenApplications)
    }
    let bundleIDs = knownIDs

    applications =
      bundleIDs
      .filter { !$0.hasPrefix("com.apple.") && $0 != Bundle.main.bundleIdentifier }
      .map { bundleID in
        MenuBarApplication(
          bundleID: bundleID,
          isAllowed: states[bundleID] ?? !hiddenIDs.contains(bundleID),
          canChangeVisibility: states[bundleID] != nil || registeredIDs.contains(bundleID),
          displayName: processes.first(where: { $0.bundleID == bundleID && $0.displayName != nil })?.displayName
        )
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    if !needsFullDiskAccess, errorMessage == nil,
      applications.contains(where: { !$0.canChangeVisibility })
    {
      errorMessage = String(
        localized: "macOS has not registered any menu bar apps yet.")
    }

    if errorMessage == nil, applications.isEmpty {
      errorMessage = String(
        localized: "No third-party app with a menu bar icon is currently running.")
    }
  }

  func openFullDiskAccessSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    else { return }
    NSWorkspace.shared.open(url)
  }

  func setAllowed(_ allowed: Bool, for bundleID: String) {
    setAllowed(allowed, for: [bundleID])
  }

  /// Shows or hides several apps with a single write of the system preference.
  func setAllowed(_ allowed: Bool, for bundleIDs: [String]) {
    guard #available(macOS 27.0, *), !bundleIDs.isEmpty else { return }
    do {
      try preferences.setAllowed(allowed, for: Set(bundleIDs))
      var hiddenIDs = Set(
        UserDefaults.standard.stringArray(forKey: MenuBarPreferenceKeys.hiddenApplications) ?? [])
      if allowed {
        hiddenIDs.subtract(bundleIDs)
      } else {
        hiddenIDs.formUnion(bundleIDs)
      }
      UserDefaults.standard.set(hiddenIDs.sorted(), forKey: MenuBarPreferenceKeys.hiddenApplications)
      Task { await refresh() }
    } catch {
      errorMessage = String(localized: "The change failed. Try again or use System Settings.")
    }
  }

  private func switchIdentifier(for process: MenuBarProcess, registeredIDs: Set<String>) -> String {
    if registeredIDs.contains(process.bundleID) { return process.bundleID }
    // Executable without a registered bundle under another path (previous
    // version, another executable of the same app): that entry applies.
    if let family = MenuBarPreferences.family(of: process.bundleID),
      let sibling = registeredIDs.sorted().first(where: { MenuBarPreferences.family(of: $0) == family })
    {
      return sibling
    }
    guard let path = process.bundleURL?.path else { return process.bundleID }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard let appComponent = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
      return process.bundleID
    }
    let outerPath = "/" + components[...appComponent].joined(separator: "/")
    guard
      outerPath != path,
      let outerBundleID = Bundle(url: URL(fileURLWithPath: outerPath))?.bundleIdentifier,
      registeredIDs.contains(outerBundleID)
    else { return process.bundleID }
    return outerBundleID
  }
}

struct MenuBarApplication: Identifiable {
  let bundleID: String
  let name: String
  let icon: NSImage?
  let isAllowed: Bool
  let canChangeVisibility: Bool

  var id: String { bundleID }

  init(bundleID: String, isAllowed: Bool, canChangeVisibility: Bool, displayName: String? = nil) {
    self.bundleID = bundleID
    self.isAllowed = isAllowed
    self.canChangeVisibility = canChangeVisibility

    if let displayName {
      name = displayName
      icon = nil
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
      let bundle = Bundle(url: url)
    {
      name =
        bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? bundleID
      icon = NSWorkspace.shared.icon(forFile: url.path)
    } else {
      name = displayName ?? bundleID
      icon = nil
    }
  }
}

@MainActor
public final class MenuBarModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "menu-bar",
    nameKey: "Menu Bar",
    symbol: "menubar.rectangle",
    tint: .indigo,
    // Accessibility is only needed to move icons, and the Order section requests it itself:
    // requiring it here blocked `start()` and with it the arrow.
    permissions: [],
    energyClass: .low
  )

  private let context: ModuleContext
  private var model: MenuBarSettingsModel?
  private var order: MenuBarOrderModel?
  private var revealController: MenuBarRevealController?

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    model = MenuBarSettingsModel()
    order = MenuBarOrderModel()
    revealController = MenuBarRevealController(context: context)
  }

  public func stop() async {
    // With the arrow open, the recalled icons go back to hidden: without the module
    // there would be no arrow left to close them again.
    revealController?.concealIfRevealed()
    revealController = nil
    order = nil
    model = nil
  }

  public var settings: AnyView {
    AnyView(MenuBarSettingsView(model: model, order: order, surfaces: context.surfaces))
  }
}

@MainActor
private final class MenuBarRevealController: NSObject {
  private let preferences = MenuBarPreferences()
  private let defaults = UserDefaults.standard
  private let surface: StatusItemSurface
  private let surfaces: SurfaceManager

  init(context: ModuleContext) {
    let revealed = defaults.bool(forKey: MenuBarPreferenceKeys.revealEnabled)
    surface = context.surfaces.makeStatusItem(
      autosaveName: "tsukumo.menubar.reveal",
      content: Self.content(revealed: revealed),
      moduleID: context.moduleID,
      // The arrow recalls the hidden icons: hiding it would make no sense.
      canHide: false,
      in: context.resources
    )
    surfaces = context.surfaces
    super.init()
    // Tsukumo's hidden icons follow the arrow; with the module off they go back to hidden.
    context.surfaces.setRevealsHidden(revealed)
    context.resources.add(.other) { [surfaces] in surfaces.setRevealsHidden(false) }
    surface.item?.button?.target = self
    surface.item?.button?.action = #selector(toggleReveal)
    surface.item?.button?.toolTip = String(localized: "Show or hide hidden icons")
  }

  @objc private func toggleReveal() {
    if !setRevealed(!defaults.bool(forKey: MenuBarPreferenceKeys.revealEnabled)) { NSSound.beep() }
  }

  /// When the module is turned off: the same step as the arrow, in reverse.
  /// If the third-party icons cannot be hidden again (Full Disk
  /// Access missing) the state stays "recalled", true to what is visible.
  func concealIfRevealed() {
    guard defaults.bool(forKey: MenuBarPreferenceKeys.revealEnabled) else { return }
    _ = setRevealed(false)
  }

  /// Shows or hides the hidden icons. `false` if it was not possible:
  /// in that case nothing changes.
  private func setRevealed(_ reveal: Bool) -> Bool {
    let hidden = Set(
      defaults.stringArray(forKey: MenuBarPreferenceKeys.hiddenApplications) ?? [])
    if !hidden.isEmpty {
      guard preferences.canAccessContainer else { return false }
      do { try preferences.setAllowed(reveal, for: hidden) } catch MenuBarPreferenceError.applicationNotRegistered {
        // None of the hidden apps is registered: system elements and
        // Tsukumo's icons must still follow the arrow.
      } catch {
        return false
      }
    }
    for item in MenuBarSystemItems.userHidden() { MenuBarSystemItems.setShown(reveal, item) }
    defaults.set(reveal, forKey: MenuBarPreferenceKeys.revealEnabled)
    surfaces.setRevealsHidden(reveal)
    surface.updateIfChanged(Self.content(revealed: reveal))
    return true
  }

  private static func content(revealed: Bool) -> StatusItemContent {
    StatusItemContent(
      symbol: revealed ? "chevron.right" : "chevron.left",
      accessibilityLabel: revealed
        ? String(localized: "Hide revealed icons")
        : String(localized: "Show hidden icons")
    )
  }
}
