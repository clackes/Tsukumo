// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Name of the XPC service that runs ffmpeg (DESIGN.md §4.1, Convert's tier 1).
public enum ConverterService {
  public static let name = "dev.local.tsukumo.Converter"
}

/// Interface exported by the `Converter.xpc` helper.
@objc public protocol ConverterXPC {
  /// `job` is an `FFmpegJob` as JSON. The reply is `nil` if everything went well,
  /// otherwise a human-readable error message.
  func run(_ job: Data, reply: @escaping @Sendable (String?) -> Void)
  func cancel()
}

/// Interface the app exports to the helper for progress (0…1).
@objc public protocol ConverterProgressXPC {
  func progress(_ fraction: Double)
}

/// Outputs that only ffmpeg can write. Each preset has fixed arguments: the helper
/// never accepts arbitrary arguments from the app.
public enum FFmpegPreset: String, Codable, Sendable, CaseIterable {
  case webp, mp3, opus, flac, webm, mkv, gif

  public var fileExtension: String { rawValue }

  /// Arguments between the input and the output.
  public var arguments: [String] {
    switch self {
    case .webp:
      // Animated GIFs stay animated too.
      ["-c:v", "libwebp_anim", "-quality", "85", "-loop", "0"]
    case .mp3:
      ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
    case .opus:
      ["-vn", "-c:a", "libopus", "-b:a", "128k"]
    case .flac:
      ["-vn", "-c:a", "flac"]
    case .webm:
      [
        "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
        "-c:a", "libopus", "-b:a", "128k",
      ]
    case .mkv:
      // Only the container changes: no re-encoding. Video, audio and
      // subtitles only: the data streams of iPhone .mov files would make `-map 0` fail.
      ["-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-dn", "-c", "copy"]
    case .gif:
      [
        "-an", "-filter_complex",
        "fps=15,scale='min(iw,720)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
        "-loop", "0",
      ]
    }
  }
}

/// A job for the helper.
public struct FFmpegJob: Codable, Sendable, Equatable {
  public var input: String
  public var output: String
  public var preset: FFmpegPreset

  public init(input: String, output: String, preset: FFmpegPreset) {
    self.input = input
    self.output = output
    self.preset = preset
  }

  public enum ValidationError: Error, Equatable {
    case notAbsolute, inputMissing, outputExists, differentFolder, wrongExtension, unsupportedName

    /// Message readable by the user.
    public var message: String {
      switch self {
      case .notAbsolute: "Invalid file path"
      case .inputMissing: "The source file no longer exists"
      case .outputExists: "A file with the destination name already exists"
      case .differentFolder: "The converted file must be next to the original"
      case .wrongExtension: "Invalid destination format"
      case .unsupportedName: "The file path contains a character (%) the engine can't handle"
      }
    }
  }

  /// Extensions ffmpeg reads as image sequences: a `%` in the name
  /// would be interpreted as a pattern (`img%03d.png`).
  public static let imageSequenceExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp"]

  /// Helper checks before launching ffmpeg: absolute paths, existing input,
  /// new output in the same folder and with the preset's extension.
  public func validate(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    throws(ValidationError)
  {
    guard input.hasPrefix("/"), output.hasPrefix("/") else { throw .notAbsolute }
    guard fileExists(input) else { throw .inputMissing }
    guard
      !(input.contains("%")
        && Self.imageSequenceExtensions.contains(URL(fileURLWithPath: input).pathExtension.lowercased()))
    else { throw .unsupportedName }
    guard !fileExists(output) else { throw .outputExists }
    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: output)
    guard
      inputURL.deletingLastPathComponent().standardizedFileURL
        == outputURL.deletingLastPathComponent().standardizedFileURL
    else { throw .differentFolder }
    guard outputURL.pathExtension.lowercased() == preset.fileExtension else { throw .wrongExtension }
  }

  /// Full command line (without the executable). `-n`: never overwrite.
  public var commandLine: [String] { commandLine(writingTo: output) }

  /// Like `commandLine`, but writes to `path` (the helper's temporary file).
  /// `-protocol_whitelist`: playlists and containers cannot open the network.
  public func commandLine(writingTo path: String) -> [String] {
    [
      "-hide_banner", "-nostdin", "-nostats", "-n", "-progress", "pipe:1",
      "-protocol_whitelist", "file,pipe", "-i", input,
    ] + preset.arguments + [path]
  }

  /// Hidden temporary name next to the output, with the preset's extension at
  /// the end (so ffmpeg picks the right container without `-f`). The helper writes
  /// here and renames on success: a failure never touches the final file.
  public func temporaryOutput(token: String) -> String {
    URL(fileURLWithPath: output).deletingLastPathComponent()
      .appendingPathComponent(".tsukumo-\(token).\(preset.fileExtension)").path
  }
}

/// Reading ffmpeg's output for progress.
public enum FFmpegProgress {
  /// Duration from the `Duration: 00:01:02.50, …` line of stderr.
  /// Valid only if the value is complete (followed by `,` or a newline): a
  /// line fragment cut in half does not produce a wrong duration.
  public static func duration(in text: String) -> Double? {
    guard let range = text.range(of: "Duration: ") else { return nil }
    let rest = text[range.upperBound...]
    guard let end = rest.firstIndex(where: { $0 == "," || $0 == "\n" || $0 == " " || $0 == "\r" }) else {
      return nil
    }
    let parts = rest[..<end].split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2].contains("."), let hours = Double(parts[0]), let minutes = Double(parts[1]),
      let seconds = Double(parts[2]), hours >= 0, minutes >= 0, seconds >= 0
    else { return nil }
    return hours * 3600 + minutes * 60 + seconds
  }

  /// Elapsed time in seconds from an `out_time_us=…` line of `-progress`.
  public static func outTime(in line: String) -> Double? {
    guard line.hasPrefix("out_time_us="), let micro = Double(line.dropFirst("out_time_us=".count)) else {
      return nil
    }
    return micro / 1_000_000
  }
}

/// Splits a chunked text stream into complete lines: the last line, still
/// without a newline, waits for the next chunk.
public struct LineBuffer: Sendable {
  private var pending = ""

  public init() {}

  public mutating func append(_ text: String) -> [String] {
    pending += text
    var lines = pending.components(separatedBy: "\n")
    pending = lines.removeLast()
    return lines
  }
}
