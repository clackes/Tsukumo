// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Control Center elements that macOS can show in the menu bar.
enum MenuBarSystemItem: String, CaseIterable, Identifiable, Sendable {
  case wifi = "WiFi"
  case bluetooth = "Bluetooth"
  case focus = "FocusModes"
  case sound = "Sound"
  case nowPlaying = "NowPlaying"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .wifi: "wifi"
    case .bluetooth: "b.circle.fill"
    case .focus: "moon.fill"
    case .sound: "speaker.wave.2.fill"
    case .nowPlaying: "play.circle"
    }
  }

  /// Without a saved preference macOS shows only Wi‑Fi.
  var shownByDefault: Bool { self == .wifi }
}

/// Same preference that System Settings writes (Control Center
/// domain, per host): 8 hides the element, 2 shows it. Control Center
/// re-reads it by itself, without restarts. Verified on macOS 27.0.1.
enum MenuBarSystemItems {
  private static var domain: CFString { "com.apple.controlcenter" as CFString }
  private static let hiddenValue = 8
  private static let shownValue = 2

  static func isShown(_ item: MenuBarSystemItem) -> Bool {
    let value = CFPreferencesCopyValue(
      item.rawValue as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    guard let number = value as? Int else { return item.shownByDefault }
    return isShown(value: number)
  }

  /// 2 and 18 are the "show" variants; 8 and 24 the "don't show" ones.
  static func isShown(value: Int) -> Bool { value & 0b1000 == 0 }

  /// Changes only bits 2/8 ("show"/"don't show") and keeps the others, for
  /// example the 16 of "also show in Control Center" (18 ↔ 24).
  static func value(shown: Bool, current: Int?) -> Int {
    ((current ?? 0) & ~(shownValue | hiddenValue)) | (shown ? shownValue : hiddenValue)
  }

  static func setShown(_ shown: Bool, _ item: MenuBarSystemItem) {
    let current =
      CFPreferencesCopyValue(
        item.rawValue as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
    CFPreferencesSetValue(
      item.rawValue as CFString, value(shown: shown, current: current) as CFNumber, domain,
      kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
  }

  // MARK: Elements hidden by the user through Tsukumo

  private static let hiddenKey = "menuBar.hiddenSystemItems"

  /// Those the user turned off here: the arrow shows and hides them again.
  static func userHidden(in defaults: UserDefaults = .standard) -> Set<MenuBarSystemItem> {
    // First time: Wi‑Fi and Bluetooth are visible by default, so if they are
    // hidden it was a user choice and the arrow must be able to recall them.
    if defaults.object(forKey: hiddenKey) == nil {
      setUserHidden(Set([MenuBarSystemItem.wifi, .bluetooth].filter { !isShown($0) }), in: defaults)
    }
    return Set((defaults.stringArray(forKey: hiddenKey) ?? []).compactMap(MenuBarSystemItem.init(rawValue:)))
  }

  static func setUserHidden(_ items: Set<MenuBarSystemItem>, in defaults: UserDefaults = .standard) {
    defaults.set(items.map(\.rawValue).sorted(), forKey: hiddenKey)
  }
}
