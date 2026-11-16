// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit

/// Snapping by dragging a window to the screen edges.
///
/// At rest only a click monitor exists (event-driven). The drag monitor
/// and the preview live only between mouseDown and mouseUp (DESIGN.md §2.2);
/// if after the first events the window under the click has not moved (selected
/// text, slider, dragged files) the drag monitor is removed
/// for the rest of the gesture.
@MainActor
final class SnapDragController {
  /// Drag events after the initial read before deciding.
  static let decisionEvents = 5
  /// Time since mouseDown after which a decision is made anyway (with at least two events).
  static let decisionDelay: TimeInterval = 0.15

  private let resources: ResourceBag
  /// Action, window, usable area of the preview's screen, frame before the drag.
  private let onSnap: (SnapAction, TargetWindow, CGRect, CGRect) -> Void
  private var downToken: ResourceBag.Token?
  private var dragToken: ResourceBag.Token?
  private var previewToken: ResourceBag.Token?
  private var preview: NSPanel?
  private var previewTarget: CGRect?

  /// State of a single drag.
  private var downPoint: CGPoint?
  private var downTime: TimeInterval = 0
  private var window: TargetWindow?
  private var initialFrame: CGRect?
  private var didProbe = false
  private var eventsSinceProbe = 0
  private var isWindowDrag = false
  private var pending: SnapAction?
  /// Usable area (AX coordinates) of the screen on which the preview is shown.
  private var pendingArea: CGRect?

  init(resources: ResourceBag, onSnap: @escaping (SnapAction, TargetWindow, CGRect, CGRect) -> Void) {
    self.resources = resources
    self.onSnap = onSnap
    downToken = try? resources.addGlobalMonitor(matching: .leftMouseDown) { [weak self] _ in self?.begin() }
  }

  func invalidate() {
    end(apply: false)
    if let downToken { resources.cancel(downToken) }
    downToken = nil
  }

  private func begin() {
    end(apply: false)
    // Coordinates only: no AX call for a simple click.
    downPoint = ScreenSpace.flipped(NSEvent.mouseLocation)
    downTime = ProcessInfo.processInfo.systemUptime
    dragToken = try? resources.addGlobalMonitor(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
      if event.type == .leftMouseUp {
        self?.end(apply: true)
      } else {
        self?.dragged()
      }
    }
  }

  private func dragged() {
    // A single AX read per drag: the window under the click and its starting frame.
    if !didProbe {
      didProbe = true
      window = downPoint.flatMap { TargetWindow.at($0) }
      initialFrame = window?.frame
      // No window under the click (desktop, menu bar): until the next click we do not look anymore.
      if window == nil || initialFrame == nil { end(apply: false) }
      return
    }
    guard let window, let initialFrame else { return }

    // A second read, only once: if the window has not moved it is
    // not a window drag and the monitor is removed until the next click.
    if !isWindowDrag {
      eventsSinceProbe += 1
      let elapsed = ProcessInfo.processInfo.systemUptime - downTime
      guard eventsSinceProbe >= Self.decisionEvents || (elapsed >= Self.decisionDelay && eventsSinceProbe >= 2)
      else { return }
      // Same size and different origin: it moves, it is not resized.
      guard let now = window.frame, now.size == initialFrame.size, now.origin != initialFrame.origin else {
        end(apply: false)
        return
      }
      isWindowDrag = true
    }

    let point = ScreenSpace.flipped(NSEvent.mouseLocation)
    guard let screen = ScreenSpace.screen(containing: point),
      let action = SnapGeometry.action(
        at: point, in: ScreenSpace.flipped(screen.frame), ignoring: Self.sharedEdges(of: screen, near: point))
    else {
      setPending(nil, on: nil)
      return
    }
    setPending(action, on: screen)
  }

  private func setPending(_ action: SnapAction?, on screen: NSScreen?) {
    guard action != pending else { return }
    pending = action
    pendingArea = screen.map { ScreenSpace.flipped($0.visibleFrame) }
    guard let action, let area = pendingArea,
      let target = SnapGeometry.frame(for: action, current: .zero, in: area)
    else {
      hidePreview()
      return
    }
    showPreview(at: ScreenSpace.flipped(target).insetBy(dx: 6, dy: 6))
  }

  private func end(apply: Bool) {
    if let dragToken { resources.cancel(dragToken) }
    dragToken = nil
    hidePreview()
    if apply, isWindowDrag, let pending, let window, let pendingArea, let initialFrame {
      onSnap(pending, window, pendingArea, initialFrame)
    }
    pendingArea = nil
    downPoint = nil
    window = nil
    initialFrame = nil
    didProbe = false
    eventsSinceProbe = 0
    isWindowDrag = false
    pending = nil
  }

  /// Screen edges beyond which, at the pointer's height, there is another monitor.
  private static func sharedEdges(of screen: NSScreen, near point: CGPoint) -> SnapEdges {
    let frame = ScreenSpace.flipped(screen.frame)
    let probes: [(SnapEdges, CGPoint)] = [
      (.left, CGPoint(x: frame.minX - 2, y: point.y)),
      (.right, CGPoint(x: frame.maxX + 2, y: point.y)),
      (.top, CGPoint(x: point.x, y: frame.minY - 2)),
      (.bottom, CGPoint(x: point.x, y: frame.maxY + 2)),
    ]
    var edges: SnapEdges = []
    // Not `ScreenSpace.screen(containing:)`: that one falls back to the main screen.
    let frames = NSScreen.screens.map { ScreenSpace.flipped($0.frame) }
    for (edge, probe) in probes where frames.contains(where: { $0.contains(probe) }) {
      edges.insert(edge)
    }
    return edges
  }

  // MARK: Preview

  /// The first time the preview grows from the center of the zone and appears; then
  /// it slides from one zone to another. System animations, short and only here.
  private func showPreview(at frame: CGRect) {
    guard frame != previewTarget else { return }
    let isNew = preview == nil
    previewTarget = frame
    if preview == nil {
      let panel = NSPanel(
        contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
      )
      panel.level = .floating
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.ignoresMouseEvents = true
      panel.isReleasedWhenClosed = false
      panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
      let glass = NSGlassEffectView()
      glass.cornerRadius = 14
      panel.contentView = glass
      preview = panel
      previewToken = resources.add(.window) { [weak panel] in panel?.close() }
    }
    guard let preview else { return }
    if isNew {
      preview.alphaValue = 0
      preview.setFrame(frame.insetBy(dx: frame.width * 0.06, dy: frame.height * 0.06), display: true)
      preview.orderFrontRegardless()
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = isNew ? 0.2 : 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      context.allowsImplicitAnimation = true
      preview.animator().setFrame(frame, display: true)
      preview.animator().alphaValue = 1
    }
  }

  private func hidePreview() {
    if let previewToken { resources.cancel(previewToken) }
    previewToken = nil
    preview = nil
    previewTarget = nil
  }
}

/// Native macOS tiling by dragging to the edges (System Settings >
/// Desktop & Dock). If it is on, the two snappings overlap.
enum NativeTiling {
  private static let domain = "com.apple.WindowManager"

  /// Read once, when snapping by dragging starts: no polling.
  /// Missing key = macOS default value, that is on.
  static var isEdgeDragEnabled: Bool {
    CFPreferencesAppSynchronize(domain as CFString)
    return ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"].contains { key in
      (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool) ?? true
    }
  }

  static func openSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
  }
}
