// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import SwiftUI

/// Settings window. It exists only while open: on close it is
/// released together with the whole SwiftUI hierarchy.
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private let window: NSWindow
  private let onClose: () -> Void

  init(model: AppModel, onClose: @escaping () -> Void) {
    self.onClose = onClose
    let hosting = NSHostingController(rootView: SettingsView(model: model))
    window = NSWindow(contentViewController: hosting)
    super.init()

    window.title = String(localized: "Tsukumo Settings")
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.setContentSize(
      NSSize(width: TsukumoTokens.Size.settingsMinWidth + 80, height: TsukumoTokens.Size.settingsMinHeight + 60)
    )
    window.contentMinSize = NSSize(
      width: TsukumoTokens.Size.settingsMinWidth, height: TsukumoTokens.Size.settingsMinHeight
    )
    window.center()
    window.setFrameAutosaveName("tsukumo.settings")
    window.delegate = self
  }

  func show() {
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    window.delegate = nil
    window.contentViewController = nil
    onClose()
  }
}
