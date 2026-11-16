// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Entry point. LSUIElement app based on `NSStatusItem`: no
/// `MenuBarExtra` nor `Settings` scene (DESIGN.md §3.1).
@main
enum TsukumoApp {
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
  }
}
