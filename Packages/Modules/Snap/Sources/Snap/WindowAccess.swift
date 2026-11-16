// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import PrivateBridges

/// Window of another app, reached with Accessibility.
@MainActor
struct TargetWindow {
  /// A blocked app must not stop Tsukumo's main thread: every AX element
  /// has its own timeout (it is not inherited from the app's).
  static let messagingTimeout: Float = 0.25

  let application: AXUIElement
  let element: AXUIElement

  /// Window with the focus of the frontmost app.
  static func focused() -> TargetWindow? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, messagingTimeout)
    guard let window = element(application, kAXFocusedWindowAttribute) else { return nil }
    return TargetWindow(application: application, element: window)
  }

  /// Window under a point (AX coordinates): the one being dragged,
  /// even if it is not the frontmost app's (⌘-drag).
  static func at(_ point: CGPoint) -> TargetWindow? {
    let systemWide = AXUIElementCreateSystemWide()
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
      let hit
    else { return nil }
    AXUIElementSetMessagingTimeout(hit, messagingTimeout)
    let window: AXUIElement
    if string(hit, kAXRoleAttribute) == kAXWindowRole {
      window = hit
    } else if let parent = element(hit, kAXWindowAttribute) {
      window = parent
    } else {
      return nil
    }
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success, pid != getpid() else { return nil }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, messagingTimeout)
    return TargetWindow(application: application, element: window)
  }

  /// Attribute that is an AX element, with the short timeout already set.
  private static func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    let result = unsafeDowncast(value, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(result, messagingTimeout)
    return result
  }

  private static func string(_ source: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  /// Frame in AX coordinates (origin at the top left of the main screen).
  var frame: CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
      let position, let size,
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
      AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
      AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
    else { return nil }
    return CGRect(origin: origin, size: extent)
  }

  /// Native full screen: there the window does not move.
  var isFullScreen: Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success else { return false }
    return (value as? Bool) ?? false
  }

  /// WindowServer identifier, through the only private API allowed for
  /// Snap (DESIGN.md §2.2), in `PrivateBridges`. Without the symbol restore
  /// is not available.
  var windowID: CGWindowID? {
    AccessibilityBridge.windowID(of: element)
  }

  /// Moves and resizes. Size, position and size again: so
  /// the move to a smaller or larger screen is not truncated.
  func setFrame(_ frame: CGRect) {
    // With AXEnhancedUserInterface active (VoiceOver and similar) windows
    // move animated and jerkily: we turn it off for the duration of the operation.
    var enhanced: CFTypeRef?
    let enhancedKey = "AXEnhancedUserInterface" as CFString
    let wasEnhanced =
      AXUIElementCopyAttributeValue(application, enhancedKey, &enhanced) == .success && (enhanced as? Bool) == true
    if wasEnhanced { AXUIElementSetAttributeValue(application, enhancedKey, kCFBooleanFalse) }
    defer { if wasEnhanced { AXUIElementSetAttributeValue(application, enhancedKey, kCFBooleanTrue) } }

    var origin = frame.origin
    var extent = frame.size
    guard
      let position = AXValueCreate(.cgPoint, &origin), let size = AXValueCreate(.cgSize, &extent)
    else { return }
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, size)
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, size)
  }
}

/// Conversions between AppKit coordinates (origin at the bottom) and AX ones.
@MainActor
enum ScreenSpace {
  static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

  static func flipped(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  static func flipped(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: primaryHeight - point.y)
  }

  /// Screen containing the point (AX coordinates), or the main one. Edges
  /// included, like `NSMouseInRect`: the pointer on the bottom edge (in AX
  /// `maxY`) is still on that screen, while `CGRect.contains` would exclude it.
  static func screen(containing point: CGPoint) -> NSScreen? {
    NSScreen.screens.first { contains(flipped($0.frame), point) } ?? NSScreen.main
  }

  /// Containment with all four edges included.
  nonisolated static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
    point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
  }
}
