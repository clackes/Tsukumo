// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import PrivateBridges
import Synchronization

/// A window listed by the switcher.
struct SwitcherWindow: Identifiable, Equatable, Sendable {
  let id: CGWindowID
  let pid: pid_t
  let appName: String
  let title: String
  let isMinimized: Bool
  let isOnScreen: Bool
}

/// List of windows without Screen Recording: metadata from
/// `CGWindowListCopyWindowInfo` (depth order, from the front), titles and
/// minimized state from Accessibility (DESIGN.md §2.2).
enum WindowCatalog {
  /// Normal windows of regular apps, the frontmost first.
  /// Runs off the main thread: AX calls have a short timeout.
  static func load(excluding ownPID: pid_t) -> [SwitcherWindow] {
    // Visible windows in depth order (from the front), then the others
    // (minimized, hidden, other Spaces): `.optionAll` alone does not respect the order.
    let onScreen =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[CFString: Any]] ?? []
    let all =
      CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
    let visibleIDs = Set(onScreen.compactMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value })
    let info = onScreen + all.filter { !visibleIDs.contains(($0[kCGWindowNumber] as? NSNumber)?.uint32Value ?? 0) }
    let apps = regularApplications()
    let offScreen = offScreenWindows(in: info)
    let axCache = axWindows(ofAll: candidatePIDs(in: info, apps: apps, excluding: ownPID), offScreen: offScreen)
    var result: [SwitcherWindow] = []
    for entry in info {
      guard let raw = entry[kCGWindowNumber] as? NSNumber, let pidNumber = entry[kCGWindowOwnerPID] as? NSNumber,
        (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0
      else { continue }
      let pid = pid_t(pidNumber.int32Value)
      guard pid != ownPID, let appName = apps[pid] else { continue }
      if let alpha = entry[kCGWindowAlpha] as? NSNumber, alpha.doubleValue <= 0 { continue }
      let bounds = (entry[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
      guard bounds.width >= 60, bounds.height >= 40 else { continue }

      let id = CGWindowID(raw.uint32Value)
      let onScreen = (entry[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false
      let windows = axCache[pid] ?? [:]
      let ax = windows[id]
      // Off screen and unknown to AX even when searched in the other Spaces:
      // closed window but still in memory, or a service one. Skipped.
      if !onScreen, ax == nil { continue }
      // AX knows the app but not this window in the current Space: palettes, internal panels.
      if onScreen, ax == nil, !windows.isEmpty { continue }
      let cgTitle = (entry[kCGWindowName] as? String) ?? ""
      let title = ax?.title.isEmpty == false ? ax?.title ?? "" : cgTitle
      result.append(
        SwitcherWindow(
          id: id, pid: pid, appName: appName, title: title.isEmpty ? appName : title,
          isMinimized: ax?.isMinimized ?? false, isOnScreen: onScreen))
    }
    return result
  }

  private static func candidatePIDs(in info: [[CFString: Any]], apps: [pid_t: String], excluding ownPID: pid_t)
    -> [pid_t]
  {
    var seen = Set<pid_t>()
    for entry in info where (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0 {
      guard let pid = (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value, pid != ownPID, apps[pid] != nil
      else { continue }
      seen.insert(pid)
    }
    return seen.sorted()
  }

  /// Apps are queried in parallel: each answers (or times out) on its
  /// own, and a slow one does not lengthen the switcher's opening.
  private static func axWindows(ofAll pids: [pid_t], offScreen: [pid_t: Set<CGWindowID>]) -> [pid_t: [CGWindowID:
    AXInfo]]
  {
    let results = Mutex<[pid_t: [CGWindowID: AXInfo]]>([:])
    DispatchQueue.concurrentPerform(iterations: pids.count) { index in
      let pid = pids[index]
      let windows = axWindows(of: pid, offScreen: offScreen[pid] ?? [])
      results.withLock { $0[pid] = windows }
    }
    return results.withLock { $0 }
  }

  /// Off-screen windows per app: candidates to be in another Space.
  private static func offScreenWindows(in info: [[CFString: Any]]) -> [pid_t: Set<CGWindowID>] {
    var result: [pid_t: Set<CGWindowID>] = [:]
    for entry in info {
      guard (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0,
        (entry[kCGWindowIsOnscreen] as? NSNumber)?.boolValue != true,
        let raw = entry[kCGWindowNumber] as? NSNumber, let pid = entry[kCGWindowOwnerPID] as? NSNumber
      else { continue }
      result[pid_t(pid.int32Value), default: []].insert(CGWindowID(raw.uint32Value))
    }
    return result
  }

  private static func regularApplications() -> [pid_t: String] {
    var apps: [pid_t: String] = [:]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      apps[app.processIdentifier] = app.localizedName ?? app.bundleIdentifier ?? "?"
    }
    return apps
  }

  struct AXInfo: Sendable {
    let title: String
    let isMinimized: Bool
  }

  /// Standard AX windows of an app, by WindowServer ID. `kAXWindows`
  /// lists only the current Space: if the app has off-screen windows that do not
  /// appear there, they are also searched in the other Spaces.
  static func axWindows(of pid: pid_t, offScreen: Set<CGWindowID> = []) -> [CGWindowID: AXInfo] {
    var result: [CGWindowID: AXInfo] = [:]
    for (id, element) in AXWindow.elements(of: pid, timeout: 0.1) {
      result[id] = info(of: element)
    }
    let missing = offScreen.subtracting(result.keys)
    if !missing.isEmpty {
      for (id, element) in AccessibilityBridge.remoteWindows(of: pid) where result[id] == nil {
        result[id] = info(of: element)
      }
    }
    return result
  }

  private static func info(of element: AXUIElement) -> AXInfo {
    AXInfo(
      title: AXWindow.string(element, kAXTitleAttribute) ?? "",
      isMinimized: AXWindow.bool(element, kAXMinimizedAttribute))
  }
}

/// AX reads and actions on a window.
enum AXWindow {
  static func windowID(of element: AXUIElement) -> CGWindowID? {
    AccessibilityBridge.windowID(of: element)
  }

  static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
    return (value as? Bool) ?? false
  }

  /// Standard windows and dialogs of the current Space (and minimized).
  static func elements(of pid: pid_t, timeout: Float) -> [CGWindowID: AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, timeout)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let elements = value as? [AXUIElement]
    else { return [:] }
    var result: [CGWindowID: AXUIElement] = [:]
    for element in elements {
      // The app's timeout does not pass to the windows: without it, every read
      // might wait for the default ~6 s.
      AXUIElementSetMessagingTimeout(element, timeout)
      guard let id = windowID(of: element) else { continue }
      let subrole = string(element, kAXSubroleAttribute)
      guard subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
      result[id] = element
    }
    return result
  }

  /// The window's AX element, even if it is in another Space.
  static func element(for window: SwitcherWindow) -> AXUIElement? {
    if let element = elements(of: window.pid, timeout: 0.2)[window.id] { return element }
    return AccessibilityBridge.remoteWindows(of: window.pid, wanted: [window.id])[window.id]
  }
}

/// Brings a window to the front, even in another Space.
enum WindowFocuser {
  /// AX calls (short timeouts, but a blocked app uses them all) and
  /// SkyLight run off the MainActor; only the AppKit fallback comes back to it.
  static func focus(_ window: SwitcherWindow) {
    Task.detached(priority: .userInitiated) {
      guard raise(window) else { return }
      await activate(pid: window.pid)
    }
  }

  /// `_SLPSSetFrontProcessWithOptions` brings the app and the window's Space to the
  /// front (DESIGN.md §4.4); then AX raises the right window among those
  /// of the app. Access to the symbol lives in `PrivateBridges.SkyLightBridge`.
  /// `true` if the `NSRunningApplication` fallback is needed.
  static func raise(_ window: SwitcherWindow) -> Bool {
    let element = AXWindow.element(for: window)
    // A minimized window must first be brought back out of the Dock.
    if let element, window.isMinimized {
      AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    let fronted = SkyLightBridge.setFrontProcess(pid: window.pid, window: window.id)
    if let element {
      AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
      AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
    return !fronted || element == nil
  }

  /// Fallback: `activate()` from a background app is ignored by macOS,
  /// while reopening the app really brings it to the front (like a click in the Dock).
  @MainActor
  private static func activate(pid: pid_t) {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return }
    if let url = app.bundleURL {
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    } else {
      app.activate(options: [.activateAllWindows])
    }
  }
}
