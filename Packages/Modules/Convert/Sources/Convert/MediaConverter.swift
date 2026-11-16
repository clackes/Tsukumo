// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Foundation

/// Audio and video conversions with AVFoundation (no external process).
/// The original is never touched; the output goes next to it, with a free name.
enum MediaConverter {
  /// Converts `source` and returns the file created. Cancellable via task cancellation.
  static func convert(_ source: URL, to format: OutputFormat) async throws -> URL {
    let name = source.lastPathComponent
    let asset = AVURLAsset(url: source)
    let destination = OutputNamer.url(for: source, extension: format.rawValue)
    do {
      switch format.kind {
      case .audio:
        try await exportAudio(asset, to: destination, format: format, name: name)
      case .video:
        try await exportVideo(asset, to: destination, format: format, name: name)
      default:
        throw ConversionError.unreadable(name)
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return destination
  }

  // MARK: Audio

  private static func fileType(for format: OutputFormat) -> AVFileType {
    switch format {
    case .m4a: .m4a
    case .wav: .wav
    case .aiff: .aiff
    case .caf: .caf
    case .mov: .mov
    default: .mp4
    }
  }

  /// Output track settings; the decoded source stays 16-bit PCM.
  private static func writerSettings(
    for format: OutputFormat, rate: Double, channels: Int
  ) -> [String: Any] {
    var settings: [String: Any] = [
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: channels,
    ]
    if format == .m4a {
      settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
      settings[AVEncoderBitRateKey] = min(256_000, 128_000 * channels)
    } else {
      settings[AVFormatIDKey] = kAudioFormatLinearPCM
      settings[AVLinearPCMBitDepthKey] = 16
      settings[AVLinearPCMIsFloatKey] = false
      settings[AVLinearPCMIsBigEndianKey] = format == .aiff
      settings[AVLinearPCMIsNonInterleaved] = false
    }
    return settings
  }

  private static func exportAudio(
    _ asset: AVURLAsset, to destination: URL, format: OutputFormat, name: String
  ) async throws {
    let tracks: [AVAssetTrack]
    do { tracks = try await asset.loadTracks(withMediaType: .audio) } catch {
      throw ConversionError.unreadable(name)
    }
    guard let track = tracks.first,
      let descriptions = try? await track.load(.formatDescriptions)
    else { throw ConversionError.unreadable(name) }
    var rate = 44_100.0
    var channels = 2
    if let first = descriptions.first,
      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee
    {
      if basic.mSampleRate > 0 { rate = basic.mSampleRate }
      if basic.mChannelsPerFrame > 0 { channels = Int(basic.mChannelsPerFrame) }
    }
    // Beyond stereo `AVAssetWriterInput` demands an `AVChannelLayoutKey` and
    // without it raises an NSException (crash). The reader downmixes to 2 channels.
    channels = min(channels, 2)

    let readerSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: channels,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let transcoder: Transcoder
    do {
      transcoder = try Transcoder(
        asset: asset, track: track, readerSettings: readerSettings,
        destination: destination, fileType: fileType(for: format),
        writerSettings: writerSettings(for: format, rate: rate, channels: channels))
    } catch {
      throw ConversionError.unwritable(name)
    }
    try await transcoder.run(name: name)
  }

  // MARK: Video

  private static func exportVideo(
    _ asset: AVURLAsset, to destination: URL, format: OutputFormat, name: String
  ) async throws {
    let passthrough = await canPassthrough(asset)
    let preset = passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw ConversionError.unreadable(name)
    }
    let box = SessionBox(session)
    let type = fileType(for: format)
    do {
      try await withTaskCancellationHandler {
        try await box.session.export(to: destination, as: type)
      } onCancel: {
        box.session.cancelExport()
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw ConversionError.unwritable(name)
    }
  }

  /// Container-only change when the codecs are H.264/HEVC and AAC (or absent).
  /// Metadata, timecode or subtitle tracks do not count: iPhone .mov files
  /// have them and must not rule out passthrough.
  private static func canPassthrough(_ asset: AVURLAsset) async -> Bool {
    guard let allTracks = try? await asset.load(.tracks) else { return false }
    let tracks = allTracks.filter { $0.mediaType == .video || $0.mediaType == .audio }
    guard !tracks.isEmpty else { return false }
    for track in tracks {
      guard let descriptions = try? await track.load(.formatDescriptions) else { return false }
      for description in descriptions {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        switch track.mediaType {
        case .video:
          guard subtype == kCMVideoCodecType_H264 || subtype == kCMVideoCodecType_HEVC else {
            return false
          }
        default:
          guard subtype == kAudioFormatMPEG4AAC else { return false }
        }
      }
    }
    return true
  }
}

/// `AVAssetExportSession` is not marked `Sendable`; we use it from a single task and from `cancelExport`.
private final class SessionBox: @unchecked Sendable {
  let session: AVAssetExportSession
  init(_ session: AVAssetExportSession) { self.session = session }
}

/// PCM reading and writing in the chosen format with AVAssetReader/Writer.
private final class Transcoder: @unchecked Sendable {
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let queue = DispatchQueue(label: "tsukumo.convert.media", qos: .utility)
  private let gate = ResumeGate()

  init(
    asset: AVURLAsset, track: AVAssetTrack, readerSettings: [String: Any],
    destination: URL, fileType: AVFileType, writerSettings: [String: Any]
  ) throws {
    reader = try AVAssetReader(asset: asset)
    output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
    output.alwaysCopiesSampleData = false
    writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
    input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
    input.expectsMediaDataInRealTime = false
    guard reader.canAdd(output), writer.canAdd(input) else {
      throw ConversionError.unwritable(destination.lastPathComponent)
    }
    reader.add(output)
    writer.add(input)
  }

  func run(name: String) async throws {
    guard reader.startReading() else { throw ConversionError.unreadable(name) }
    guard writer.startWriting() else { throw ConversionError.unwritable(name) }
    writer.startSession(atSourceTime: .zero)
    await withTaskCancellationHandler {
      await pump()
    } onCancel: {
      reader.cancelReading()
      writer.cancelWriting()
      // After `cancelWriting` the `pump` block may no longer be called back:
      // resume here, once only.
      gate.resume()
    }
    if Task.isCancelled {
      writer.cancelWriting()
      throw CancellationError()
    }
    if reader.status == .failed { throw ConversionError.unreadable(name) }
    await writer.finishWriting()
    guard writer.status == .completed else { throw ConversionError.unwritable(name) }
  }

  private func pump() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      gate.install(continuation)
      input.requestMediaDataWhenReady(on: queue) { [self] in
        while input.isReadyForMoreMediaData {
          guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
            if writer.status == .writing { input.markAsFinished() }
            gate.resume()
            return
          }
        }
      }
    }
  }
}

/// Resumes a continuation only once, from any queue, even if
/// `resume()` arrives before `install(_:)`.
private final class ResumeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var resumed = false

  func install(_ continuation: CheckedContinuation<Void, Never>) {
    let immediately = lock.withLock { () -> Bool in
      if resumed { return true }
      self.continuation = continuation
      return false
    }
    if immediately { continuation.resume() }
  }

  func resume() {
    let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      guard !resumed else { return nil }
      resumed = true
      defer { continuation = nil }
      return continuation
    }
    pending?.resume()
  }
}
