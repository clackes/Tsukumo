// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import ApplicationServices
import CoreGraphics
import Foundation

/// Private Accessibility (HIServices) symbols used by the Switcher
/// (DESIGN.md §2.2, §4.4). As with SkyLight: if a symbol disappears the bridge
/// returns `nil` and the caller falls back to the public APIs.
public enum AccessibilityBridge {
  private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
  private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

  /// `RTLD_DEFAULT`: the symbols live in frameworks already loaded by the app.
  private static var rtldDefault: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }

  private static let getWindow: GetWindow? = dlsym(rtldDefault, "_AXUIElementGetWindow").map {
    unsafeBitCast($0, to: GetWindow.self)
  }

  private static let createWithRemoteToken: CreateWithRemoteToken? =
    dlsym(rtldDefault, "_AXUIElementCreateWithRemoteToken").map {
      unsafeBitCast($0, to: CreateWithRemoteToken.self)
    }

  /// WindowServer ID of an AX window.
  public static func windowID(of element: AXUIElement) -> CGWindowID? {
    guard let getWindow else { return nil }
    var id: CGWindowID = 0
    return getWindow(element, &id) == .success && id != 0 ? id : nil
  }

  /// AX windows of an app that `kAXWindowsAttribute` does not list: those in
  /// other Spaces and full-screen ones. Public Accessibility returns only the
  /// windows of the current Space; here the elements are built from their internal
  /// identifier (the first `limit`), keeping those that are windows.
  ///
  /// - Parameters:
  ///   - wanted: if not empty, stop as soon as all these windows are found.
  ///   - budget: maximum time, so we do not hang on an unresponsive app.
  public static func remoteWindows(
    of pid: pid_t, wanted: Set<CGWindowID> = [], limit: UInt64 = 1000, budget: TimeInterval = 0.12
  ) -> [CGWindowID: AXUIElement] {
    guard let createWithRemoteToken else { return [:] }
    var result: [CGWindowID: AXUIElement] = [:]
    let deadline = ProcessInfo.processInfo.systemUptime + budget
    // Token: pid (4 bytes), zero (4), "coco" signature (4), identifier (8).
    var token = Data(count: 20)
    withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
    withUnsafeBytes(of: Int32(0x636f_636f)) { token.replaceSubrange(8..<12, with: $0) }
    for elementID in 0..<limit {
      // On every iteration: a timing-out element costs up to 0.1 s, and 64 in a row
      // would blow the budget by several seconds.
      if ProcessInfo.processInfo.systemUptime > deadline { break }
      withUnsafeBytes(of: elementID) { token.replaceSubrange(12..<20, with: $0) }
      guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
      AXUIElementSetMessagingTimeout(element, 0.1)
      guard let id = windowID(of: element), result[id] == nil else { continue }
      var subrole: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
        let name = subrole as? String, name == kAXStandardWindowSubrole || name == kAXDialogSubrole
      else { continue }
      result[id] = element
      if !wanted.isEmpty, wanted.isSubset(of: result.keys) { break }
    }
    return result
  }
}
