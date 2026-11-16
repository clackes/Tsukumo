// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Foundation
import Testing

@testable import Convert

@Suite("Convert: audio and video")
struct MediaConverterTests {
  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("tsukumo-media-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// 440 Hz sine, mono or stereo, 44.1 kHz, in the container chosen by the extension.
  private func makeSine(
    in folder: URL, name: String, seconds: Double = 1, channels: AVAudioChannelCount = 2
  ) throws -> URL {
    let url = folder.appendingPathComponent(name)
    let bigEndian = url.pathExtension == "aiff"
    let settings: [String: Any] =
      url.pathExtension == "m4a"
      ? [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: Int(channels), AVEncoderBitRateKey: 128_000,
      ]
      : [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: Int(channels), AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian,
      ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(44_100 * seconds)
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: channels,
        interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let data = buffer.floatChannelData
    else { throw ConversionError.unwritable(name) }
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
      for frame in 0..<Int(frames) {
        data[channel][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 44_100)
      }
    }
    try file.write(from: buffer)
    return url
  }

  /// One second of 5.1 (6 channels) PCM: beyond stereo the explicit layout is required.
  private func makeSurround(in folder: URL, name: String) throws -> URL {
    let url = folder.appendingPathComponent(name)
    guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A) else {
      throw ConversionError.unwritable(name)
    }
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 44_100, interleaved: false, channelLayout: layout)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0,
      AVNumberOfChannelsKey: 6, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVChannelLayoutKey: Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size),
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames: AVAudioFrameCount = 44_100
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let data = buffer.floatChannelData
    else { throw ConversionError.unwritable(name) }
    buffer.frameLength = frames
    for channel in 0..<6 {
      for frame in 0..<Int(frames) {
        data[channel][frame] = 0.3 * sin(2 * .pi * 440 * Float(frame) / 44_100)
      }
    }
    try file.write(from: buffer)
    return url
  }

  private func duration(of url: URL) async throws -> Double {
    try await AVURLAsset(url: url).load(.duration).seconds
  }

  @Test("5.1 audio becomes m4a and stereo wav without crashing the process", arguments: [OutputFormat.m4a, .wav])
  func surroundDownmix(format: OutputFormat) async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try makeSurround(in: folder, name: "surround.caf")
    let output = try await MediaConverter.convert(source, to: format)
    #expect(abs(try await duration(of: output) - 1) < 0.15)
    #expect(try AVAudioFile(forReading: output).fileFormat.channelCount == 2)
  }

  @Test("wav becomes m4a: same duration, original intact")
  func wavToM4A() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try makeSine(in: folder, name: "tone.wav")
    let before = try Data(contentsOf: source)
    let output = try await MediaConverter.convert(source, to: .m4a)
    #expect(output.lastPathComponent == "tone.m4a")
    #expect(abs(try await duration(of: output) - 1) < 0.15)
    #expect(try Data(contentsOf: source) == before)
  }

  @Test("m4a becomes wav with the same channels and sample rate")
  func m4aToWav() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try makeSine(in: folder, name: "tone.m4a", channels: 1)
    let output = try await MediaConverter.convert(source, to: .wav)
    #expect(abs(try await duration(of: output) - 1) < 0.15)
    let file = try AVAudioFile(forReading: output)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.sampleRate == 44_100)
  }

  @Test("aiff becomes caf")
  func aiffToCaf() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try makeSine(in: folder, name: "tone.aiff")
    let output = try await MediaConverter.convert(source, to: .caf)
    #expect(output.pathExtension == "caf")
    #expect(abs(try await duration(of: output) - 1) < 0.05)
  }

  @Test("a second run doesn't overwrite")
  func noOverwrite() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try makeSine(in: folder, name: "tone.wav")
    let first = try await MediaConverter.convert(source, to: .aiff)
    let second = try await MediaConverter.convert(source, to: .aiff)
    #expect(first.lastPathComponent == "tone.aiff")
    #expect(second.lastPathComponent == "tone 2.aiff")
    #expect(FileManager.default.fileExists(atPath: first.path))
  }

  @Test("non-audio file: error and no leftover")
  func unreadable() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("finto.wav")
    try Data("not audio".utf8).write(to: source)
    await #expect(throws: ConversionError.self) {
      try await MediaConverter.convert(source, to: .m4a)
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(names == ["finto.wav"])
  }

  // MARK: Synthetic video

  private func makeVideo(in folder: URL, name: String, type: AVFileType) async throws -> URL {
    let url = folder.appendingPathComponent(name)
    let writer = try AVAssetWriter(outputURL: url, fileType: type)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
      ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
      ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for index in 0..<20 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      var pixels: CVPixelBuffer?
      CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
      guard let pixels else { throw ConversionError.unwritable(name) }
      CVPixelBufferLockBaseAddress(pixels, [])
      if let base = CVPixelBufferGetBaseAddress(pixels) {
        memset(base, 0, CVPixelBufferGetDataSize(pixels))
      }
      CVPixelBufferUnlockBaseAddress(pixels, [])
      adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw ConversionError.unwritable(name) }
    return url
  }

  @Test("mp4 video becomes mov, duration preserved")
  func mp4ToMov() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try await makeVideo(in: folder, name: "clip.mp4", type: .mp4)
    let output = try await MediaConverter.convert(source, to: .mov)
    #expect(output.lastPathComponent == "clip.mov")
    #expect(abs(try await duration(of: output) - 2) < 0.3)
  }
}
