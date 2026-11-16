// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-FileCopyrightText: 2026 fx-xf
// SPDX-License-Identifier: GPL-3.0-only
//
// Adapted from fx-xf/duo (MIT), see THIRD-PARTY-NOTICES.md.

import AppKit
import MetalKit

/// Full-screen window, transparent to clicks, in which the bent screen is drawn.
@MainActor
final class OverlayController {
  let renderer: BendRenderer
  private let window: NSWindow
  private let view: MTKView
  private(set) var isVisible = false

  init?(screen: NSScreen) {
    guard let device = MTLCreateSystemDefaultDevice(), let renderer = BendRenderer(device: device) else {
      return nil
    }
    self.renderer = renderer

    let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer.device)
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.isPaused = true
    view.enableSetNeedsDisplay = false
    view.presentsWithTransaction = true
    view.clearColor = MTLClearColorMake(0, 0, 0, 0)
    view.delegate = renderer
    if let layer = view.layer as? CAMetalLayer {
      layer.isOpaque = false
      layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
      layer.displaySyncEnabled = true
    }
    self.view = view

    let window = NSWindow(
      contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
    window.contentView = view
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    window.sharingType = .none
    window.displaysWhenScreenProfileChanges = true
    self.window = window

    let perMillimetre = Self.pixelsPerMillimetre(of: screen)
    renderer.pixelsPerMillimetre = perMillimetre
    // Notched panels round the top corners by ~2.2 mm; there is no API,
    // the radius comes from the physical size. Square panels: no radius.
    renderer.cornerRadius = screen.safeAreaInsets.top > 0 ? 2.2 * perMillimetre : 0
  }

  var pixelSize: CGSize {
    let scale = window.screen?.backingScaleFactor ?? 2
    return CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
  }

  var displayID: CGDirectDisplayID { window.screen?.displayID ?? CGMainDisplayID() }
  var windowID: CGWindowID { CGWindowID(window.windowNumber) }

  /// Draws and only then brings the window to the front, in the same transaction:
  /// the first composited frame is already the right one.
  func render(_ params: BendParams) {
    guard renderer.hasFrame else { return }
    renderer.params = params
    view.draw()
    if !isVisible {
      isVisible = true
      // Reset and restore: AppKit skips the restore if the value does not change.
      let behavior = window.collectionBehavior
      window.collectionBehavior = []
      window.collectionBehavior = behavior
      window.orderFrontRegardless()
    }
  }

  /// Leaves a transparent frame before disappearing, so the next first frame is invisible.
  func hide() {
    guard isVisible else { return }
    isVisible = false
    renderer.params.tilt = 0
    view.draw()
    window.orderOut(nil)
  }

  /// Removes the window without trusting internal state: the last safety net.
  func forceHide() {
    isVisible = false
    renderer.params.tilt = 0
    window.orderOut(nil)
  }

  func close() {
    isVisible = false
    window.orderOut(nil)
    window.contentView = nil
  }

  private static func pixelsPerMillimetre(of screen: NSScreen) -> Double {
    let millimetres = CGDisplayScreenSize(screen.displayID).width
    guard millimetres > 0 else { return 10 }
    return Double(screen.frame.width * screen.backingScaleFactor) / millimetres
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }

  static var builtIn: NSScreen? {
    // No fallback to an external monitor: with the lid closed (clamshell) the
    // built-in display goes away and the sensor must no longer be read.
    screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
  }
}
