// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Convert

/// Synthetic images and temporary files for the tool tests.
private enum Fixture {
  static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  static func solid(width: Int = 32, height: Int = 24, gray: Double) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setFillColor(
      CGColor(colorSpace: space, components: [gray, gray, gray, 1]) ?? CGColor(gray: gray, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context?.makeImage() ?? CGImage.empty
  }

  /// Gradient with noise: gives the PNG something to compress.
  static func noisy(width: Int = 96, height: Int = 96) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    if let base = context?.data, let bytesPerRow = context?.bytesPerRow {
      let pixels = base.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
      var seed: UInt32 = 12345
      for row in 0..<height {
        for column in 0..<width {
          seed = seed &* 1_664_525 &+ 1_013_904_223
          let noise = Int(seed >> 24) % 24
          let offset = row * bytesPerRow + column * 4
          pixels[offset] = UInt8(min(255, column * 2 + noise))
          pixels[offset + 1] = UInt8(min(255, row * 2 + noise))
          pixels[offset + 2] = UInt8(min(255, 100 + noise))
          pixels[offset + 3] = 255
        }
      }
    }
    return context?.makeImage() ?? CGImage.empty
  }

  /// Red, green, blue of pixel (x, y), in 0…255.
  struct RGB: Equatable {
    let red: Int
    let green: Int
    let blue: Int
  }

  static func pixel(_ image: CGImage, column: Int = 0, row: Int = 0) -> RGB {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(image, in: CGRect(x: -column, y: -(image.height - 1 - row), width: image.width, height: image.height))
    return RGB(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
  }

  static func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  static func write(
    _ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]
  ) throws -> URL {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    let finished = CGImageDestinationFinalize(destination)
    #expect(finished)
    return url
  }

  static func richProperties() -> [CFString: Any] {
    [
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:01:01 10:00:00", kCGImagePropertyExifFNumber: 2.8,
      ],
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 46.0, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 8.9, kCGImagePropertyGPSLongitudeRef: "E",
      ],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "ACME", kCGImagePropertyTIFFModel: "X1"],
      kCGImagePropertyIPTCDictionary: [
        kCGImagePropertyIPTCByline: ["Mario"], kCGImagePropertyIPTCCaptionAbstract: "Ciao",
      ],
    ]
  }
}

extension CGImage {
  fileprivate static var empty: CGImage {
    // Not reachable in practice: only serves to avoid force unwraps in the tests.
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: Fixture.space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    return context?.makeImage() ?? { fatalError("CGContext unavailable") }()
  }
}

@Suite("Edit Photo: Core Image engine")
struct ImageEditingEngineTests {
  private let engine = ImageEditingEngine()

  @Test("neutral adjustments return the image intact")
  func neutral() {
    let image = Fixture.solid(gray: 0.5)
    let output = engine.render(image, adjustments: EditAdjustments())
    #expect(output === image)
  }

  @Test("positive exposure lightens, negative darkens")
  func exposure() throws {
    let image = Fixture.solid(gray: 0.4)
    let base = Fixture.pixel(image).red
    let brighter = try #require(engine.render(image, adjustments: EditAdjustments(exposure: 1)))
    let darker = try #require(engine.render(image, adjustments: EditAdjustments(exposure: -1)))
    #expect(Fixture.pixel(brighter).red > base + 20)
    #expect(Fixture.pixel(darker).red < base - 20)
    #expect(brighter.width == image.width && brighter.height == image.height)
  }

  @Test("brightness and contrast change pixels in the right direction")
  func brightnessAndContrast() throws {
    let mid = Fixture.solid(gray: 0.5)
    let bright = try #require(engine.render(mid, adjustments: EditAdjustments(brightness: 60)))
    #expect(Fixture.pixel(bright).red > Fixture.pixel(mid).red + 10)
    // Contrast pushes values away from mid grey (0.5 in sRGB space).
    let light = Fixture.solid(gray: 0.7)
    let dark = Fixture.solid(gray: 0.3)
    let lightOut = try #require(engine.render(light, adjustments: EditAdjustments(contrast: 80)))
    let darkOut = try #require(engine.render(dark, adjustments: EditAdjustments(contrast: 80)))
    #expect(Fixture.pixel(lightOut).red > Fixture.pixel(light).red)
    #expect(Fixture.pixel(darkOut).red < Fixture.pixel(dark).red)
    let flat = try #require(engine.render(light, adjustments: EditAdjustments(contrast: -80)))
    #expect(Fixture.pixel(flat).red < Fixture.pixel(light).red)
  }

  @Test("negative highlights darken bright areas; positive shadows lighten dark ones")
  func highlightsAndShadows() throws {
    let light = Fixture.solid(gray: 0.85)
    let dark = Fixture.solid(gray: 0.15)
    let tamed = try #require(engine.render(light, adjustments: EditAdjustments(highlights: -100)))
    let lifted = try #require(engine.render(dark, adjustments: EditAdjustments(shadows: 100)))
    #expect(Fixture.pixel(tamed).red < Fixture.pixel(light).red)
    #expect(Fixture.pixel(lifted).red > Fixture.pixel(dark).red)
  }

  @Test("positive highlights lighten bright areas")
  func highlightsUp() throws {
    let light = Fixture.solid(gray: 0.75)
    let output = try #require(engine.render(light, adjustments: EditAdjustments(highlights: 100)))
    #expect(Fixture.pixel(output).red > Fixture.pixel(light).red)
  }
}

@Suite("Add BG: composition")
struct BackgroundCompositorTests {
  @Test("the canvas is about 8% larger than the image per side")
  func canvas() {
    let size = BackgroundCompositor.canvasSize(for: CGSize(width: 1000, height: 500))
    #expect(size == CGSize(width: 1160, height: 660))
  }

  @Test("the image sits in the center and the background fills the corners")
  func composition() throws {
    let image = Fixture.solid(width: 100, height: 100, gray: 1)
    let output = try #require(BackgroundCompositor.render(image, style: .color(RGBAColor(1, 0, 0))))
    #expect(output.width == 116 && output.height == 116)
    let corner = Fixture.pixel(output, column: 0, row: 0)
    #expect(corner.red > 240 && corner.green < 15 && corner.blue < 15)
    let center = Fixture.pixel(output, column: 58, row: 58)
    #expect(center.red > 240 && center.green > 240 && center.blue > 240)
  }

  @Test("the gradient changes color from the top corner to the bottom corner")
  func gradient() throws {
    let image = Fixture.solid(width: 40, height: 40, gray: 0.5)
    let output = try #require(BackgroundCompositor.render(image, style: .gradient(0)))
    let top = Fixture.pixel(output, column: 0, row: 0)
    let bottom = Fixture.pixel(output, column: output.width - 1, row: output.height - 1)
    #expect(top.red != bottom.red || top.green != bottom.green || top.blue != bottom.blue)
  }

  @Test("there are 10 gradients and 10 solid colors")
  func presets() {
    #expect(BackgroundPresets.gradients.count == 10)
    #expect(BackgroundPresets.solids.count == 10)
  }

  @Test("a background image fills the canvas")
  func imageBackground() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let backgroundFile = try Fixture.write(
      Fixture.solid(width: 200, height: 100, gray: 0), to: folder.appendingPathComponent("background.png"), type: .png)
    let image = Fixture.solid(width: 40, height: 40, gray: 1)
    let output = try #require(BackgroundCompositor.render(image, style: .image(backgroundFile)))
    #expect(Fixture.pixel(output, column: 0, row: 0).red < 20)
  }

  @Test("saves a PNG with the -background suffix without touching the original")
  func savePNG() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try Fixture.write(
      Fixture.solid(gray: 0.5), to: folder.appendingPathComponent("photo.jpg"), type: .jpeg)
    let composed = try #require(BackgroundCompositor.render(try ToolImage.load(source), style: .solid(0)))
    let output = try BackgroundCompositor.savePNG(composed, like: source, suffix: "-background")
    #expect(output.lastPathComponent == "photo-background.png")
    #expect(FileManager.default.fileExists(atPath: source.path))
    let reloaded = try ToolImage.load(output)
    #expect(reloaded.width == composed.width)
  }
}

@Suite("Compress: compression")
struct ImageCompressorTests {
  @Test("the output format follows the input format, the rest goes to JPEG")
  func kinds() {
    #expect(ImageCompressor.kind(for: URL(fileURLWithPath: "/tmp/a.png")).fileExtension == "png")
    #expect(ImageCompressor.kind(for: URL(fileURLWithPath: "/tmp/a.jpeg")).fileExtension == "jpg")
    #expect(ImageCompressor.kind(for: URL(fileURLWithPath: "/tmp/a.tiff")).fileExtension == "jpg")
    #expect(ImageCompressor.kind(for: URL(fileURLWithPath: "/tmp/a.heic")).fileExtension != "png")
  }

  @Test("lower quality gives a smaller JPEG")
  func jpegQuality() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try Fixture.write(Fixture.noisy(), to: folder.appendingPathComponent("a.jpg"), type: .jpeg)
    let high = try ImageCompressor.encode(source, quality: 1.0, scale: .original)
    let low = try ImageCompressor.encode(source, quality: 0.1, scale: .original)
    #expect(low.data.count < high.data.count)
    #expect(low.fileExtension == "jpg")
  }

  @Test("resizing reduces the pixel dimensions")
  func scale() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try Fixture.write(
      Fixture.noisy(width: 96, height: 64), to: folder.appendingPathComponent("a.jpg"), type: .jpeg)
    let half = try ImageCompressor.encode(source, quality: 0.8, scale: .half)
    let imageSource = try #require(CGImageSourceCreateWithData(half.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.width == 48 && image.height == 32)
  }

  @Test("the quantized PNG is smaller than the lossless one")
  func pngQuantization() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try Fixture.write(Fixture.noisy(), to: folder.appendingPathComponent("a.png"), type: .png)
    let lossless = try ImageCompressor.encode(source, quality: 1.0, scale: .original)
    let reduced = try ImageCompressor.encode(source, quality: 0.2, scale: .original)
    #expect(reduced.data.count < lossless.data.count)
    #expect(reduced.fileExtension == "png")
    #expect(ImageCompressor.quantizationStep(quality: 1.0) == 1)
    #expect(ImageCompressor.quantizationStep(quality: 0.6) == 4)
  }

  @Test("compress writes next to the original with the -compressed suffix and reports the bytes")
  func writes() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try Fixture.write(
      Fixture.noisy(), to: folder.appendingPathComponent("a.jpg"), type: .jpeg,
      properties: [
        kCGImageDestinationLossyCompressionQuality: 1.0
      ])
    let result = try ImageCompressor.compress(source, quality: 0.2, scale: .original)
    #expect(result.output.lastPathComponent == "a-compressed.jpg")
    #expect(result.after == ImageCompressor.fileSize(result.output))
    #expect(result.after < result.before)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }
}

@Suite("Metadata: reading and removal")
struct ImageMetadataTests {
  private func makeSource(_ folder: URL, name: String = "photo.jpg") throws -> URL {
    try Fixture.write(
      Fixture.noisy(width: 64, height: 48), to: folder.appendingPathComponent(name), type: .jpeg,
      properties: Fixture.richProperties())
  }

  @Test("groups collect EXIF, GPS, camera and IPTC with readable entries")
  func groups() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let groups = ImageMetadata.groups(of: try makeSource(folder))
    let titles = Set(groups.map(\.title))
    #expect(titles.contains("EXIF") && titles.contains("Camera"))
    #expect(titles.contains("GPS Location") && titles.contains("IPTC / Author"))
    let gps = try #require(groups.first { $0.category == .gps })
    #expect(gps.entries.contains { $0.key == "Latitude" && $0.value == "46" })
    #expect(ImageMetadata.count(of: .gps, in: groups) >= 4)
    #expect(ImageMetadata.count(of: .all, in: groups) > ImageMetadata.count(of: .gps, in: groups))
  }

  @Test("humanize and format")
  func formatting() {
    #expect(ImageMetadata.humanize("DateTimeOriginal") == "Date Time Original")
    #expect(ImageMetadata.format(["Mario", "Rossi"]) == "Mario, Rossi")
    #expect(ImageMetadata.format(2.5) == "2.5" || ImageMetadata.format(2.5) == "2,5")
    #expect(ImageMetadata.format("") == nil)
  }

  @Test("removing GPS leaves the rest")
  func stripGPS() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try makeSource(folder)
    let output = try ImageMetadata.strip(source, removing: [.gps])
    #expect(output.lastPathComponent == "photo-no-metadata.jpg")
    let properties = ImageMetadata.properties(of: output)
    #expect((properties["{GPS}"] as? [String: Any])?.isEmpty ?? true)
    #expect(!((properties["{IPTC}"] as? [String: Any])?.isEmpty ?? true))
    #expect(!((properties["{TIFF}"] as? [String: Any])?["Make"] == nil))
  }

  @Test("removing camera/EXIF leaves GPS and IPTC")
  func stripCamera() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = try ImageMetadata.strip(try makeSource(folder), removing: [.camera])
    let properties = ImageMetadata.properties(of: output)
    #expect(!ImageMetadata.hasResidue(properties, categories: [.camera]))
    #expect(!((properties["{GPS}"] as? [String: Any])?.isEmpty ?? true))
  }

  @Test("removing IPTC leaves GPS and EXIF")
  func stripIPTC() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = try ImageMetadata.strip(try makeSource(folder), removing: [.iptc])
    let properties = ImageMetadata.properties(of: output)
    #expect((properties["{IPTC}"] as? [String: Any])?.isEmpty ?? true)
    #expect(!((properties["{GPS}"] as? [String: Any])?.isEmpty ?? true))
  }

  @Test("removing everything leaves no trace")
  func stripAll() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = try ImageMetadata.strip(try makeSource(folder), removing: [.all])
    #expect(!ImageMetadata.hasResidue(ImageMetadata.properties(of: output), categories: [.all]))
  }

  @Test("without re-encoding the pixels stay identical")
  func pixelsUnchanged() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try makeSource(folder)
    let output = try ImageMetadata.strip(source, removing: [.all])
    let before = try ToolImage.load(source)
    let after = try ToolImage.load(output)
    #expect(before.width == after.width && before.height == after.height)
    for (column, row) in [(0, 0), (10, 20), (63, 47)] {
      let first = Fixture.pixel(before, column: column, row: row)
      let second = Fixture.pixel(after, column: column, row: row)
      #expect(first == second)
    }
  }

  @Test("a PNG without metadata is still copied")
  func png() throws {
    let folder = try Fixture.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try Fixture.write(Fixture.noisy(), to: folder.appendingPathComponent("a.png"), type: .png)
    let output = try ImageMetadata.strip(source, removing: [.all])
    #expect(output.lastPathComponent == "a-no-metadata.png")
  }

  @Test("the re-encoding fallback carries only what remains")
  func carried() {
    let properties: [String: Any] = [
      "{GPS}": ["Latitude": 1.0], "{IPTC}": ["Byline": "x"],
      "{Exif}": ["FNumber": 2.8, "PixelXDimension": 10], "{TIFF}": ["Make": "A", "Orientation": 6],
    ]
    let withoutGPS = ImageMetadata.carriedProperties(from: properties, removing: [.gps])
    #expect(withoutGPS[kCGImagePropertyGPSDictionary] == nil)
    #expect(withoutGPS[kCGImagePropertyIPTCDictionary] != nil)
    let exif = withoutGPS[kCGImagePropertyExifDictionary] as? [String: Any]
    #expect(exif?["PixelXDimension"] == nil && exif?["FNumber"] != nil)
    let tiff = withoutGPS[kCGImagePropertyTIFFDictionary] as? [String: Any]
    #expect(tiff?["Orientation"] == nil && tiff?["Make"] != nil)
    #expect(ImageMetadata.carriedProperties(from: properties, removing: [.all]).isEmpty)
  }
}
