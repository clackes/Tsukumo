// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Onboarding with **zero permissions at launch** (DESIGN.md §6.1): three presets and
/// the "Customize" option. The choice turns on the indicated modules; permissions
/// are still to be requested at the first action that uses them.
public struct ModulePreset: Identifiable, Sendable, Equatable {
  public let id: String
  /// Name shown in the card.
  public let title: String
  /// Short description under the title.
  public let detail: String
  /// IDs of the modules to turn on.
  public let moduleIDs: [String]
  /// SF Symbol of the badge.
  public let symbol: String

  public init(id: String, title: String, detail: String, moduleIDs: [String], symbol: String) {
    self.id = id
    self.title = title
    self.detail = detail
    self.moduleIDs = moduleIDs
    self.symbol = symbol
  }
}

public enum OnboardingPresets {
  /// "Essenziale" (DESIGN §6.1): Island, Snap, Monitor.
  public static let essenziale = ModulePreset(
    id: "essenziale",
    title: "Essenziale",
    detail: "Dynamic Island, window snapping with Snap, and ambient info from Monitor.",
    moduleIDs: ["island", "snap", "monitor"],
    symbol: "sparkles")
  /// "Power user": all the base modules + Switcher, Clack, MenuBar, Sound.
  public static let powerUser = ModulePreset(
    id: "powerUser",
    title: "Power user",
    detail: "Everything essential plus Switcher, Clack, menu bar tools and the Sound mixer.",
    moduleIDs: ["island", "snap", "monitor", "menu-bar", "clack", "switcher", "sound"],
    symbol: "bolt.fill")
  /// "Personalizza": no module preselected; the user chooses from the panel.
  public static let personalizza = ModulePreset(
    id: "personalizza",
    title: "Personalizza",
    detail: "Nothing turned on: choose module by module in Settings.",
    moduleIDs: [],
    symbol: "slider.horizontal.3")

  public static let all: [ModulePreset] = [essenziale, powerUser, personalizza]
}

/// Persisted onboarding state: done / not done + version, so a
/// future revision of the onboarding can present it again surgically.
public struct OnboardingState: Codable, Equatable, Sendable {
  /// Current onboarding version; changes when the content of the
  /// screens is different enough to deserve showing it again.
  public static let currentVersion = 1

  public var completedVersion: Int
  public var chosenPresetID: String?

  public init(completedVersion: Int = 0, chosenPresetID: String? = nil) {
    self.completedVersion = completedVersion
    self.chosenPresetID = chosenPresetID
  }

  public var shouldShow: Bool { completedVersion < Self.currentVersion }

  public mutating func markCompleted(presetID: String?) {
    completedVersion = Self.currentVersion
    chosenPresetID = presetID
  }
}

/// Minimal persistence of the onboarding state: single key in UserDefaults,
/// with no dependency on external Codable.
@MainActor
public final class OnboardingStore {
  public static let defaultsKey = "onboardingState"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> OnboardingState {
    guard let data = defaults.data(forKey: Self.defaultsKey),
      let decoded = try? JSONDecoder().decode(OnboardingState.self, from: data)
    else { return OnboardingState() }
    return decoded
  }

  public func save(_ state: OnboardingState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }
}
