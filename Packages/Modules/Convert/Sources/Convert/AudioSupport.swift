// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Accelerate
import Foundation

enum AudioToolError: LocalizedError {
  case unreadable(String)
  case unwritable(String)
  case emptySelection

  var errorDescription: String? {
    switch self {
    case .unreadable(let name): String(localized: "Can't read \(name)")
    case .unwritable(let name): String(localized: "Can't save \(name)")
    case .emptySelection: String(localized: "The selection is empty")
    }
  }
}

/// Peak waveform: one 0...1 value per column, per channel (at most two).
struct AudioWaveform: Equatable, Sendable {
  var duration: Double
  var sampleRate: Double
  var channelCount: Int
  /// Peaks per channel; a mono file has a single list.
  var peaks: [[Float]]

  /// Maximum peak across channels, column by column.
  var combined: [Float] {
    guard let first = peaks.first else { return [] }
    guard peaks.count > 1 else { return first }
    return first.indices.map { index in peaks.map { $0[index] }.max() ?? 0 }
  }

  /// Peaks of channel 0 (left) or 1 (right); a mono file repeats its single channel.
  func channel(_ index: Int) -> [Float] {
    guard !peaks.isEmpty else { return [] }
    return peaks[min(index, peaks.count - 1)]
  }
}

/// Time format as in the reference: `m:ss.cc`.
enum AudioTime {
  static func format(_ seconds: Double) -> String {
    let total = Int((max(0, seconds) * 100).rounded())
    let centis = total % 100
    let secs = (total / 100) % 60
    let mins = total / 6000
    return "\(mins):" + String(format: "%02d.%02d", secs, centis)
  }
}

/// Reading, analysis and writing of audio with AVFoundation, shared by the three tools.
/// All of it is pure file work: no audio engine stays on.
enum AudioSupport {
  static let pcmExtensions: Set<String> = ["wav", "aiff", "aif", "caf"]
  static let chunkFrames: AVAudioFrameCount = 32768

  // MARK: Waveform

  /// Extracts the peaks (cancellable via task cancellation). Reads the file in blocks.
  static func waveform(url: URL, columns: Int = 600) async throws -> AudioWaveform {
    let file = try openFile(url)
    let total = file.length
    let format = file.processingFormat
    let sampleRate = format.sampleRate
    let channelCount = Int(format.channelCount)
    guard total > 0, sampleRate > 0, columns > 0 else {
      throw AudioToolError.unreadable(url.lastPathComponent)
    }
    let kept = min(2, channelCount)
    let columnFrames = max(1, (total + Int64(columns) - 1) / Int64(columns))
    let count = Int((total + columnFrames - 1) / columnFrames)
    var peaks = [[Float]](repeating: [Float](repeating: 0, count: count), count: kept)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
      throw AudioToolError.unreadable(url.lastPathComponent)
    }
    var position: Int64 = 0
    while position < total {
      try Task.checkCancellation()
      try file.read(into: buffer, frameCount: chunkFrames)
      let frames = Int(buffer.frameLength)
      if frames == 0 { break }
      guard let data = buffer.floatChannelData else { break }
      for channel in 0..<kept {
        accumulate(data[channel], frames: frames, from: position, columnFrames: columnFrames, into: &peaks[channel])
      }
      position += Int64(frames)
    }
    return AudioWaveform(
      duration: Double(total) / sampleRate, sampleRate: sampleRate, channelCount: channelCount, peaks: peaks)
  }

  /// Updates the maximum peak of each column touched by the block.
  private static func accumulate(
    _ samples: UnsafePointer<Float>, frames: Int, from position: Int64, columnFrames: Int64, into peaks: inout [Float]
  ) {
    var offset = 0
    while offset < frames {
      let column = Int((position + Int64(offset)) / columnFrames)
      let columnEnd = Int64(column + 1) * columnFrames - position
      let length = Int(min(Int64(frames), columnEnd)) - offset
      guard length > 0, column < peaks.count else { break }
      var peak: Float = 0
      vDSP_maxmgv(samples + offset, 1, &peak, vDSP_Length(length))
      peaks[column] = max(peaks[column], min(1, peak))
      offset += length
    }
  }

  // MARK: Silence

  /// Interval (in seconds) between the first and last sample above the threshold; `nil` if it is all silence.
  static func nonSilentRange(url: URL, thresholdDB: Float = -45) throws -> ClosedRange<Double>? {
    let file = try openFile(url)
    let total = file.length
    let rate = file.processingFormat.sampleRate
    guard total > 0, rate > 0 else { return nil }
    let threshold = pow(10, thresholdDB / 20)
    guard let first = try firstLoudFrame(in: file, threshold: threshold, forward: true),
      let last = try firstLoudFrame(in: file, threshold: threshold, forward: false)
    else { return nil }
    return (Double(first) / rate)...(Double(last + 1) / rate)
  }

  /// First (or last) frame above the threshold, searching in blocks from the chosen edge towards the centre.
  private static func firstLoudFrame(in file: AVAudioFile, threshold: Float, forward: Bool) throws -> Int64? {
    let total = file.length
    let block = Int64(4096)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block))
    else { return nil }
    let channels = Int(buffer.format.channelCount)
    var edge = forward ? Int64(0) : total
    while forward ? edge < total : edge > 0 {
      let start = forward ? edge : max(0, edge - block)
      let length = forward ? min(block, total - edge) : edge - start
      file.framePosition = start
      try file.read(into: buffer, frameCount: AVAudioFrameCount(length))
      let frames = Int(buffer.frameLength)
      if let data = buffer.floatChannelData, frames > 0 {
        for step in 0..<frames {
          let index = forward ? step : frames - 1 - step
          for channel in 0..<channels where abs(data[channel][index]) > threshold {
            return start + Int64(index)
          }
        }
      }
      edge = forward ? edge + block : start
    }
    return nil
  }

  // MARK: Opening and writing

  static func openFile(_ url: URL) throws -> AVAudioFile {
    do {
      return try AVAudioFile(forReading: url)
    } catch {
      throw AudioToolError.unreadable(url.lastPathComponent)
    }
  }

  /// A PCM file keeps its container, everything else comes out as M4A (AAC).
  static func outputExtension(for source: URL) -> String {
    let ext = source.pathExtension.lowercased()
    return pcmExtensions.contains(ext) ? ext : "m4a"
  }

  /// Output file settings: PCM like the original (16 bit if it is not), or AAC.
  static func writerSettings(like file: AVAudioFile, ext: String, channels: Int) -> [String: Any] {
    let rate = file.processingFormat.sampleRate
    guard pcmExtensions.contains(ext) else {
      return [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: min(256_000, 96_000 * channels),
      ]
    }
    var settings = file.fileFormat.settings
    if (settings[AVFormatIDKey] as? UInt32) != kAudioFormatLinearPCM {
      settings = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: ext != "wav" && ext != "caf",
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: rate,
      ]
    }
    settings[AVNumberOfChannelsKey] = channels
    return settings
  }

  /// Copies `range` (in frames) of `source` into `writer`, passing each block through `body`.
  /// `body` receives the block read, the one to write (already the right length) and the absolute start frame.
  static func process(
    source: AVAudioFile, writer: AVAudioFile, range: Range<Int64>,
    body: (_ input: AVAudioPCMBuffer, _ output: AVAudioPCMBuffer, _ startFrame: Int64) -> Void
  ) throws {
    let input = source.processingFormat
    let output = writer.processingFormat
    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunkFrames),
      let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: chunkFrames)
    else { throw AudioToolError.unreadable("") }
    source.framePosition = range.lowerBound
    var position = range.lowerBound
    while position < range.upperBound {
      try Task.checkCancellation()
      let wanted = AVAudioFrameCount(min(Int64(chunkFrames), range.upperBound - position))
      try source.read(into: inBuffer, frameCount: wanted)
      let frames = inBuffer.frameLength
      if frames == 0 { break }
      outBuffer.frameLength = frames
      body(inBuffer, outBuffer, position)
      try writer.write(from: outBuffer)
      position += Int64(frames)
    }
  }

  /// Copies the common channels (if the output has more, repeats the last one).
  static func copyChannels(_ input: AVAudioPCMBuffer, to output: AVAudioPCMBuffer) {
    guard let from = input.floatChannelData, let into = output.floatChannelData else { return }
    let frames = Int(input.frameLength)
    let inCount = Int(input.format.channelCount)
    for channel in 0..<Int(output.format.channelCount) {
      memcpy(into[channel], from[min(channel, inCount - 1)], frames * MemoryLayout<Float>.size)
    }
  }

  /// Temporary file for previews (16-bit PCM, regardless of the original's format).
  static func temporaryPreviewURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-convert-\(UUID().uuidString).caf")
  }

  static func previewWriter(at url: URL, rate: Double, channels: Int) throws -> AVAudioFile {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: channels,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    return try AVAudioFile(forWriting: url, settings: settings)
  }

  // MARK: Trim

  /// Exports `start`...`end` (seconds) next to the original, with the `-trimmed` suffix.
  static func trim(source: URL, start: Double, end: Double) async throws -> URL {
    let ext = outputExtension(for: source)
    let destination = OutputNamer.url(for: source, extension: ext, suffix: "-trimmed")
    do {
      if ext == "m4a" {
        try await exportM4A(source: source, start: start, end: end, to: destination)
      } else {
        try trimPCM(source: source, start: start, end: end, to: destination, ext: ext)
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return destination
  }

  private static func exportM4A(source: URL, start: Double, end: Double, to destination: URL) async throws {
    let asset = AVURLAsset(url: source)
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw AudioToolError.unwritable(destination.lastPathComponent)
    }
    let scale: CMTimeScale = 44100
    session.timeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: scale),
      end: CMTime(seconds: end, preferredTimescale: scale))
    try await session.export(to: destination, as: .m4a)
  }

  private static func trimPCM(source: URL, start: Double, end: Double, to destination: URL, ext: String) throws {
    let file = try openFile(source)
    let rate = file.processingFormat.sampleRate
    let first = max(0, Int64((start * rate).rounded()))
    let last = min(file.length, Int64((end * rate).rounded()))
    guard last > first else { throw AudioToolError.emptySelection }
    let channels = Int(file.processingFormat.channelCount)
    let settings = writerSettings(like: file, ext: ext, channels: channels)
    let writer: AVAudioFile
    do {
      writer = try AVAudioFile(forWriting: destination, settings: settings)
    } catch {
      throw AudioToolError.unwritable(destination.lastPathComponent)
    }
    try process(source: file, writer: writer, range: first..<last) { input, output, _ in
      copyChannels(input, to: output)
    }
  }
}
