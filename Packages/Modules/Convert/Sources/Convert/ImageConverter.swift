// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

enum ConversionError: Error, Equatable {
  case unreadable(String)
  case unwritable(String)
}

/// Tier 0 conversions with ImageIO and PDFKit: no dependencies, no
/// external process. The original is never touched; the output goes next to it.
enum ImageConverter {
  /// JPEG, HEIC and AVIF quality: high, like Preview's default export.
  static let lossyQuality = 0.9

  /// Converts a file and returns the files created (more than one for a multi-page PDF).
  static func convert(_ source: URL, to format: OutputFormat) throws(ConversionError) -> [URL] {
    let isPDF = source.pathExtension.lowercased() == "pdf"
    if isPDF { return try convertPDF(source, to: format) }
    if format == .pdf { return [try imageToPDF(source)] }
    return [try convertImage(source, to: format)]
  }

  private static func convertImage(_ source: URL, to format: OutputFormat) throws(ConversionError) -> URL {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(input) > 0 else {
      throw .unreadable(source.lastPathComponent)
    }
    let output = OutputNamer.url(for: source, extension: format.fileExtension)
    guard
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL, format.type.identifier as CFString, 1, nil)
    else { throw .unwritable(output.lastPathComponent) }
    let options = [kCGImageDestinationLossyCompressionQuality: lossyQuality] as CFDictionary
    if format.isOpaque, let image = CGImageSourceCreateImageAtIndex(input, 0, nil), hasAlpha(image) {
      // JPG and BMP have no transparency: without a white background it would turn black.
      guard let flat = flatten(image) else { throw .unreadable(source.lastPathComponent) }
      let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil)
      CGImageDestinationAddImage(destination, flat, properties)
      CGImageDestinationSetProperties(destination, options)
    } else {
      // Also copies the metadata (orientation, colour profile, EXIF).
      CGImageDestinationAddImageFromSource(destination, input, 0, options)
    }
    guard CGImageDestinationFinalize(destination) else { throw .unwritable(output.lastPathComponent) }
    return output
  }

  /// Copies an image to PNG with the orientation applied (input for ffmpeg).
  static func writePNG(_ source: URL, to output: URL) throws(ConversionError) {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        input, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 16384,
        ] as CFDictionary)
    else { throw .unreadable(source.lastPathComponent) }
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)
    else { throw .unwritable(output.lastPathComponent) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw .unwritable(output.lastPathComponent) }
  }

  private static func imageToPDF(_ source: URL) throws(ConversionError) -> URL {
    guard let image = NSImage(contentsOf: source), let page = PDFPage(image: image) else {
      throw .unreadable(source.lastPathComponent)
    }
    let document = PDFDocument()
    document.insert(page, at: 0)
    let output = OutputNamer.url(for: source, extension: "pdf")
    guard document.write(to: output) else { throw .unwritable(output.lastPathComponent) }
    return output
  }

  /// Each page becomes a 144 dpi image on a white background.
  private static func convertPDF(_ source: URL, to format: OutputFormat) throws(ConversionError) -> [URL] {
    guard let document = PDFDocument(url: source), document.pageCount > 0 else {
      throw .unreadable(source.lastPathComponent)
    }
    var outputs: [URL] = []
    var pending: URL?
    do {
      for index in 0..<document.pageCount {
        guard let page = document.page(at: index), let image = render(page, scale: 2) else {
          throw ConversionError.unreadable(source.lastPathComponent)
        }
        let suffix = pageSuffix(index: index, count: document.pageCount)
        let output = OutputNamer.url(for: source, extension: format.fileExtension, suffix: suffix)
        pending = output
        guard
          let destination = CGImageDestinationCreateWithURL(
            output as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw ConversionError.unwritable(output.lastPathComponent) }
        CGImageDestinationAddImage(
          destination, image, [kCGImageDestinationLossyCompressionQuality: lossyQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
          throw ConversionError.unwritable(output.lastPathComponent)
        }
        outputs.append(output)
        pending = nil
      }
    } catch {
      // A half-written image or the pages already written are of no use to anyone.
      for url in outputs + [pending].compactMap(\.self) { try? FileManager.default.removeItem(at: url) }
      throw (error as? ConversionError) ?? .unreadable(source.lastPathComponent)
    }
    return outputs
  }

  /// "-01", "-02"… with leading zeros: the files stay in order in Finder.
  /// A single-page PDF has no suffix.
  static func pageSuffix(index: Int, count: Int) -> String {
    guard count > 1 else { return "" }
    let width = String(count).count
    let number = String(index + 1)
    return "-" + String(repeating: "0", count: max(width - number.count, 0)) + number
  }

  private static func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: false
    default: true
    }
  }

  private static func whiteContext(width: Int, height: Int) -> CGContext? {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
    context?.setFillColor(CGColor(gray: 1, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context
  }

  private static func flatten(_ image: CGImage) -> CGImage? {
    let context = whiteContext(width: image.width, height: image.height)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context?.makeImage()
  }

  private static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let width = max(Int(bounds.width * scale), 1)
    let height = max(Int(bounds.height * scale), 1)
    guard let context = whiteContext(width: width, height: height) else { return nil }
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
  }
}
