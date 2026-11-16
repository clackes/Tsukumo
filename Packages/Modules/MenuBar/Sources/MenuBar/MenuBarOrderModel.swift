// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreFoundation
import Observation

/// Name and symbol of the system icons, from the identifier that Control
/// Center gives to each one (`com.apple.menuextra.<name>`).
enum SystemItemNames {
  private static let prefix = "com.apple.menuextra."

  private static let known: [String: (title: String.LocalizationValue, symbol: String)] = [
    "wifi": ("Wi‑Fi", "wifi"),
    "bluetooth": ("Bluetooth", "b.circle.fill"),
    "battery": ("Battery", "battery.75percent"),
    "controlcenter": ("Control Center", "switch.2"),
    "sound": ("Sound", "speaker.wave.2.fill"),
    "now-playing": ("Now Playing", "play.circle"),
    "focusmode": ("Focus", "moon.fill"),
    "display": ("Schermo", "display"),
    "airplay": ("Duplicazione schermo", "airplayvideo"),
    "spotlight": ("Spotlight", "magnifyingglass"),
    "siri": ("Siri", "mic.fill"),
    "vpn": ("VPN", "shield.lefthalf.filled"),
    "airdrop": ("AirDrop", "airplayaudio"),
    "keyboardbrightness": ("Retroilluminazione tastiera", "light.max"),
  ]

  static func isClock(_ identifier: String?) -> Bool { identifier == prefix + "clock" }

  /// Name and symbol; for an icon we do not know, macOS's description applies.
  static func describe(identifier: String?, description: String?) -> (title: String, symbol: String) {
    let name = identifier.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
    if let name, let entry = known[name] { return (String(localized: entry.title), entry.symbol) }
    let title = [description, name].compactMap { $0 }.first { !$0.isEmpty }
    return (title ?? String(localized: "System item"), "circle.grid.2x2")
  }
}

/// Puts together what Accessibility reads and what we know:
/// system icon names, hidden icons, fixed clock.
enum MenuBarItemCatalog {
  struct Result: Equatable {
    var visible: [MenuBarItemSlot]
    var hidden: [MenuBarItemSlot]
  }

  /// - Parameter screens: screen frames in AX coordinates (origin at the top
  ///   left of the main screen). Empty: the bar is assumed at y = 0.
  static func compose(_ raw: [RawMenuBarItem], hiddenKeys: Set<String>, screens: [CGRect] = []) -> Result {
    var result = Result(visible: [], hidden: [])
    for item in raw.sorted(by: { $0.frame.minX < $1.frame.minX }) {
      // Outside the bar band (for example at the bottom of the screen) it is not
      // a menu bar icon. The band is measured from the top edge of the icon's
      // screen: with the bar on a lower monitor y does not start at 0.
      if item.frame.minY - screenTop(of: item.frame, screens: screens) > 60 { continue }
      if item.owner.isSystem {
        // The clock does not move; a system icon that is not there is not listed.
        if SystemItemNames.isClock(item.systemIdentifier) || !item.isOnBar { continue }
        let described = SystemItemNames.describe(
          identifier: item.systemIdentifier, description: item.systemDescription)
        result.visible.append(
          MenuBarItemSlot(
            id: "system:\(item.systemIdentifier ?? String(item.index))", title: described.title,
            bundleID: nil, symbol: described.symbol, frame: item.frame))
        continue
      }
      let slot = MenuBarItemSlot(
        id: "\(item.owner.bundleID ?? item.owner.executable ?? item.owner.name):\(item.index)",
        title: title(for: item), bundleID: item.owner.bundleID, symbol: nil, frame: item.frame)
      if item.isOnBar, item.owner.keys.isDisjoint(with: hiddenKeys) {
        result.visible.append(slot)
      } else {
        result.hidden.append(slot)
      }
    }
    return result
  }

  /// Top edge of the screen containing the icon's center (edges included).
  /// An icon outside every screen (bar auto-hidden, above the
  /// edge) belongs to the nearest screen in its column.
  static func screenTop(of frame: CGRect, screens: [CGRect]) -> CGFloat {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    func inside(_ screen: CGRect) -> Bool {
      center.x >= screen.minX && center.x <= screen.maxX && center.y >= screen.minY && center.y <= screen.maxY
    }
    if let screen = screens.first(where: inside) { return screen.minY }
    let column = screens.filter { center.x >= $0.minX && center.x <= $0.maxX }
    let nearest = (column.isEmpty ? screens : column).min { lhs, rhs in
      abs(lhs.minY - center.y) < abs(rhs.minY - center.y)
    }
    return nearest?.minY ?? 0
  }

  private static func title(for item: RawMenuBarItem) -> String {
    let name = displayName(of: item.owner)
    // Labels often carry changing values ("Monitor, CPU 15%…"): the name stays.
    guard let label = item.label?.components(separatedBy: ", ").first, !label.isEmpty, label != name
    else { return name }
    return "\(name): \(label)"
  }

  /// Processes without a bundle take the name of the folder in Applications
  /// (".../Applications/PaperCut Print Deploy Client/v…/usercontextservice").
  static func displayName(of owner: MenuBarOwner) -> String {
    guard owner.bundleID == nil, let executable = owner.executable, let url = URL(string: executable) else {
      return owner.name
    }
    let parts = url.pathComponents
    guard let index = parts.firstIndex(of: "Applications"), parts.indices.contains(index + 2) else {
      return owner.name
    }
    return parts[index + 1]
  }

  /// Expected order after moving `from` to `to`.
  static func expectedOrder(_ ids: [String], from: Int, to: Int) -> [String] {
    var order = ids
    let moved = order.remove(at: from)
    order.insert(moved, at: to)
    return order
  }
}

/// State of the "Icon order" section. It exists only with the module on and
/// works only when the Settings page is open.
@MainActor
@Observable
final class MenuBarOrderModel {
  private(set) var items: [MenuBarItemSlot] = []
  private(set) var hiddenItems: [MenuBarItemSlot] = []
  private(set) var hasAccessibility = false
  private(set) var isMoving = false
  private(set) var message: String?

  func refresh() async {
    hasAccessibility = AXIsProcessTrusted()
    guard hasAccessibility else {
      items = []
      hiddenItems = []
      return
    }
    let running = NSWorkspace.shared.runningApplications
    // Screens in AX coordinates, read here on the MainActor.
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let screens = NSScreen.screens.map {
      CGRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
    }
    // Name, executable and Accessibility are read off the main thread.
    let result = await Task.detached(priority: .userInitiated) {
      let processes = running.map {
        MenuBarOwner(
          pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
          name: $0.localizedName ?? $0.bundleIdentifier ?? "?", executable: $0.executableURL?.absoluteString)
      }
      // The real state of the native switches applies (needs Full Disk
      // Access); without it, the list Tsukumo saved when it turned them off.
      let hiddenKeys: Set<String>
      if let states = try? MenuBarPreferences.readStates() {
        hiddenKeys = Set(states.filter { !$0.value }.keys)
      } else {
        hiddenKeys = Set(UserDefaults.standard.stringArray(forKey: MenuBarPreferenceKeys.hiddenApplications) ?? [])
      }
      return MenuBarItemCatalog.compose(
        MenuBarItemReader.read(processes: processes), hiddenKeys: hiddenKeys, screens: screens)
    }.value
    items = result.visible
    hiddenItems = result.hidden
  }

  /// `offset` -1 moves left, +1 right.
  func move(_ id: String, by offset: Int) async {
    guard !isMoving else { return }
    isMoving = true
    defer { isMoving = false }
    // Positions are re-read right before the gesture: those in memory
    // may be stale (an icon appeared, the text of one got wider).
    await refresh()
    guard let from = items.firstIndex(where: { $0.id == id }) else { return }
    let to = from + offset
    guard let drop = MenuBarMovePlanner.dropPoint(from: from, to: to, frames: items.map(\.frame)) else { return }
    let frame = items[from].frame
    let expected = MenuBarItemCatalog.expectedOrder(items.map(\.id), from: from, to: to)
    guard await MenuBarItemMover.drag(from: CGPoint(x: frame.midX, y: frame.midY), to: drop) else {
      message = String(localized: "To move icons, Tsukumo needs Accessibility access.")
      return
    }
    await refreshUntilSettled(expecting: expected)
    let actual = items.map(\.id)
    if actual == expected {
      message = nil
    } else if items.firstIndex(where: { $0.id == id }) == to {
      // It happens with Tsukumo's own icons: if one is moved, another can jump.
      message = String(localized: "The icon is in place, but another one moved. Check the list.")
    } else {
      message = String(localized: "macOS didn't move the icon. You can do it by hand by holding ⌘ and dragging.")
    }
  }

  /// The bar rearranges with an animation: it is re-read until the order is
  /// the expected one or two consecutive reads match (at most ~1.2 s).
  private func refreshUntilSettled(expecting expected: [String]) async {
    var previous: [CGRect] = []
    for _ in 0..<8 {
      try? await Task.sleep(for: .milliseconds(150))
      await refresh()
      let frames = items.map(\.frame)
      if items.map(\.id) == expected, frames == previous { return }
      if frames == previous, !previous.isEmpty { return }
      previous = frames
    }
  }
}
