// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ToolImageError: LocalizedError {
  case unreadable(String)
  case unwritable(String)

  var errorDescription: String? {
    switch self {
    case .unreadable(let name): String(localized: "Can't read \(name)")
    case .unwritable(let name): String(localized: "Can't save \(name)")
    }
  }
}

/// Reading and writing images for the tools: the original is never touched,
/// the result goes next to it with a suffix (`OutputNamer`).
enum ToolImage {
  /// Image with the orientation already applied. `maxPixel` limits the long side (for previews).
  static func load(_ url: URL, maxPixel: Int = 16384) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw ToolImageError.unreadable(url.lastPathComponent)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw ToolImageError.unreadable(url.lastPathComponent)
    }
    return image
  }

  /// Saves in the same format as the original (PNG if that format cannot be written).
  /// `properties` are ImageIO metadata to write (nil: none).
  @discardableResult
  static func save(
    _ image: CGImage, like source: URL, suffix: String, quality: Double = 0.9,
    properties: [CFString: Any]? = nil
  ) throws -> URL {
    var type = UTType(filenameExtension: source.pathExtension.lowercased()) ?? .png
    let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    if !writable.contains(type.identifier) { type = .png }
    let ext = type.preferredFilenameExtension ?? "png"
    let output = OutputNamer.url(for: source, extension: ext, suffix: suffix)
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
      throw ToolImageError.unwritable(output.lastPathComponent)
    }
    var options: [CFString: Any] = properties ?? [:]
    options[kCGImageDestinationLossyCompressionQuality] = quality
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ToolImageError.unwritable(output.lastPathComponent) }
    return output
  }
}
