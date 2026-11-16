// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import CoreText
import SwiftUI

// MARK: - Model

/// Serializable sRGB colour.
struct AnnotationColor: Codable, Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double = 1

  static let presets: [AnnotationColor] = [
    AnnotationColor(red: 0.96, green: 0.23, blue: 0.21),
    AnnotationColor(red: 1.0, green: 0.80, blue: 0.0),
    AnnotationColor(red: 0.20, green: 0.78, blue: 0.35),
    AnnotationColor(red: 0.0, green: 0.48, blue: 1.0),
    AnnotationColor(red: 1, green: 1, blue: 1),
    AnnotationColor(red: 0, green: 0, blue: 0),
  ]

  init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  init(_ color: Color) {
    let native = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.systemRed
    self.init(
      red: Double(native.redComponent), green: Double(native.greenComponent), blue: Double(native.blueComponent),
      alpha: Double(native.alphaComponent))
  }

  var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

  var cgColor: CGColor {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    return CGColor(colorSpace: space, components: [red, green, blue, alpha].map { CGFloat($0) })
      ?? CGColor(gray: 0, alpha: 1)
  }
}

/// An element drawn on the image. All coordinates are normalised (0–1)
/// relative to the image and `lineWidth` is a fraction of its width: so the
/// same model draws identically at any resolution.
struct Annotation: Identifiable, Equatable, Codable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable {
    case arrow, rectangle, oval, line, freehand, text
  }

  var id = UUID()
  var kind: Kind
  /// Arrow, line, rectangle and oval: two points (start/end or opposite corners);
  /// freehand: all the points; text: the top-left point.
  var points: [CGPoint]
  var color: AnnotationColor
  var lineWidth: Double
  var text = ""
}

// MARK: - Shared geometry (SwiftUI Canvas and CoreGraphics)

enum AnnotationGeometry {
  /// Text size = thickness × this factor.
  static let textScale: CGFloat = 7

  static func absolute(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(x: point.x * size.width, y: point.y * size.height)
  }

  static func strokeWidth(_ item: Annotation, in size: CGSize) -> CGFloat {
    CGFloat(item.lineWidth) * size.width
  }

  static func fontSize(_ item: Annotation, in size: CGSize) -> CGFloat {
    CGFloat(item.lineWidth) * textScale * size.width
  }

  /// Path to draw with the element's stroke; `nil` for text.
  static func path(for item: Annotation, in size: CGSize) -> CGPath? {
    let pts = item.points.map { absolute($0, in: size) }
    guard let first = pts.first else { return nil }
    let path = CGMutablePath()
    let last = pts.last ?? first
    switch item.kind {
    case .line:
      path.move(to: first)
      path.addLine(to: last)
    case .arrow:
      path.move(to: first)
      path.addLine(to: last)
      addHead(to: path, from: first, tip: last, width: strokeWidth(item, in: size))
    case .rectangle:
      path.addRect(rectBetween(first, last))
    case .oval:
      path.addEllipse(in: rectBetween(first, last))
    case .freehand:
      addSmoothed(pts, to: path)
    case .text:
      return nil
    }
    return path
  }

  private static func addHead(to path: CGMutablePath, from start: CGPoint, tip: CGPoint, width: CGFloat) {
    let deltaX = tip.x - start.x
    let deltaY = tip.y - start.y
    guard hypot(deltaX, deltaY) > 0.5 else { return }
    let angle = atan2(deltaY, deltaX)
    let length = min(max(width * 4.5, width + 8), hypot(deltaX, deltaY))
    for side in [-1.0, 1.0] {
      let wing = angle + .pi + side * (.pi / 7)
      path.move(to: tip)
      path.addLine(to: CGPoint(x: tip.x + length * cos(wing), y: tip.y + length * sin(wing)))
    }
  }

  private static func addSmoothed(_ pts: [CGPoint], to path: CGMutablePath) {
    guard let first = pts.first else { return }
    path.move(to: first)
    guard pts.count > 2 else {
      path.addLine(to: pts.last ?? first)
      return
    }
    for index in 1..<(pts.count - 1) {
      let mid = CGPoint(x: (pts[index].x + pts[index + 1].x) / 2, y: (pts[index].y + pts[index + 1].y) / 2)
      path.addQuadCurve(to: mid, control: pts[index])
    }
    path.addLine(to: pts[pts.count - 1])
  }

  // MARK: Text

  static func textFont(size: CGFloat) -> CTFont {
    NSFont.systemFont(ofSize: max(size, 1), weight: .bold) as CTFont
  }

  static func textLine(_ item: Annotation, in size: CGSize) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): textFont(size: fontSize(item, in: size)),
      NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: attributes))
  }

  /// Rectangle occupied by the text (origin at top left) and baseline distance.
  static func textBox(_ item: Annotation, in size: CGSize) -> (rect: CGRect, ascent: CGFloat) {
    let line = textLine(item, in: size)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let origin = item.points.first.map { absolute($0, in: size) } ?? .zero
    return (CGRect(x: origin.x, y: origin.y, width: width, height: ascent + descent + leading), ascent)
  }

  // MARK: Selection

  /// Rectangle enclosing the element, in points of the `size` space.
  static func bounds(of item: Annotation, in size: CGSize) -> CGRect {
    if item.kind == .text { return textBox(item, in: size).rect }
    let pad = strokeWidth(item, in: size) / 2
    let box = path(for: item, in: size)?.boundingBoxOfPath ?? .zero
    return box.insetBy(dx: -pad, dy: -pad)
  }

  static func hit(_ item: Annotation, at point: CGPoint, in size: CGSize, tolerance: CGFloat) -> Bool {
    if item.kind == .text {
      return textBox(item, in: size).rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
    guard let path = path(for: item, in: size) else { return false }
    let width = strokeWidth(item, in: size) + tolerance * 2
    return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
  }

  static func moved(_ item: Annotation, by delta: CGPoint) -> Annotation {
    var copy = item
    copy.points = item.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    return copy
  }
}

// MARK: - Full-resolution rasterisation

enum AnnotationRenderer {
  /// Draws the annotations on the image, at its resolution, with the same model as the canvas.
  static func render(_ items: [Annotation], onto image: CGImage) -> CGImage? {
    guard let ctx = ToolBitmap.context(width: image.width, height: image.height, like: image) else { return nil }
    let size = CGSize(width: image.width, height: image.height)
    ctx.draw(image, in: CGRect(origin: .zero, size: size))
    // From here the origin is at top left, as in the normalised coordinates.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    for item in items { draw(item, in: ctx, size: size) }
    return ctx.makeImage()
  }

  static func draw(_ item: Annotation, in ctx: CGContext, size: CGSize) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setStrokeColor(item.color.cgColor)
    ctx.setFillColor(item.color.cgColor)
    if item.kind == .text {
      guard !item.text.isEmpty else { return }
      let box = AnnotationGeometry.textBox(item, in: size)
      ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      ctx.textPosition = CGPoint(x: box.rect.minX, y: box.rect.minY + box.ascent)
      CTLineDraw(AnnotationGeometry.textLine(item, in: size), ctx)
      return
    }
    guard let path = AnnotationGeometry.path(for: item, in: size) else { return }
    ctx.setLineWidth(AnnotationGeometry.strokeWidth(item, in: size))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
  }
}
