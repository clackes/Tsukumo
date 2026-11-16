// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI
import Switcher

/// Tsukumo's item in the menu bar. The panel is built only when
/// opened: with the panel closed nothing runs.
@MainActor
final class StatusItemController: NSObject {
  private let model: AppModel
  private let openSettings: () -> Void
  private let item: NSStatusItem
  /// Releases the icon from the Menu Bar module's "hide" management.
  private var release: (@MainActor () -> Void)?
  private var popover: StatusPopover?

  init(model: AppModel, isVisible: Bool, openSettings: @escaping () -> Void) {
    self.model = model
    self.openSettings = openSettings
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.isVisible = false
    super.init()

    item.autosaveName = "tsukumo.main"
    if let button = item.button {
      button.image = Self.menuBarIcon()
      popover = StatusPopover(button: button) { [weak self] in
        guard let self else { return AnyView(EmptyView()) }
        return AnyView(
          StatusPopoverView(
            model: self.model,
            showsRestoreSwitcher: NativeSwitcherGuard.isDisabledByUs,
            openSettings: { [weak self] in
              self?.popover?.close()
              self?.openSettings()
            },
            restoreSwitcher: { [weak self] in
              self?.popover?.close()
              self?.restoreNativeSwitcher()
            }))
      }
    }
    setVisible(isVisible)
  }

  /// Ring and dot of the app icon, as a template: macOS
  /// tints it by itself for light bar, dark bar and pressed state. Drawn in
  /// code, no asset to load.
  static func menuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 3.25, dy: 3.25))
      ring.lineWidth = 1.7
      ring.stroke()
      NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.7, y: rect.midY - 1.7, width: 3.4, height: 3.4)).fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Tsukumo"
    return image
  }

  /// From General the icon can be disabled entirely. While shown it can still
  /// be hidden from the Menu Bar module, and then it comes back with the arrow.
  func setVisible(_ visible: Bool) {
    release?()
    release = nil
    guard visible else {
      item.isVisible = false
      return
    }
    release = model.registry.surfaces.adoptStatusItem(item, autosaveName: "tsukumo.main", title: "Tsukumo")
  }

  private func restoreNativeSwitcher() {
    // With the module on, it goes through the module, which returns to ⌥⇥ and stops using ⌘⇥;
    // with the module off, it is enough to re-enable the system ⌘⇥.
    if let switcher = model.registry.module(SwitcherModule.descriptor.id) as? SwitcherModule {
      switcher.restoreSystemCommandTab()
    } else {
      NativeSwitcherGuard.enableNative()
    }
  }
}
