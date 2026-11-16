// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Observation

/// Levels of Tsukumo's surfaces, from lowest to highest. It is the single
/// arbiter: no module picks an `NSWindow.Level` on its own, so Island, HUD
/// and Switcher do not cover each other (DESIGN.md §4.3, spike 9).
public enum SurfaceLevel: Int, Sendable, CaseIterable, Comparable {
  /// Snap preview while dragging.
  case preview
  /// Island: above the menu bar.
  case island
  /// Window Switcher.
  case switcher
  /// Volume and brightness HUD: always on top.
  case hud

  public var windowLevel: NSWindow.Level {
    switch self {
    case .preview: .modalPanel
    case .island: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    case .switcher: .popUpMenu
    case .hud: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    }
  }

  public static func < (lhs: SurfaceLevel, rhs: SurfaceLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// What a status item shows. It is `Equatable`: the item redraws only
/// when this value changes (DESIGN.md §5.2 rule 11).
public struct StatusItemContent: Sendable, Equatable {
  public var symbol: String?
  public var title: String?
  public var accessibilityLabel: String

  public init(symbol: String? = nil, title: String? = nil, accessibilityLabel: String) {
    self.symbol = symbol
    self.title = title
    self.accessibilityLabel = accessibilityLabel
  }
}

/// A module's menu bar item. It exists only between `start()` and `stop()`.
@MainActor
public final class StatusItemSurface {
  private let render: @MainActor (StatusItemContent) -> Void
  public private(set) var content: StatusItemContent?
  /// Number of actual redraws (for tests and diagnostics).
  public private(set) var renderCount = 0
  /// The system item; `nil` in tests that use a fake renderer.
  public let item: NSStatusItem?

  init(item: NSStatusItem?, render: @escaping @MainActor (StatusItemContent) -> Void) {
    self.item = item
    self.render = render
  }

  /// Redraws only if the displayed content has changed.
  /// - Returns: `true` if it redrew.
  @discardableResult
  public func updateIfChanged(_ new: StatusItemContent) -> Bool {
    guard new != content else { return false }
    content = new
    renderCount += 1
    render(new)
    return true
  }
}

/// Set of overlay windows, one per screen, kept aligned with the screens.
@MainActor
public final class OverlaySurface {
  public let level: SurfaceLevel
  private let acceptsMouse: Bool
  private let makeContent: @MainActor (NSScreen) -> NSView
  public private(set) var windows: [CGDirectDisplayID: NSWindow] = [:]

  init(level: SurfaceLevel, acceptsMouse: Bool, makeContent: @escaping @MainActor (NSScreen) -> NSView) {
    self.level = level
    self.acceptsMouse = acceptsMouse
    self.makeContent = makeContent
  }

  /// Creates windows for new screens, closes those of vanished screens
  /// and realigns the frame of the others.
  func reconcile(with screens: [NSScreen]) {
    let current = Dictionary(screens.compactMap { screen in screen.displayID.map { ($0, screen) } }) { first, _ in first
    }
    let plan = OverlayPlan(existing: Set(windows.keys), current: Set(current.keys))

    for id in plan.removed {
      windows.removeValue(forKey: id)?.close()
    }
    for id in plan.added {
      guard let screen = current[id] else { continue }
      windows[id] = makeWindow(for: screen)
    }
    for id in plan.kept {
      guard let screen = current[id], let window = windows[id], window.frame != screen.frame else { continue }
      window.setFrame(screen.frame, display: true)
    }
  }

  func closeAll() {
    for window in windows.values { window.close() }
    windows.removeAll()
  }

  private func makeWindow(for screen: NSScreen) -> NSWindow {
    let panel = NSPanel(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = level.windowLevel
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = !acceptsMouse
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = makeContent(screen)
    panel.setFrame(screen.frame, display: false)
    panel.orderFrontRegardless()
    return panel
  }
}

/// Difference between the screens that have a window and those connected now.
struct OverlayPlan: Equatable {
  let added: Set<CGDirectDisplayID>
  let removed: Set<CGDirectDisplayID>
  let kept: Set<CGDirectDisplayID>

  init(existing: Set<CGDirectDisplayID>, current: Set<CGDirectDisplayID>) {
    added = current.subtracting(existing)
    removed = existing.subtracting(current)
    kept = existing.intersection(current)
  }
}

/// Creates the modules' surfaces and registers them in their `ResourceBag`: when
/// the module is turned off, items and windows disappear with it. When idle it does not
/// observe anything; the screens observer exists only while there is an overlay.
@MainActor
@Observable
public final class SurfaceManager {
  /// A live status item, as Settings sees it.
  public struct StatusItemRecord: Identifiable, Sendable, Equatable {
    /// The item's autosave name: stable across launches.
    public let id: String
    public let moduleID: String?
    public let title: String
    /// The user's choice; with the recall arrow active the item is visible anyway.
    public var isVisible: Bool
    /// `false` for items it makes no sense to hide, like the arrow that recalls the others.
    public let canHide: Bool
  }

  static let hiddenItemsKey = "dev.local.tsukumo.statusItems.hidden"

  /// The status items of the modules that are on, in the order they were born.
  public private(set) var statusItems: [StatusItemRecord] = []
  /// `true` while the menu bar arrow is recalling the hidden icons.
  public private(set) var revealsHidden = false
  @ObservationIgnored private var liveItems: [String: NSStatusItem] = [:]
  @ObservationIgnored private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  private var hiddenItems: Set<String> {
    get { Set(defaults.stringArray(forKey: Self.hiddenItemsKey) ?? []) }
    set { defaults.set(newValue.sorted(), forKey: Self.hiddenItemsKey) }
  }

  /// The items of a module that the user can hide.
  public func statusItems(of moduleID: String) -> [StatusItemRecord] {
    statusItems.filter { $0.moduleID == moduleID && $0.canHide }
  }

  /// The choice also holds while off: at the next turn-on the item is born already hidden.
  public func isStatusItemVisible(_ autosaveName: String) -> Bool {
    !hiddenItems.contains(autosaveName)
  }

  /// Shows or hides an item without turning the module off: the module keeps working.
  public func setStatusItemVisible(_ visible: Bool, autosaveName: String) {
    var hidden = hiddenItems
    if visible { hidden.remove(autosaveName) } else { hidden.insert(autosaveName) }
    hiddenItems = hidden
    if let index = statusItems.firstIndex(where: { $0.id == autosaveName }) {
      statusItems[index].isVisible = visible
    }
    applyVisibility()
  }

  /// Recalls (or re-hides) the hidden Tsukumo icons, as the arrow does with those of other apps.
  public func setRevealsHidden(_ reveals: Bool) {
    guard revealsHidden != reveals else { return }
    revealsHidden = reveals
    applyVisibility()
  }

  /// Takes over an item created elsewhere (the app's main icon).
  /// The returned closure releases it without touching its visibility.
  public func adoptStatusItem(
    _ item: NSStatusItem, autosaveName: String, title: String
  ) -> @MainActor () -> Void {
    register(item, autosaveName: autosaveName, title: title, moduleID: nil, canHide: true)
    return { [weak self] in self?.forget(autosaveName) }
  }

  private func register(_ item: NSStatusItem, autosaveName: String, title: String, moduleID: String?, canHide: Bool) {
    liveItems[autosaveName] = item
    statusItems.removeAll { $0.id == autosaveName }
    statusItems.append(
      StatusItemRecord(
        id: autosaveName, moduleID: moduleID, title: title,
        isVisible: !canHide || isStatusItemVisible(autosaveName), canHide: canHide
      )
    )
    applyVisibility()
  }

  private func forget(_ autosaveName: String) {
    liveItems[autosaveName] = nil
    statusItems.removeAll { $0.id == autosaveName }
  }

  private func applyVisibility() {
    for record in statusItems {
      liveItems[record.id]?.isVisible = !record.canHide || record.isVisible || revealsHidden
    }
  }

  /// Menu bar item. Must be called only inside `start()` (§4.2, rule 4).
  public func makeStatusItem(
    autosaveName: String,
    content: StatusItemContent,
    menu: NSMenu? = nil,
    moduleID: String? = nil,
    canHide: Bool = true,
    in resources: ResourceBag
  ) -> StatusItemSurface {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = autosaveName
    item.menu = menu
    let surface = StatusItemSurface(item: item) { [weak item] content in
      guard let button = item?.button else { return }
      let image = content.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
      image?.isTemplate = true
      button.image = image
      button.title = content.title ?? ""
      button.imagePosition = content.title == nil ? .imageOnly : .imageLeading
      button.setAccessibilityLabel(content.accessibilityLabel)
    }
    surface.updateIfChanged(content)
    register(
      item, autosaveName: autosaveName, title: content.accessibilityLabel, moduleID: moduleID, canHide: canHide
    )
    resources.add(.statusItem) { [weak self] in
      // AppKit remembers visibility by name: we restore it to "visible" before
      // removing the item, so the choice stays only in our preferences.
      item.isVisible = true
      NSStatusBar.system.removeStatusItem(item)
      self?.forget(autosaveName)
    }
    return surface
  }

  /// Transparent overlay windows, one per screen, recomputed when the
  /// screen configuration changes.
  public func makeOverlay(
    level: SurfaceLevel,
    acceptsMouse: Bool = false,
    in resources: ResourceBag,
    content: @escaping @MainActor (NSScreen) -> NSView
  ) -> OverlaySurface {
    let overlay = OverlaySurface(level: level, acceptsMouse: acceptsMouse, makeContent: content)
    overlay.reconcile(with: NSScreen.screens)
    resources.add(.window) { overlay.closeAll() }
    resources.addObserver(NSApplication.didChangeScreenParametersNotification) { [weak overlay] in
      overlay?.reconcile(with: NSScreen.screens)
    }
    return overlay
  }
}

extension NSScreen {
  /// Stable identifier of the screen.
  public var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}
