// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Convert

// MARK: - Helpers

private let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

private struct Pixels {
  let width: Int
  let height: Int
  let data: [UInt8]  // RGBA, row 0 at the top

  func color(_ col: Int, _ row: Int) -> [UInt8] {
    let offset = (row * width + col) * 4
    return Array(data[offset..<offset + 4])
  }
}

private func pixels(of image: CGImage) -> Pixels {
  let width = image.width
  let height = image.height
  var data = [UInt8](repeating: 0, count: width * height * 4)
  let space = srgb
  data.withUnsafeMutableBytes { buffer in
    let ctx = CGContext(
      data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  return Pixels(width: width, height: height, data: data)
}

/// Opaque sRGB image generated pixel by pixel (row 0 at the top).
private struct RGB {
  var red: UInt8
  var green: UInt8
  var blue: UInt8

  init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }
}

private func makeImage(width: Int, height: Int, _ pixel: (Int, Int) -> RGB) -> CGImage {
  var data = [UInt8](repeating: 255, count: width * height * 4)
  for row in 0..<height {
    for col in 0..<width {
      let color = pixel(col, row)
      let offset = (row * width + col) * 4
      data[offset] = color.red
      data[offset + 1] = color.green
      data[offset + 2] = color.blue
    }
  }
  guard let provider = CGDataProvider(data: Data(data) as CFData),
    let image = CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: srgb,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)
  else { preconditionFailure("test image not created") }
  return image
}

private func noise(_ col: Int, _ row: Int) -> RGB {
  let seed = (col &* 73_856_093) ^ (row &* 19_349_663)
  let bytes = (0..<3).map { UInt8(truncatingIfNeeded: seed >> ($0 * 8)) }
  return RGB(bytes[0], bytes[1], bytes[2])
}

private func white(_ width: Int, _ height: Int) -> CGImage {
  makeImage(width: width, height: height) { _, _ in RGB(255, 255, 255) }
}

// MARK: - CropGeometry

@Suite("Crop: image rotations")
struct ImageOpsTests {
  /// 2×1: red on the left, blue on the right.
  private var sample: CGImage {
    makeImage(width: 2, height: 1) { col, _ in col == 0 ? RGB(255, 0, 0) : RGB(0, 0, 255) }
  }

  @Test("right: red goes to the top")
  func rotateRight() throws {
    let out = try #require(ImageOp.rotateRight.apply(to: sample))
    let map = pixels(of: out)
    #expect(map.width == 1 && map.height == 2)
    #expect(map.color(0, 0) == [255, 0, 0, 255])
    #expect(map.color(0, 1) == [0, 0, 255, 255])
  }

  @Test("left: red goes to the bottom")
  func rotateLeft() throws {
    let out = try #require(ImageOp.rotateLeft.apply(to: sample))
    let map = pixels(of: out)
    #expect(map.width == 1 && map.height == 2)
    #expect(map.color(0, 0) == [0, 0, 255, 255])
    #expect(map.color(0, 1) == [255, 0, 0, 255])
  }

  @Test("flip: right and left swap")
  func flip() throws {
    let out = try #require(ImageOp.flipHorizontal.apply(to: sample))
    let map = pixels(of: out)
    #expect(map.width == 2 && map.height == 1)
    #expect(map.color(0, 0) == [0, 0, 255, 255])
    #expect(map.color(1, 0) == [255, 0, 0, 255])
  }

  @Test("four rotations return to the original")
  func fullTurn() {
    let out = ImageOp.apply(Array(repeating: .rotateRight, count: 4), to: sample)
    #expect(pixels(of: out).data == pixels(of: sample).data)
  }
}

// MARK: - Annotations

@Suite("Annotations")
struct AnnotationTests {
  private let red = AnnotationColor(red: 1, green: 0, blue: 0)

  @Test("the model serializes and deserializes")
  func codable() throws {
    let item = Annotation(
      kind: .freehand, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.6)], color: red, lineWidth: 0.01,
      text: "hello")
    let data = try JSONEncoder().encode([item])
    let back = try JSONDecoder().decode([Annotation].self, from: data)
    #expect(back == [item])
  }

  @Test("the rectangle draws the border and leaves the inside and outside empty")
  func rectangle() throws {
    let item = Annotation(
      kind: .rectangle, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)], color: red, lineWidth: 0.04)
    let out = try #require(AnnotationRenderer.render([item], onto: white(100, 100)))
    let map = pixels(of: out)
    #expect(map.color(20, 50) == [255, 0, 0, 255])  // left edge
    #expect(map.color(50, 20) == [255, 0, 0, 255])  // top edge
    #expect(map.color(80, 80) == [255, 0, 0, 255])  // bottom-right corner
    #expect(map.color(50, 50) == [255, 255, 255, 255])  // inside
    #expect(map.color(5, 5) == [255, 255, 255, 255])  // outside
  }

  @Test("the same model at double resolution gives the same drawing")
  func resolutionIndependent() throws {
    let item = Annotation(
      kind: .oval, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)], color: red, lineWidth: 0.05)
    let small = pixels(of: try #require(AnnotationRenderer.render([item], onto: white(100, 100))))
    let big = pixels(of: try #require(AnnotationRenderer.render([item], onto: white(200, 200))))
    // The left edge of the oval: x = 10% (circle), vertical centre.
    #expect(small.color(10, 50) == [255, 0, 0, 255])
    #expect(big.color(20, 100) == [255, 0, 0, 255])
    #expect(small.color(50, 50) == [255, 255, 255, 255])
    #expect(big.color(100, 100) == [255, 255, 255, 255])
  }

  @Test("the arrow has a shaft and head; the line only the shaft")
  func arrowAndLine() throws {
    let points = [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)]
    let arrow = Annotation(kind: .arrow, points: points, color: red, lineWidth: 0.02)
    let line = Annotation(kind: .line, points: points, color: red, lineWidth: 0.02)
    let withHead = pixels(of: try #require(AnnotationRenderer.render([arrow], onto: white(200, 100))))
    let plain = pixels(of: try #require(AnnotationRenderer.render([line], onto: white(200, 100))))
    #expect(withHead.color(100, 50) == [255, 0, 0, 255])
    #expect(plain.color(100, 50) == [255, 0, 0, 255])
    // The arrowhead barbs fall above and below the shaft, near the end.
    #expect(withHead.color(170, 44) != [255, 255, 255, 255])
    #expect(plain.color(170, 44) == [255, 255, 255, 255])
  }

  @Test("freehand passes through the points")
  func freehand() throws {
    let item = Annotation(
      kind: .freehand, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.9)],
      color: red, lineWidth: 0.03)
    let map = pixels(of: try #require(AnnotationRenderer.render([item], onto: white(100, 100))))
    #expect(map.color(40, 20) == [255, 0, 0, 255])  // curve that rounds the corner
    #expect(map.color(50, 60) == [255, 0, 0, 255])
    #expect(map.color(20, 80) == [255, 255, 255, 255])
  }

  @Test("text colors pixels near its point and nowhere else")
  func text() throws {
    let item = Annotation(
      kind: .text, points: [CGPoint(x: 0.1, y: 0.1)], color: AnnotationColor(red: 0, green: 0, blue: 0),
      lineWidth: 0.01, text: "HHHH")
    let map = pixels(of: try #require(AnnotationRenderer.render([item], onto: white(300, 150))))
    var inside = 0
    var outside = 0
    for row in 0..<map.height {
      for col in 0..<map.width where map.color(col, row) != [255, 255, 255, 255] {
        if col >= 30, col < 150, row >= 15, row < 60 { inside += 1 } else { outside += 1 }
      }
    }
    #expect(inside > 50)
    #expect(outside == 0)
  }

  @Test("empty text draws nothing")
  func emptyText() throws {
    let item = Annotation(kind: .text, points: [CGPoint(x: 0.1, y: 0.1)], color: red, lineWidth: 0.01)
    let out = try #require(AnnotationRenderer.render([item], onto: white(50, 50)))
    #expect(pixels(of: out).data == pixels(of: white(50, 50)).data)
  }

  @Test("selection: hits land on the stroke, not on empty space; moving translates the points")
  func hitAndMove() {
    let size = CGSize(width: 100, height: 100)
    let item = Annotation(
      kind: .line, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], color: red, lineWidth: 0.02)
    #expect(AnnotationGeometry.hit(item, at: CGPoint(x: 50, y: 52), in: size, tolerance: 4))
    #expect(!AnnotationGeometry.hit(item, at: CGPoint(x: 50, y: 80), in: size, tolerance: 4))
    let moved = AnnotationGeometry.moved(item, by: CGPoint(x: 0.1, y: 0.2))
    #expect(moved.points == [CGPoint(x: 0.2, y: 0.7), CGPoint(x: 1.0, y: 0.7)])
    #expect(moved.id == item.id)
  }

  @Test("undo and redo")
  func history() {
    var history = EditHistory<[Int]>([])
    history.commit([1])
    history.commit([1, 2])
    history.commit([1, 2])  // equal: no step
    #expect(history.canUndo)
    history.undo()
    #expect(history.current == [1])
    #expect(history.canRedo)
    history.redo()
    #expect(history.current == [1, 2])
    history.undo()
    history.commit([9])  // a new step clears redo
    #expect(!history.canRedo)
    history.replaceCurrent([9, 9])
    history.undo()
    #expect(history.current == [1])
  }

  @Test("ImageFit fits the image and converts coordinates")
  func fit() {
    let fit = ImageFit(container: CGSize(width: 400, height: 200), imageSize: CGSize(width: 100, height: 100))
    #expect(fit.rect == CGRect(x: 100, y: 0, width: 200, height: 200))
    #expect(fit.viewPoint(CGPoint(x: 0.5, y: 0.5)) == CGPoint(x: 200, y: 100))
    #expect(fit.normalized(CGPoint(x: 100, y: 0)) == .zero)
    #expect(fit.normalized(CGPoint(x: 0, y: 500)) == CGPoint(x: 0, y: 1))
    #expect(fit.normalized(CGPoint(x: 0, y: 0), clamped: false).x == -0.5)
  }
}

// MARK: - RedactEngine

@Suite("Redaction")
struct RedactEngineTests {
  private let region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

  private func inside(_ col: Int, _ row: Int, _ size: Int) -> Bool {
    let low = Int(Double(size) * 0.25)
    let high = Int(Double(size) * 0.75)
    return col >= low && col < high && row >= low && row < high
  }

  private func run(_ style: RedactStyle, size: Int = 160) throws -> (before: Pixels, after: Pixels) {
    let source = makeImage(width: size, height: size, noise)
    let out = try RedactEngine.apply([RedactRegion(rect: region, style: style)], to: source)
    #expect(out.width == size && out.height == size)
    return (pixels(of: source), pixels(of: out))
  }

  @Test("outside the zone pixels stay identical, inside they change (all styles)", arguments: RedactStyle.allCases)
  func outsideUntouched(_ style: RedactStyle) throws {
    let size = 160
    let (before, after) = try run(style, size: size)
    var changed = 0
    for row in 0..<size {
      for col in 0..<size {
        if inside(col, row, size) {
          if before.color(col, row) != after.color(col, row) { changed += 1 }
        } else {
          #expect(before.color(col, row) == after.color(col, row))
        }
      }
    }
    #expect(changed > (size / 2) * (size / 2) * 9 / 10)
  }

  @Test("solid black is black everywhere in the zone")
  func black() throws {
    let (_, after) = try run(.black)
    for row in 40..<120 {
      for col in 40..<120 { #expect(after.color(col, row) == [0, 0, 0, 255]) }
    }
  }

  @Test("pixelation makes large blocks: few distinct colors and no fine detail")
  func pixelate() throws {
    let (before, after) = try run(.pixelate)
    var colors = Set<[UInt8]>()
    var beforeColors = Set<[UInt8]>()
    for row in 45..<115 {
      for col in 45..<115 {
        colors.insert(after.color(col, row))
        beforeColors.insert(before.color(col, row))
      }
    }
    #expect(colors.count < 40)
    #expect(beforeColors.count > 1000)
  }

  @Test("the blur is much more uniform than the original")
  func blur() throws {
    let (before, after) = try run(.blur)
    func spread(_ map: Pixels) -> Int {
      var low = 255
      var high = 0
      for row in 60..<100 {
        for col in 60..<100 {
          let value = Int(map.color(col, row)[0])
          low = min(low, value)
          high = max(high, value)
        }
      }
      return high - low
    }
    #expect(spread(before) > 200)
    #expect(spread(after) < 80)
  }

  @Test("a zone outside the image or empty does nothing; a zone on the edge stays inside")
  func edges() throws {
    let source = makeImage(width: 40, height: 40, noise)
    let regions = [
      RedactRegion(rect: CGRect(x: 2, y: 2, width: 0.5, height: 0.5), style: .black),
      RedactRegion(rect: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), style: .black),
      RedactRegion(rect: CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5), style: .black),
    ]
    let out = pixels(of: try RedactEngine.apply(regions, to: source))
    let orig = pixels(of: source)
    #expect(out.color(5, 5) == orig.color(5, 5))
    #expect(out.color(39, 39) == [0, 0, 0, 255])
    #expect(out.color(31, 31) == orig.color(31, 31))
  }

  @Test("blocks and radius scale with the zone and the image")
  func parameters() {
    let big = CGSize(width: 4000, height: 3000)
    let strip = CGRect(x: 0, y: 0, width: 600, height: 40)
    #expect(RedactEngine.blockSize(for: strip, imageSize: big) >= 35)
    #expect(RedactEngine.blurRadius(for: strip, imageSize: big) >= 40)
    let area = CGRect(x: 0, y: 0, width: 800, height: 600)
    #expect(RedactEngine.blockSize(for: area, imageSize: big) >= 200)
    let tiny = CGRect(x: 0, y: 0, width: 5, height: 5)
    #expect(RedactEngine.blockSize(for: tiny, imageSize: big) <= 5)
  }

  @Test("the saved image carries no metadata from the original and the pixels are destroyed")
  func savedFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("redact-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("photo.png")
    // Original with metadata (TIFF description) to verify it does not pass through.
    let original = makeImage(width: 64, height: 64, noise)
    let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "segreto"]]
    let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, original, props as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let loaded = try ToolImage.load(source)
    let result = try RedactEngine.apply(
      [RedactRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1), style: .black)], to: loaded)
    let saved = try ToolImage.save(result, like: source, suffix: "-redacted")
    #expect(saved.lastPathComponent == "photo-redacted.png")

    let reread = try #require(CGImageSourceCreateWithURL(saved as CFURL, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(reread, 0, nil) as? [CFString: Any] ?? [:]
    #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
    let image = try ToolImage.load(saved)
    #expect(pixels(of: image).color(10, 10) == [0, 0, 0, 255])
  }
}
