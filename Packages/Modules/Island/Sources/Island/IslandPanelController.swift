// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit
import QuartzCore
import SwiftUI

/// Panel root view: detects the mouse passing with an `NSTrackingArea`
/// local to the window, hence no global monitor (DESIGN.md §2.1.1, point 3).
final class IslandContainerView: NSView {
  var onHover: ((Bool) -> Void)?
  /// A dragged file entered (with the position in the view) or left (`nil`).
  var onDragMove: ((CGPoint?) -> Void)?
  var onDrop: (([URL], CGPoint) -> Bool)?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self
      )
    )
  }

  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: File drop

  private func location(of sender: any NSDraggingInfo) -> CGPoint {
    convert(sender.draggingLocation, from: nil)
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard onDrop != nil else { return [] }
    onDragMove?(location(of: sender))
    return .copy
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard onDrop != nil else { return [] }
    onDragMove?(location(of: sender))
    return .copy
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) { onDragMove?(nil) }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let urls =
      sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
    guard !urls.isEmpty else { return false }
    return onDrop?(urls, location(of: sender)) ?? false
  }
}

/// Pure blur of what is behind, with no tint or reflections.
///
/// `NSVisualEffectView` always adds color and saturation to the material; here
/// the bare blur is needed, which Core Animation offers only with private classes
/// (`CABackdropLayer` and `CAFilter`). If they are missing the view stays empty: the island
/// works the same, without the glow.
final class HaloBlurView: NSView {
  private let maskLayer = CALayer()
  private let margin: CGFloat

  /// `margin` is the width of the fade around the island; `radius` the radius of its corners.
  init(frame: CGRect, margin: CGFloat, radius: CGFloat) {
    self.margin = margin
    super.init(frame: frame)
    guard let backdrop = Self.makeBackdrop(radius: 16) else { return }
    layer = backdrop
    wantsLayer = true
    let scale: CGFloat = 2
    let inset = margin + radius
    let side = inset * 2 + 2
    maskLayer.contents = Self.makeMask(side: side, margin: margin, radius: radius, scale: scale)
    // Nine parts: corners and faded edges stay as drawn, the center stretches.
    let unit = inset / side
    maskLayer.contentsCenter = CGRect(x: unit, y: unit, width: 1 - unit * 2, height: 1 - unit * 2)
    maskLayer.contentsScale = scale
    backdrop.mask = maskLayer
    fitMask()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// To call on every window frame change: a view hosting its
  /// own layer does not receive `layout()`, so the mask does not adapt by itself.
  func fitMask() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // The mask protrudes above the window by a margin: the top fade
    // stays off screen and the blur is full up to the top edge.
    // On the sides the fillet is removed: the solid part of the mask coincides with the
    // island's body, so the fade is equally wide on the sides and bottom.
    let shoulder = IslandGeometry.shoulderRadius
    maskLayer.frame = CGRect(
      x: shoulder, y: 0, width: max(bounds.width - shoulder * 2, 0), height: bounds.height + margin
    )
    CATransaction.commit()
  }

  /// Solid rounded rectangle fading to zero within `margin`, without steps.
  private static func makeMask(side: CGFloat, margin: CGFloat, radius: CGFloat, scale: CGFloat) -> CGImage? {
    let pixels = Int((side * scale).rounded())
    guard
      let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    let body = CGRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let black = CGColor(gray: 0, alpha: 1)
    context.setFillColor(black)
    // Three glows of increasing extent: full near the island, then a long tail
    // that reaches zero before the window's edge, so no cut is visible.
    for blur in [margin * 0.25, margin * 0.5, margin * 0.8] {
      context.setShadow(offset: .zero, blur: blur * scale, color: black)
      context.addPath(path)
      context.fillPath()
    }
    return context.makeImage()
  }

  private static func makeBackdrop(radius: CGFloat) -> CALayer? {
    let makeFilter = NSSelectorFromString("filterWithType:")
    guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
      let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
      filterClass.responds(to: makeFilter),
      let filter = filterClass.perform(makeFilter, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
    else { return nil }
    let layer = layerClass.init()
    guard layer.responds(to: NSSelectorFromString("setWindowServerAware:")) else { return nil }
    filter.setValue(radius, forKey: "inputRadius")
    layer.filters = [filter]
    // Without this the layer blurs only our window's content, that is nothing.
    layer.setValue(true, forKey: "windowServerAware")
    return layer
  }
}

/// Buttons must respond to the first click even if the app is not active.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the island's panel and moves its frame together with the shape:
/// the frame is never larger than the visible shape, so clicks on the menu bar
/// items next to the notch are not intercepted (§2.1.1).
@MainActor
final class IslandPanelController: NSObject {
  private struct Morph {
    let from: CGRect
    let target: CGRect
    let start: CFTimeInterval
    /// Opening and closing both bounce; closing is shorter and more damped.
    let opening: Bool

    var duration: CFTimeInterval { opening ? 0.66 : 0.5 }
    var damping: Double { opening ? IslandGeometry.openingDamping : IslandGeometry.closingDamping }
  }

  private var halo: NSPanel?
  private var haloBlur: HaloBlurView?

  /// Present in every Space and above full-screen apps. `.transient` hides
  /// it in Mission Control, so it does not appear in the Spaces' previews.
  static let spaceBehavior: NSWindow.CollectionBehavior = [
    .canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle,
  ]

  private let model: IslandModel
  private let resources: ResourceBag
  private let container = IslandContainerView()
  private var panel: NSPanel?
  private var screenFrame: CGRect = .zero
  private var scale: CGFloat = 2
  private var presentation: IslandPresentation = .collapsed
  private var morph: Morph?
  private var link: CADisplayLink?
  private var linkToken: ResourceBag.Token?

  var onHover: ((Bool) -> Void)? {
    get { container.onHover }
    set { container.onHover = newValue }
  }

  var onDragMove: ((CGPoint?) -> Void)? {
    get { container.onDragMove }
    set { container.onDragMove = newValue }
  }

  /// Setting it enables file drop on the panel; `nil` disables it.
  var onDrop: (([URL], CGPoint) -> Bool)? {
    get { container.onDrop }
    set {
      container.onDrop = newValue
      if newValue == nil {
        container.unregisterDraggedTypes()
      } else {
        container.registerForDraggedTypes([.fileURL])
      }
    }
  }

  /// Current size of the panel, to place the drop zones.
  var size: CGSize { container.bounds.size }

  /// Current frame on screen; `nil` if the panel does not exist.
  var frame: CGRect? { panel?.frame }

  init(model: IslandModel, actions: IslandActions, resources: ResourceBag) {
    self.model = model
    self.resources = resources
    super.init()
    let hosting = IslandHostingView(rootView: IslandView(model: model, actions: actions))
    hosting.sizingOptions = []
    hosting.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: container.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    relayout()
    resources.add(.window) { [weak self] in self?.close() }
  }

  /// Recomputes screen and notch (at launch and when the screen configuration changes).
  func relayout() {
    stopMorph()
    // The screen with the notch, otherwise the one with the menu bar.
    guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else {
      close()
      return
    }
    let notch = IslandGeometry.notch(
      screenFrame: screen.frame,
      safeTop: screen.safeAreaInsets.top,
      leftArea: screen.auxiliaryTopLeftArea,
      rightArea: screen.auxiliaryTopRightArea,
      menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY
    )
    screenFrame = screen.frame
    scale = screen.backingScaleFactor
    model.notch = notch
    model.screenFrame = screen.frame

    let panel = panel ?? makePanel()
    if self.panel == nil, attachesToLockScreen { LockScreenSpace.attach([panel]) }
    self.panel = panel
    place(targetFrame(for: presentation), display: true)
    updateVisibility()
  }

  /// Brings the shape to the indicated presentation, animating the frame.
  func apply(_ new: IslandPresentation) {
    guard let panel else { return }
    let target = targetFrame(for: new)
    let goal = morph?.target ?? panel.frame
    // AppKit rounds the window frame to whole points (265.5 becomes 266):
    // a difference under one point is not a shape change and must not start
    // a morph, which for half a second would make the panel transparent to clicks
    // and would make a dragged file get lost.
    guard new != presentation || !IslandGeometry.isSameFrame(target, goal) else { return }
    let shrinking = IslandGeometry.isShrinking(from: goal, to: target)
    presentation = new
    if !model.notch.isPhysical, new != .collapsed { panel.orderFrontRegardless() }

    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      stopMorph()
      place(target, display: true)
      updateVisibility()
      return
    }
    // During the collapse clicks pass to whatever is underneath (§2.1.1, point 4). If a
    // collapse is interrupted by a reopening the panel starts receiving them again immediately.
    // Never during a drag: the panel would stop being the destination.
    panel.ignoresMouseEvents = shrinking && !model.isDragging
    morph = Morph(from: panel.frame, target: target, start: CACurrentMediaTime(), opening: !shrinking)
    startLink()
  }

  private func targetFrame(for presentation: IslandPresentation) -> CGRect {
    IslandGeometry.frame(
      for: presentation, notch: model.notch.rect, screenFrame: screenFrame, extraHeight: model.extraHeight
    )
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: model.notch.rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = SurfaceLevel.island.windowLevel
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.collectionBehavior = IslandPanelController.spaceBehavior
    panel.contentView = container
    return panel
  }

  /// Without a notch the panel exists on screen only while it shows something (§2.1.1, point 5).
  private func updateVisibility() {
    guard let panel else { return }
    if model.notch.isPhysical || presentation != .collapsed {
      panel.orderFrontRegardless()
    } else {
      panel.orderOut(nil)
    }
  }

  func close() {
    stopMorph()
    halo?.close()
    halo = nil
    haloBlur = nil
    panel?.close()
    panel = nil
  }

  // MARK: Frame and glow

  /// The only point where the panel changes frame: the glow always follows it.
  private func place(_ frame: CGRect, display: Bool) {
    panel?.setFrame(frame, display: display)
    updateHalo(around: frame)
  }

  /// Blurred glow around the open island. It is a separate window that ignores
  /// the mouse: the panel stays tight to the shape (§2.1.1) and clicks around it
  /// pass to whatever is underneath. It exists on screen only while the island is open.
  private func updateHalo(around frame: CGRect) {
    let openness = IslandGeometry.haloOpacity(height: frame.height, notchHeight: model.notch.rect.height)
    let wanted =
      model.haloEnabled && openness > 0.01 && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    guard wanted, let panel else {
      halo?.orderOut(nil)
      return
    }
    let halo = halo ?? makeHalo()
    self.halo = halo
    halo.setFrame(IslandGeometry.haloFrame(around: frame), display: false)
    haloBlur?.fitMask()
    halo.alphaValue = openness
    if !halo.isVisible { halo.order(.below, relativeTo: panel.windowNumber) }
  }

  /// The windows are in the lock screen's Space only while the screen is
  /// locked. There they are composited above everything, even above the image of
  /// a dragged file, and the system does not consider them drop destinations.
  var attachesToLockScreen = false {
    didSet { if attachesToLockScreen != oldValue { rebuild() } }
  }

  /// Recreates the windows: needed to enter or leave the lock screen's Space.
  func rebuild() {
    close()
    relayout()
  }

  /// Reapplies the glow after a preference change.
  func refreshHalo() {
    guard let frame = panel?.frame else { return }
    updateHalo(around: frame)
  }

  private func makeHalo() -> NSPanel {
    let size = CGSize(width: 200, height: 100)
    let halo = NSPanel(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      // Not deferred: the lock screen's Space needs a valid window number.
      defer: false
    )
    halo.level = SurfaceLevel.island.windowLevel
    halo.isOpaque = false
    halo.backgroundColor = .clear
    halo.hasShadow = false
    halo.ignoresMouseEvents = true
    halo.isReleasedWhenClosed = false
    halo.hidesOnDeactivate = false
    halo.collectionBehavior = IslandPanelController.spaceBehavior

    let blur = HaloBlurView(
      frame: CGRect(origin: .zero, size: size), margin: IslandGeometry.haloMargin,
      radius: IslandGeometry.expandedCornerRadius
    )
    blur.autoresizingMask = [.width, .height]
    halo.contentView = blur
    haloBlur = blur
    if attachesToLockScreen { LockScreenSpace.attach([halo]) }
    return halo
  }

  // MARK: Morph

  /// The display link lives only during the animation (DESIGN.md §5.2, rule 4).
  private func startLink() {
    guard link == nil else { return }
    let link = container.displayLink(target: self, selector: #selector(step(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    self.link = link
    linkToken = resources.add(.other) { link.invalidate() }
  }

  private func stopMorph() {
    if let linkToken { resources.cancel(linkToken) }
    linkToken = nil
    link = nil
    morph = nil
    panel?.ignoresMouseEvents = false
  }

  @objc private func step(_ sender: CADisplayLink) {
    guard let morph, panel != nil else {
      stopMorph()
      return
    }
    let elapsed = (CACurrentMediaTime() - morph.start) / morph.duration
    guard elapsed < 1 else {
      place(morph.target, display: false)
      stopMorph()
      updateVisibility()
      return
    }
    let frame = IslandGeometry.interpolate(
      from: morph.from,
      to: morph.target,
      progress: IslandGeometry.springProgress(elapsed, damping: morph.damping),
      scale: scale
    )
    place(frame, display: false)
  }
}
