// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Engine

/// How much to resize before compressing.
enum CompressionScale: Double, CaseIterable, Hashable, Sendable {
  case original = 1
  case threeQuarters = 0.75
  case half = 0.5

  var title: LocalizedStringKey {
    switch self {
    case .original: "Original"
    case .threeQuarters: "75%"
    case .half: "50%"
    }
  }
}

/// Already-encoded image, ready to write.
struct EncodedImage: Sendable {
  let data: Data
  let fileExtension: String
}

/// Image recompression: JPEG and HEIC with quality, PNG with colour reduction, the rest as JPEG.
enum ImageCompressor {
  enum Kind: Sendable {
    case jpeg, heic, png

    var type: UTType {
      switch self {
      case .jpeg: .jpeg
      case .heic: .heic
      case .png: .png
      }
    }

    var fileExtension: String {
      switch self {
      case .jpeg: "jpg"
      case .heic: "heic"
      case .png: "png"
      }
    }
  }

  static func kind(for url: URL) -> Kind {
    let type = UTType(filenameExtension: url.pathExtension.lowercased())
    if type?.conforms(to: .png) == true { return .png }
    if type?.conforms(to: .heic) == true || type?.conforms(to: .heif) == true {
      let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
      return writable.contains(UTType.heic.identifier) ? .heic : .jpeg
    }
    return .jpeg
  }

  /// Channel quantisation step for PNGs: 1 = lossless (from 95% quality upwards).
  static func quantizationStep(quality: Double) -> Int {
    quality >= 0.95 ? 1 : 1 + Int((0.95 - quality) * 10)
  }

  /// Encodes `url` with the given quality (0.1…1) and scale, without writing to disk.
  static func encode(_ url: URL, quality: Double, scale: CompressionScale) throws -> EncodedImage {
    let kind = kind(for: url)
    let properties = ImageMetadata.properties(of: url)
    let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
    let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
    let longSide = max(width, height)
    let target = longSide > 0 ? max(1, Int((Double(longSide) * scale.rawValue).rounded())) : 16384

    var image = try ToolImage.load(url, maxPixel: target)
    var options: [CFString: Any] = [:]
    switch kind {
    case .png:
      let step = quantizationStep(quality: quality)
      if step > 1, let reduced = quantized(image, step: step) { image = reduced }
    case .jpeg, .heic:
      options = ImageMetadata.carriedProperties(from: properties, removing: [])
      options[kCGImageDestinationLossyCompressionQuality] = quality
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, kind.type.identifier as CFString, 1, nil) else {
      throw ToolImageError.unwritable(url.lastPathComponent)
    }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ToolImageError.unwritable(url.lastPathComponent) }
    return EncodedImage(data: data as Data, fileExtension: kind.fileExtension)
  }

  /// Reduces the levels of each colour channel (not alpha): the resulting PNG compresses far better.
  static func quantized(_ image: CGImage, step: Int) -> CGImage? {
    let width = image.width
    let height = image.height
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let base = context.data
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let table: [UInt8] = (0..<256).map { value in
      UInt8(min(255, (value + step / 2) / step * step))
    }
    let pixels = base.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
    for row in 0..<height {
      var offset = row * context.bytesPerRow
      for _ in 0..<width {
        pixels[offset] = table[Int(pixels[offset])]
        pixels[offset + 1] = table[Int(pixels[offset + 1])]
        pixels[offset + 2] = table[Int(pixels[offset + 2])]
        offset += 4
      }
    }
    return context.makeImage()
  }

  static func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
  }

  /// Outcome of a compression written to disk.
  struct Outcome: Sendable {
    let output: URL
    let before: Int64
    let after: Int64
  }

  /// Compresses and writes next to the original; returns the written file and the byte sizes of the original and the new one.
  @discardableResult
  static func compress(_ url: URL, quality: Double, scale: CompressionScale) throws -> Outcome {
    let encoded = try encode(url, quality: quality, scale: scale)
    let output = OutputNamer.url(for: url, extension: encoded.fileExtension, suffix: "-compressed")
    do {
      try encoded.data.write(to: output, options: .atomic)
    } catch {
      throw ToolImageError.unwritable(output.lastPathComponent)
    }
    return Outcome(output: output, before: fileSize(url), after: Int64(encoded.data.count))
  }

  static func formatted(bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

// MARK: - View

/// Compress: quality and resizing, with before/after size computed on the first file.
struct CompressToolView: View {
  let context: ToolContext

  /// Settings that, when changed, trigger a new estimate.
  private struct Settings: Hashable {
    var quality = 60.0
    var scale = CompressionScale.original
  }

  private enum Estimate: Equatable {
    case calculating
    case sizes(before: Int64, after: Int64)
    case failed
  }

  @State private var settings = Settings()
  @State private var estimate = Estimate.calculating

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 18) {
        qualityRow
        scaleRow
        estimateBox
        if context.files.count > 1 {
          Text("Settings apply to all \(context.files.count) files; the estimate is based on the first.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      ToolFooter(context: context, apply: apply)
    }
    .task(id: settings) { await updateEstimate() }
  }

  private var qualityRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Quality").font(.subheadline.weight(.semibold))
        Spacer()
        Text(verbatim: "\(Int(settings.quality))%").monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(value: $settings.quality, in: 10...100, step: 1)
    }
  }

  private var scaleRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Resize").font(.subheadline.weight(.semibold))
      Picker("Resize", selection: $settings.scale) {
        ForEach(CompressionScale.allCases, id: \.self) { scale in
          Text(scale.title).tag(scale)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  private var estimateBox: some View {
    HStack(spacing: 0) {
      switch estimate {
      case .calculating:
        ProgressView().controlSize(.small)
        Text("Calculating size…").foregroundStyle(.secondary).padding(.leading, 8)
        Spacer()
      case .failed:
        Label("Estimate unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        Spacer()
      case .sizes(let before, let after):
        sizeColumn("Before", ImageCompressor.formatted(bytes: before))
        Spacer()
        Image(systemName: "arrow.right").foregroundStyle(.secondary)
        Spacer()
        sizeColumn("After", ImageCompressor.formatted(bytes: after))
        Spacer()
        Text(verbatim: percentage(before: before, after: after))
          .font(.title3.weight(.semibold))
          .foregroundStyle(after <= before ? Color.green : Color.orange)
          .monospacedDigit()
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func sizeColumn(_ title: LocalizedStringKey, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(verbatim: value).font(.headline).monospacedDigit()
    }
  }

  private func percentage(before: Int64, after: Int64) -> String {
    guard before > 0 else { return "" }
    let change = Double(after - before) / Double(before) * 100
    return change.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))) + "%"
  }

  private func updateEstimate() async {
    guard let first = context.files.first else {
      estimate = .failed
      return
    }
    estimate = .calculating
    let current = settings
    // Short wait: while dragging the slider, intermediate computations are cancelled before they start.
    try? await Task.sleep(for: .milliseconds(250))
    if Task.isCancelled { return }
    let result = await Task.detached(priority: .userInitiated) { () -> Estimate in
      guard let encoded = try? ImageCompressor.encode(first, quality: current.quality / 100, scale: current.scale)
      else { return .failed }
      return .sizes(before: ImageCompressor.fileSize(first), after: Int64(encoded.data.count))
    }.value
    if !Task.isCancelled { estimate = result }
  }

  private func apply() {
    let files = context.files
    let quality = settings.quality / 100
    let scale = settings.scale
    context.apply {
      var before: Int64 = 0
      var after: Int64 = 0
      for file in files {
        try Task.checkCancellation()
        let result = try ImageCompressor.compress(file, quality: quality, scale: scale)
        before += result.before
        after += result.after
      }
      let saved = before - after
      guard saved > 0 else { return String(localized: "Done: the files were already highly compressed") }
      return String(localized: "Saved \(ImageCompressor.formatted(bytes: saved))")
    }
  }
}
