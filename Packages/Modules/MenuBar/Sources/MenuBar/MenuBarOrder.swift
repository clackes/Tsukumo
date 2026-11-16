// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics

/// A menu bar icon as it is now on screen.
struct MenuBarItemSlot: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let bundleID: String?
  /// SF Symbol for system icons, which have no app to take the icon from.
  let symbol: String?
  /// Global coordinates with the origin at the top left, like AX and `CGEvent`.
  let frame: CGRect
}

/// Process that can have icons in the bar.
struct MenuBarOwner: Sendable {
  let pid: pid_t
  let bundleID: String?
  let name: String
  /// `file://` URL of the executable: identifies processes without a bundle (PaperCut).
  let executable: String?

  /// System icons are drawn by MenuBarAgent, with no name or identifier.
  var isSystem: Bool { bundleID == "com.apple.MenuBarAgent" }
  /// Keys by which the "hidden" preference can refer to this process.
  var keys: Set<String> { Set([bundleID, executable].compactMap(\.self)) }
}

/// An element as Accessibility returns it, before giving it a name.
struct RawMenuBarItem: Sendable {
  let owner: MenuBarOwner
  let index: Int
  let label: String?
  let frame: CGRect
  /// Only for system icons: `com.apple.menuextra.<name>`, read from the element's
  /// child (the element itself is a container without a name).
  var systemIdentifier: String?
  /// Localized description of the system icon, for the ones we do not know.
  var systemDescription: String?
  /// `false` if something else is at that spot in the bar: Accessibility keeps
  /// listing, with the last known position, even the icons macOS does not show
  /// (hidden by the system switches or without room). Counting them as
  /// visible skews the positions and sends moves to the wrong icon.
  var isOnBar = true
}

/// Reads the icons from the bar with Accessibility. On macOS 27 the bar is
/// drawn by `MenuBarAgent` and there is no longer a window per icon, so the
/// positions come from each app's `AXExtrasMenuBar`. It is read only when the
/// Settings page asks for it: no observers, no polling.
enum MenuBarItemReader {
  private static let timeout: Float = 0.25

  static func read(processes: [MenuBarOwner]) -> [RawMenuBarItem] {
    var items: [RawMenuBarItem] = []
    for process in processes {
      let app = AXUIElementCreateApplication(process.pid)
      // A hung app must not block the page. The timeout is not inherited:
      // it must be set on every element read.
      AXUIElementSetMessagingTimeout(app, timeout)
      guard let bar: AXUIElement = attribute(app, "AXExtrasMenuBar") else { continue }
      AXUIElementSetMessagingTimeout(bar, timeout)
      guard let children: [AXUIElement] = attribute(bar, kAXChildrenAttribute) else { continue }
      for (index, child) in children.enumerated() {
        AXUIElementSetMessagingTimeout(child, timeout)
        guard let frame = frame(of: child), frame.width > 0, frame.height > 0 else { continue }
        let description: String? = attribute(child, kAXDescriptionAttribute)
        let title: String? = attribute(child, kAXTitleAttribute)
        let label = [description, title].compactMap { $0 }.first { !$0.isEmpty }
        var item = RawMenuBarItem(owner: process, index: index, label: label, frame: frame)
        item.isOnBar = isOnBar(frame, owner: process.pid)
        if process.isSystem, let kids: [AXUIElement] = attribute(child, kAXChildrenAttribute), let inner = kids.first {
          AXUIElementSetMessagingTimeout(inner, timeout)
          item.systemIdentifier = attribute(inner, kAXIdentifierAttribute)
          let text: NSAttributedString? = attribute(inner, "AXAttributedDescription")
          item.systemDescription = text?.string
        }
        items.append(item)
      }
    }
    return items
  }

  /// Asks the system what is at the center of the icon: if an icon
  /// of the same process answers, it is really there.
  private static func isOnBar(_ frame: CGRect, owner: pid_t) -> Bool {
    var hit: AXUIElement?
    let systemWide = AXUIElementCreateSystemWide()
    guard
      AXUIElementCopyElementAtPosition(systemWide, Float(frame.midX), Float(frame.midY), &hit) == .success,
      let hit
    else { return false }
    AXUIElementSetMessagingTimeout(hit, timeout)
    var pid: pid_t = 0
    guard AXUIElementGetPid(hit, &pid) == .success, pid == owner else { return false }
    // Several icons of the same process: it must be exactly this one.
    guard let hitFrame = self.frame(of: hit) else { return true }
    return abs(hitFrame.midX - frame.midX) < 2
  }

  private static func frame(of element: AXUIElement) -> CGRect? {
    guard let position: AXValue = attribute(element, kAXPositionAttribute),
      let size: AXValue = attribute(element, kAXSizeAttribute)
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
  }

  private static func attribute<Value>(_ element: AXUIElement, _ name: String) -> Value? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? Value
  }
}

/// Where to drop an icon so that it ends up in the right place.
enum MenuBarMovePlanner {
  /// Drop point to bring the icon `from` to position `to` (left-to-right
  /// order). Going left it is dropped on the left edge of the icon occupying that
  /// place, going right on its right edge.
  static func dropPoint(from: Int, to: Int, frames: [CGRect]) -> CGPoint? {
    guard frames.indices.contains(from), frames.indices.contains(to), from != to else { return nil }
    let target = frames[to]
    let edge = to < from ? target.minX + 2 : target.maxX - 2
    return CGPoint(x: edge, y: target.midY)
  }
}

/// Moves an icon the way the user would: ⌘ held and dragging.
@MainActor
enum MenuBarItemMover {
  /// Requires Accessibility to send events. The pointer returns to where it was.
  static func drag(from start: CGPoint, to end: CGPoint) async -> Bool {
    guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { return false }
    let saved = CGEvent(source: nil)?.location
    // For the duration of the gesture the real mouse does not move the pointer: a small
    // user movement in the middle of the drag would carry the icon elsewhere (or
    // out of the bar, i.e. remove it).
    CGAssociateMouseAndMouseCursorPosition(0)
    defer {
      if let saved { CGWarpMouseCursorPosition(saved) }
      CGAssociateMouseAndMouseCursorPosition(1)
    }
    func post(_ type: CGEventType, at point: CGPoint) {
      let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
      event?.flags = .maskCommand
      event?.setIntegerValueField(.mouseEventClickState, value: 1)
      event?.post(tap: .cghidEventTap)
    }
    post(.mouseMoved, at: start)
    try? await Task.sleep(for: .milliseconds(30))
    post(.leftMouseDown, at: start)
    try? await Task.sleep(for: .milliseconds(60))
    // The first stretch is short: macOS recognizes the drag only after
    // a few points of movement, then the icon follows the pointer.
    let steps = 14
    for step in 1...steps {
      let progress = CGFloat(step) / CGFloat(steps)
      let eased = progress * progress * (3 - 2 * progress)
      post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y))
      try? await Task.sleep(for: .milliseconds(12))
    }
    // Hold at the destination point until the bar has made room for the icon.
    post(.leftMouseDragged, at: CGPoint(x: end.x, y: start.y))
    try? await Task.sleep(for: .milliseconds(120))
    post(.leftMouseUp, at: CGPoint(x: end.x, y: start.y))
    try? await Task.sleep(for: .milliseconds(30))
    return true
  }
}
