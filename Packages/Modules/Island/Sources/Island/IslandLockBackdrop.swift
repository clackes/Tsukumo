// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore

/// Full-screen lock screen background: the track's artwork,
/// blurred, covering the clock, profile photo and password field like a screensaver.
///
/// Artwork arrives small (about 600 px per side): enlarged to full
/// screen it gets grainy anyway. Here the artwork is blurred *while small* and only
/// afterwards enlarged: an enlarged gradient stays smooth. The image is
/// 16 bits per channel, so the gradients do not band. The sharp artwork
/// stays the player's.
///
/// The motion is a `CAAnimation` on the layer: the system composites it, without
/// our code on every frame, and it stops when the music is paused.
/// A click on the background removes it for a few seconds and shows the macOS
/// login; Touch ID and the typed password work even with the background covering.
@MainActor
final class LockBackdrop {
  /// Maximum side of the blurred image: beyond that no difference would be visible.
  static let blurredSide: CGFloat = 512
  /// Blur radius relative to the artwork's side (15 Nov: from 7% to 0.5%,
  /// the artwork is still recognizable).
  static let blurFraction: CGFloat = 0.005
  /// The fill at the sides of the artwork: the same image much more blurred.
  static let fillBlurFraction: CGFloat = 0.12
  /// Part of the artwork that fades into the fill, per side.
  static let edgeFade: CGFloat = 0.16
  /// Slow zoom around the center, back and forth: the artwork stays centered
  /// and slightly enlarged (previously 1.15 → 1.34 with a sideways drift).
  static let zoomRange: ClosedRange<CGFloat> = 1.0...1.06
  /// For how long the login stays uncovered after a click.
  static let revealDuration: Duration = .seconds(12)

  private(set) var panel: NSPanel?
  /// Whole artwork, square and centered, as tall as the screen.
  private let imageLayer = CALayer()
  /// Behind: the heavily blurred artwork, filling the sides.
  private let fillLayer = CALayer()
  private let veil = CALayer()
  private let hint = CATextLayer()
  private var imageKey: ObjectIdentifier?
  private(set) var isRevealed = false
  /// Called on click on the background.
  var onClick: (() -> Void)?

  /// The background covers only if there is artwork and the user has not moved it aside.
  static func covers(hasArtwork: Bool, revealed: Bool) -> Bool { hasArtwork && !revealed }

  func show(on screen: CGRect, level: NSWindow.Level) {
    if let panel {
      if panel.frame != screen {
        panel.setFrame(screen, display: false)
        layout(in: CGRect(origin: .zero, size: screen.size))
      }
      return
    }
    let panel = NSPanel(
      contentRect: screen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = level
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    let view = BackdropView(frame: CGRect(origin: .zero, size: screen.size))
    view.onClick = { [weak self] in self?.onClick?() }
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.cgColor
    view.layer?.masksToBounds = true
    panel.contentView = view
    let scale = panel.backingScaleFactor
    let bounds = CGRect(origin: .zero, size: screen.size)

    // On a wide screen artwork that filled it would lose a third
    // of the image and look zoomed: the artwork stays whole at the center
    // and the sides are filled by the same image heavily blurred and darker.
    fillLayer.frame = bounds
    fillLayer.contentsGravity = .resizeAspectFill
    fillLayer.magnificationFilter = .trilinear
    fillLayer.opacity = 0.75
    view.layer?.addSublayer(fillLayer)

    imageLayer.frame = Self.coverFrame(in: bounds)
    imageLayer.contentsGravity = .resizeAspectFill
    // It is only enlarged: the linear filter is enough, without mipmaps.
    imageLayer.magnificationFilter = .linear
    imageLayer.transform = CATransform3DMakeScale(Self.zoomRange.lowerBound, Self.zoomRange.lowerBound, 1)
    // The faded edges are already in the image: no mask, which would cost
    // an offscreen pass on every composition.
    view.layer?.addSublayer(imageLayer)

    // Dark veil: the player and the white text stay readable on any artwork.
    veil.frame = bounds
    veil.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    view.layer?.addSublayer(veil)

    hint.string = String(localized: "Click to show sign-in")
    hint.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    hint.fontSize = 12
    hint.alignmentMode = .center
    hint.foregroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
    hint.contentsScale = scale
    hint.frame = CGRect(x: 0, y: 28, width: bounds.width, height: 18)
    view.layer?.addSublayer(hint)

    panel.alphaValue = 0
    self.panel = panel
  }

  /// Updates artwork and motion. Without artwork, or with the background moved aside, the
  /// window is transparent and lets clicks through to the macOS screen.
  func update(artwork: NSImage?, isPlaying: Bool, reduceMotion: Bool) {
    guard let panel else { return }
    if let artwork {
      let key = ObjectIdentifier(artwork)
      if key != imageKey, let blurred = Self.blurred(artwork, fadingEdges: true),
        let fill = Self.blurred(artwork, fraction: Self.fillBlurFraction)
      {
        imageKey = key
        for (layer, image) in [(imageLayer, blurred), (fillLayer, fill)] {
          let fade = CATransition()
          fade.type = .fade
          fade.duration = 0.9
          layer.add(fade, forKey: "contents")
          layer.contents = image
        }
      }
    } else {
      imageKey = nil
    }
    let covering = Self.covers(hasArtwork: imageKey != nil, revealed: isRevealed)
    panel.ignoresMouseEvents = !covering
    setAlpha(covering ? 1 : 0)
    setMotion(running: covering && isPlaying && !reduceMotion)
  }

  /// Moves the background aside (click) or puts it back.
  func setRevealed(_ revealed: Bool) {
    isRevealed = revealed
  }

  func close() {
    imageLayer.removeAllAnimations()
    imageLayer.contents = nil
    fillLayer.contents = nil
    imageKey = nil
    isRevealed = false
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel = nil
  }

  private func setAlpha(_ alpha: CGFloat) {
    guard let panel, panel.alphaValue != alpha else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.35
      panel.animator().alphaValue = alpha
    }
  }

  /// Slow zoom around the center, back and forth. When paused the layer stops where it is.
  private func setMotion(running: Bool) {
    let key = "drift"
    if running {
      if imageLayer.animation(forKey: key) == nil {
        let from = CATransform3DMakeScale(Self.zoomRange.lowerBound, Self.zoomRange.lowerBound, 1)
        let to = CATransform3DMakeScale(Self.zoomRange.upperBound, Self.zoomRange.upperBound, 1)
        let drift = CABasicAnimation(keyPath: "transform")
        drift.fromValue = from
        drift.toValue = to
        drift.duration = 26
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageLayer.add(drift, forKey: key)
      }
      guard imageLayer.speed == 0 else { return }
      let paused = imageLayer.timeOffset
      imageLayer.speed = 1
      imageLayer.timeOffset = 0
      imageLayer.beginTime = 0
      imageLayer.beginTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil) - paused
    } else if imageLayer.speed != 0, imageLayer.animation(forKey: key) != nil {
      imageLayer.timeOffset = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
      imageLayer.speed = 0
    }
  }

  // MARK: Image

  private static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])

  /// Artwork shrunk, blurred and slightly more saturated, at 16 bits per channel.
  /// Repositions the layers for a new screen size.
  private func layout(in bounds: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fillLayer.frame = bounds
    veil.frame = bounds
    // The frame of a transformed layer is not set: go through bounds and position.
    let cover = Self.coverFrame(in: bounds)
    imageLayer.bounds = CGRect(origin: .zero, size: cover.size)
    imageLayer.position = CGPoint(x: cover.midX, y: cover.midY)
    hint.frame = CGRect(x: 0, y: 28, width: bounds.width, height: 18)
    CATransaction.commit()
  }

  /// Fades the left and right sides to transparent (by `edgeFade` of the width).
  static func fadeEdges(of image: CIImage) -> CIImage {
    let extent = image.extent
    let fade = extent.width * edgeFade
    func ramp(from start: CGFloat, to end: CGFloat) -> CIImage? {
      let gradient = CIFilter.linearGradient()
      gradient.point0 = CGPoint(x: start, y: extent.midY)
      gradient.point1 = CGPoint(x: end, y: extent.midY)
      gradient.color0 = CIColor.black
      gradient.color1 = CIColor.white
      return gradient.outputImage?.cropped(to: extent)
    }
    guard let left = ramp(from: extent.minX, to: extent.minX + fade),
      let right = ramp(from: extent.maxX, to: extent.maxX - fade)
    else { return image }
    let both = CIFilter.multiplyCompositing()
    both.inputImage = left
    both.backgroundImage = right
    let blend = CIFilter.blendWithMask()
    blend.inputImage = image
    blend.backgroundImage = CIImage.empty()
    blend.maskImage = both.outputImage
    return blend.outputImage?.cropped(to: extent) ?? image
  }

  /// How much the artwork exceeds the screen's short side: at 1 it is seen whole
  /// but looks small, filling the whole screen a third of it disappears. 1.25
  /// sits in between: about a tenth is lost above and below.
  static let coverScale: CGFloat = 1.25

  /// Centered square, slightly taller than the screen's short side.
  static func coverFrame(in bounds: CGRect) -> CGRect {
    let side = min(min(bounds.width, bounds.height) * coverScale, max(bounds.width, bounds.height))
    return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
  }

  static func blurred(_ image: NSImage, fraction: CGFloat = blurFraction, fadingEdges: Bool = false) -> CGImage? {
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var input = CIImage(cgImage: source)
    let side = max(input.extent.width, input.extent.height)
    guard side > 0 else { return nil }
    if side > blurredSide {
      let scale = CIFilter.lanczosScaleTransform()
      scale.inputImage = input
      scale.scale = Float(blurredSide / side)
      input = scale.outputImage ?? input
    }
    let extent = input.extent
    let blur = CIFilter.gaussianBlur()
    // Edges are extended before blurring: no dark halo at the sides.
    blur.inputImage = input.clampedToExtent()
    blur.radius = Float(max(extent.width, extent.height) * fraction)
    let color = CIFilter.colorControls()
    color.inputImage = blur.outputImage
    color.saturation = 1.25
    color.brightness = -0.03
    guard var output = color.outputImage?.cropped(to: extent) else { return nil }
    if fadingEdges { output = fadeEdges(of: output) }
    let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    return context.createCGImage(output, from: extent, format: .RGBAh, colorSpace: space)
  }
}

/// Background view: receives only the click.
private final class BackdropView: NSView {
  var onClick: (() -> Void)?

  override func mouseDown(with event: NSEvent) { onClick?() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
