// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Edit Photo

/// Edit Photo light adjustments. Exposure is in EV (-3…+3), the others in -100…+100.
struct EditAdjustments: Equatable, Sendable {
  var exposure = 0.0
  var brightness = 0.0
  var contrast = 0.0
  var highlights = 0.0
  var shadows = 0.0

  var isNeutral: Bool { self == EditAdjustments() }
}

/// Edit Photo's Core Image engine. The `CIContext` lives as long as the panel that owns it.
final class ImageEditingEngine: @unchecked Sendable {
  // CIContext is thread-safe: several renders in parallel (preview + apply) are allowed.
  private let context = CIContext(options: [.cacheIntermediates: false])

  /// Applies the adjustments; `nil` if Core Image cannot produce the image.
  func render(_ image: CGImage, adjustments: EditAdjustments) -> CGImage? {
    if adjustments.isNeutral { return image }
    var output = CIImage(cgImage: image)
    let extent = output.extent

    if adjustments.exposure != 0 {
      let filter = CIFilter.exposureAdjust()
      filter.inputImage = output
      filter.ev = Float(adjustments.exposure)
      output = filter.outputImage ?? output
    }
    if adjustments.shadows != 0 || adjustments.highlights < 0 {
      let filter = CIFilter.highlightShadowAdjust()
      filter.inputImage = output
      filter.radius = 0
      // 1 = no change; below 1 the highlights darken.
      filter.highlightAmount = Float(1 + min(0, adjustments.highlights) / 100)
      filter.shadowAmount = Float(adjustments.shadows / 100)
      output = filter.outputImage ?? output
    }
    if adjustments.highlights > 0 {
      // The filter cannot brighten highlights: gentle curve on the top quarter.
      let filter = CIFilter.toneCurve()
      filter.inputImage = output
      let lift = CGFloat(adjustments.highlights / 100) * 0.12
      filter.point0 = CGPoint(x: 0, y: 0)
      filter.point1 = CGPoint(x: 0.25, y: 0.25)
      filter.point2 = CGPoint(x: 0.5, y: 0.5)
      filter.point3 = CGPoint(x: 0.75, y: 0.75 + lift)
      filter.point4 = CGPoint(x: 1, y: 1)
      output = filter.outputImage ?? output
    }
    if adjustments.brightness != 0 || adjustments.contrast != 0 {
      // Contrast pivots around mid grey: it must be applied in perceptual space (sRGB gamma),
      // not in Core Image's linear working space.
      let filter = CIFilter.colorControls()
      filter.inputImage = output.applyingFilter("CILinearToSRGBToneCurve")
      filter.brightness = Float(adjustments.brightness / 100 * 0.5)
      filter.contrast = Float(1 + adjustments.contrast / 100 * 0.6)
      filter.saturation = 1
      output = filter.outputImage?.applyingFilter("CISRGBToneCurveToLinear") ?? output
    }

    let space: CGColorSpace
    if let own = image.colorSpace, own.model == .rgb {
      space = own
    } else {
      space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
    return context.createCGImage(output.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: space)
  }
}

// MARK: - Add BG

/// RGBA colour in sRGB space, simple and Sendable.
struct RGBAColor: Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha = 1.0

  init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// From a SwiftUI colour, converted to sRGB.
  init(_ color: Color) {
    let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
    self.init(
      Double(converted.redComponent), Double(converted.greenComponent), Double(converted.blueComponent),
      Double(converted.alphaComponent))
  }

  var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

  var cgColor: CGColor {
    CGColor(
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]) ?? CGColor(gray: 0, alpha: 1)
  }
}

/// Background chosen for Add BG.
enum BackgroundStyle: Hashable, Sendable {
  case gradient(Int)
  case solid(Int)
  case color(RGBAColor)
  case image(URL)
}

/// Default swatches: gradients (fixed diagonal angle) and solid colours.
enum BackgroundPresets {
  static let gradients: [[RGBAColor]] = [
    [RGBAColor(0.99, 0.60, 0.40), RGBAColor(0.93, 0.25, 0.45)],
    [RGBAColor(0.36, 0.55, 0.98), RGBAColor(0.65, 0.35, 0.95)],
    [RGBAColor(0.20, 0.80, 0.75), RGBAColor(0.20, 0.45, 0.90)],
    [RGBAColor(0.99, 0.85, 0.40), RGBAColor(0.98, 0.50, 0.30)],
    [RGBAColor(0.55, 0.90, 0.55), RGBAColor(0.10, 0.60, 0.55)],
    [RGBAColor(0.98, 0.70, 0.85), RGBAColor(0.60, 0.55, 0.95)],
    [RGBAColor(0.15, 0.17, 0.25), RGBAColor(0.40, 0.25, 0.55)],
    [RGBAColor(0.95, 0.95, 0.97), RGBAColor(0.70, 0.75, 0.85)],
    [RGBAColor(0.05, 0.05, 0.08), RGBAColor(0.25, 0.28, 0.35)],
    [RGBAColor(0.99, 0.45, 0.35), RGBAColor(0.99, 0.80, 0.35)],
  ]

  static let solids: [RGBAColor] = [
    RGBAColor(1, 1, 1), RGBAColor(0.93, 0.93, 0.94), RGBAColor(0.60, 0.62, 0.66), RGBAColor(0.10, 0.10, 0.12),
    RGBAColor(0.92, 0.26, 0.24), RGBAColor(0.98, 0.58, 0.15), RGBAColor(0.99, 0.80, 0.20),
    RGBAColor(0.25, 0.72, 0.38), RGBAColor(0.20, 0.50, 0.95), RGBAColor(0.62, 0.33, 0.90),
  ]
}

/// Composes the image on a larger canvas, with a soft shadow, over the background.
enum BackgroundCompositor {
  /// Margin around the image, proportional to the long side.
  static let marginRatio = 0.08

  static func canvasSize(for image: CGSize) -> CGSize {
    let margin = (max(image.width, image.height) * marginRatio).rounded()
    return CGSize(width: image.width + 2 * margin, height: image.height + 2 * margin)
  }

  static func render(_ image: CGImage, style: BackgroundStyle) -> CGImage? {
    let size = canvasSize(for: CGSize(width: image.width, height: image.height))
    let margin = (size.width - CGFloat(image.width)) / 2
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let canvas = CGRect(origin: .zero, size: size)
    context.interpolationQuality = .high
    drawBackground(style, in: context, rect: canvas, space: space)

    context.saveGState()
    context.setShadow(
      offset: CGSize(width: 0, height: -margin * 0.18), blur: margin * 0.55,
      color: CGColor(gray: 0, alpha: 0.38))
    context.draw(image, in: CGRect(x: margin, y: margin, width: CGFloat(image.width), height: CGFloat(image.height)))
    context.restoreGState()
    return context.makeImage()
  }

  private static func drawBackground(_ style: BackgroundStyle, in context: CGContext, rect: CGRect, space: CGColorSpace)
  {
    switch style {
    case .gradient(let index):
      let presets = BackgroundPresets.gradients
      let colors = presets[min(max(index, 0), presets.count - 1)].map(\.cgColor)
      guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
      context.drawLinearGradient(
        gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    case .solid(let index):
      let presets = BackgroundPresets.solids
      context.setFillColor(presets[min(max(index, 0), presets.count - 1)].cgColor)
      context.fill(rect)
    case .color(let color):
      context.setFillColor(color.cgColor)
      context.fill(rect)
    case .image(let url):
      guard let picture = try? ToolImage.load(url, maxPixel: Int(max(rect.width, rect.height).rounded())) else {
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(rect)
        return
      }
      // Fills the canvas without distorting the image (aspect fill, centred).
      let scale = max(rect.width / CGFloat(picture.width), rect.height / CGFloat(picture.height))
      let drawn = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
      context.saveGState()
      context.clip(to: rect)
      context.draw(
        picture,
        in: CGRect(
          x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2, width: drawn.width,
          height: drawn.height))
      context.restoreGState()
    }
  }

  /// Saves the result as PNG next to the original.
  @discardableResult
  static func savePNG(_ image: CGImage, like source: URL, suffix: String) throws -> URL {
    let output = OutputNamer.url(for: source, extension: "png", suffix: suffix)
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ToolImageError.unwritable(output.lastPathComponent) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ToolImageError.unwritable(output.lastPathComponent) }
    return output
  }
}
