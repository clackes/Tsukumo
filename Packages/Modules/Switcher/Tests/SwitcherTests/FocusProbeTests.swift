// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import Testing

@testable import Switcher

/// Manual probe, off by default: lists the windows as the
/// switcher sees them and, if requested, brings one to the front.
///
///     TSUKUMO_SWITCHER_PROBE=list swift test --filter FocusProbe
///     TSUKUMO_SWITCHER_PROBE=<id finestra> swift test --filter FocusProbe
///
/// Accessibility is needed for the terminal that launches the tests.
@Suite struct FocusProbeTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TSUKUMO_SWITCHER_PROBE"] != nil))
  @MainActor func probe() async throws {
    let request = ProcessInfo.processInfo.environment["TSUKUMO_SWITCHER_PROBE"] ?? "list"
    let windows = WindowCatalog.load(excluding: ProcessInfo.processInfo.processIdentifier)
    for window in windows {
      let state = "visibile=\(window.isOnScreen) min=\(window.isMinimized)"
      print("window \(window.id) \(window.appName) \(state) \(window.title)")
    }
    guard let id = UInt32(request), let window = windows.first(where: { $0.id == id }) else { return }
    WindowFocuser.focus(window)
    try await Task.sleep(for: .seconds(1))
    let onScreen =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[CFString: Any]] ?? []
    let top = onScreen.first { ($0[kCGWindowLayer] as? Int) == 0 }
    print("frontmost: \(top?[kCGWindowNumber] as? Int ?? 0) \(top?[kCGWindowOwnerName] as? String ?? "")")
    #expect((top?[kCGWindowNumber] as? UInt32) == id)
  }
}
