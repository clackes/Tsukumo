// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import ConverterKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Kind of a dragged file.
enum FileKind: Sendable, Equatable {
  case image, pdf, audio, video

  init?(_ url: URL) {
    guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
    if type.conforms(to: .pdf) {
      self = .pdf
    } else if type.conforms(to: .image) {
      self = .image
    } else if type.conforms(to: .audio) {
      self = .audio
    } else if type.conforms(to: .movie) || type.conforms(to: .video) {
      self = .video
    } else {
      return nil
    }
  }
}

/// Output formats. Images and PDF with ImageIO/PDFKit; audio and video with
/// AVFoundation (`MediaConverter`). WebP is missing because no system API
/// writes it: it comes with ffmpeg (tier 1).
enum OutputFormat: String, CaseIterable, Sendable, Identifiable {
  case jpeg, png, heic, avif, tiff, bmp, gif, pdf
  case m4a, wav, aiff, caf
  case mp4, mov
  // Tier 1: only with ffmpeg (Converter.xpc helper).
  case webp, mp3, opus, flac, webm, mkv, gifAnimation

  var id: String { rawValue }

  var kind: FileKind {
    switch self {
    case .m4a, .wav, .aiff, .caf, .mp3, .opus, .flac: .audio
    case .mp4, .mov, .webm, .mkv, .gifAnimation: .video
    case .pdf: .pdf
    default: .image
    }
  }

  var label: String {
    switch self {
    case .jpeg: "JPG"
    case .gifAnimation: "GIF"
    default: rawValue.uppercased()
    }
  }

  var type: UTType {
    switch self {
    case .jpeg: .jpeg
    case .png: .png
    case .heic: .heic
    case .avif: UTType("public.avif") ?? .image
    case .tiff: .tiff
    case .bmp: .bmp
    case .gif: .gif
    case .pdf: .pdf
    case .m4a: .mpeg4Audio
    case .wav: .wav
    case .aiff: .aiff
    case .caf: UTType("com.apple.coreaudio-format") ?? .audio
    case .mp4: .mpeg4Movie
    case .mov: .quickTimeMovie
    case .webp: .webP
    case .mp3: .mp3
    case .opus: UTType(filenameExtension: "opus") ?? .audio
    case .flac: UTType(filenameExtension: "flac") ?? .audio
    case .webm: UTType(filenameExtension: "webm") ?? .movie
    case .mkv: UTType(filenameExtension: "mkv") ?? .movie
    case .gifAnimation: .gif
    }
  }

  var fileExtension: String {
    switch self {
    case .jpeg: "jpg"
    case .gifAnimation: "gif"
    default: rawValue
    }
  }

  /// ffmpeg helper preset, `nil` for formats written by system APIs.
  var ffmpegPreset: FFmpegPreset? {
    switch self {
    case .webp: .webp
    case .mp3: .mp3
    case .opus: .opus
    case .flac: .flac
    case .webm: .webm
    case .mkv: .mkv
    case .gifAnimation: .gif
    default: nil
    }
  }

  /// Formats without transparency: the image is placed on a white background.
  var isOpaque: Bool { self == .jpeg || self == .bmp }
}

/// Quick tools: the second set of petals of the picker (DESIGN.md §2.5).
enum ConvertTool: String, CaseIterable, Sendable, Identifiable {
  // Images
  case compress, metadata, edit, annotate, addBackground, crop, redact
  // Audio
  case trimAudio, audioChannels, bleeps

  var id: String { rawValue }

  /// Label on the petal, as in the reference: short and uppercase.
  var label: String {
    switch self {
    case .compress: "Compress"
    case .metadata: "Metadata"
    case .edit: "Edit"
    case .annotate: "Annotate"
    case .addBackground: "Add BG"
    case .crop: "Crop"
    case .redact: "Redact"
    case .trimAudio: "Trim"
    case .audioChannels: "Channels"
    case .bleeps: "Bleeps"
    }
  }

  /// Panel title.
  var title: String {
    switch self {
    case .compress: "Compress"
    case .metadata: "Metadata"
    case .edit: "Edit Photo"
    case .annotate: "Annotate"
    case .addBackground: "Add BG"
    case .crop: "Crop"
    case .redact: "Redact"
    case .trimAudio: "Trim Audio"
    case .audioChannels: "Convert Audio Channels"
    case .bleeps: "Bleeps"
    }
  }

  var symbol: String {
    switch self {
    case .compress: "arrow.down.right.and.arrow.up.left"
    case .metadata: "tag"
    case .edit: "slider.horizontal.3"
    case .annotate: "pencil.tip.crop.circle"
    case .addBackground: "photo.badge.plus"
    case .crop: "crop"
    case .redact: "eye.slash"
    case .trimAudio: "scissors"
    case .audioChannels: "speaker.wave.2"
    case .bleeps: "speaker.slash"
    }
  }
}

/// A petal of the picker: an output format or a tool.
enum RadialItem: Identifiable, Equatable, Sendable {
  case format(OutputFormat)
  case tool(ConvertTool)

  var id: String {
    switch self {
    case .format(let format): "f.\(format.rawValue)"
    case .tool(let tool): "t.\(tool.rawValue)"
    }
  }

  var label: String {
    switch self {
    case .format(let format): format.label
    case .tool(let tool): tool.label
    }
  }

  var symbol: String? {
    switch self {
    case .format: nil
    case .tool(let tool): tool.symbol
    }
  }
}

/// What to offer for the dragged files. All files must be of the same kind.
enum ConvertCatalog {
  static let rasterFormats: [OutputFormat] = [.jpeg, .png, .heic, .avif, .tiff, .bmp, .gif, .pdf, .webp]
  static let pdfFormats: [OutputFormat] = [.jpeg, .png, .heic, .tiff]
  static let audioFormats: [OutputFormat] = [.m4a, .mp3, .wav, .flac, .opus, .aiff]
  static let videoFormats: [OutputFormat] = [.mp4, .mov, .webm, .mkv, .gifAnimation, .m4a, .mp3]
  static let imageTools: [ConvertTool] = [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact]
  static let audioTools: [ConvertTool] = [.trimAudio, .audioChannels, .bleeps]

  /// Kind common to all files, or `nil` if mixed or unknown.
  static func kind(of urls: [URL]) -> FileKind? {
    let kinds = urls.map(FileKind.init)
    guard let first = kinds.first, let kind = first, kinds.allSatisfy({ $0 == kind }) else { return nil }
    return kind
  }

  /// `ffmpeg`: whether tier 1 is available (helper included in the build).
  static func formats(for urls: [URL], ffmpeg: Bool = FFmpegConverter.isAvailable) -> [OutputFormat] {
    guard let kind = kind(of: urls) else { return [] }
    let candidates: [OutputFormat]
    switch kind {
    case .pdf: return pdfFormats
    case .image: candidates = rasterFormats
    case .audio: candidates = audioFormats
    case .video: candidates = videoFormats
    }
    // The format the file already has is not offered, if they are all the same.
    let types = urls.compactMap { UTType(filenameExtension: $0.pathExtension.lowercased()) }
    let sources = Set(types.map(\.identifier))
    return candidates.filter {
      !(sources.count == 1 && sources.contains($0.type.identifier)) && (ffmpeg || $0.ffmpegPreset == nil)
    }
  }

  static func tools(for urls: [URL]) -> [ConvertTool] {
    switch kind(of: urls) {
    case .image: imageTools
    case .audio: audioTools
    default: []
    }
  }
}

/// Output name next to the original, never overwriting.
enum OutputNamer {
  static func url(
    for source: URL, extension ext: String, suffix: String = "",
    exists: (URL) -> Bool = {
      FileManager.default.fileExists(atPath: $0.path)
    }
  ) -> URL {
    let folder = source.deletingLastPathComponent()
    let base = source.deletingPathExtension().lastPathComponent + suffix
    var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
    var counter = 2
    while exists(candidate) || candidate.standardizedFileURL == source.standardizedFileURL {
      candidate = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
      counter += 1
    }
    return candidate
  }
}

/// Geometry of the radial picker: equal petals, the first at the top, clockwise.
struct RadialLayout: Equatable, Sendable {
  var petals: Int
  var innerRadius: CGFloat = 62
  var outerRadius: CGFloat = 150

  var slice: Double { petals > 0 ? 2 * .pi / Double(petals) : 0 }

  /// Central angle of the petal, in radians, measured clockwise from the top.
  func centerAngle(of index: Int) -> Double { Double(index) * slice }

  /// Petal under the point (relative to the centre, y pointing down); `nil` at the centre or outside.
  func petal(at offset: CGPoint) -> Int? {
    guard petals > 0 else { return nil }
    let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
    guard distance >= innerRadius, distance <= outerRadius + 12 else { return nil }
    // atan2 with x and y swapped: 0 at the top, increasing clockwise.
    var angle = atan2(Double(offset.x), Double(-offset.y))
    if angle < 0 { angle += 2 * .pi }
    return Int(((angle + slice / 2) / slice).rounded(.down)) % petals
  }
}
