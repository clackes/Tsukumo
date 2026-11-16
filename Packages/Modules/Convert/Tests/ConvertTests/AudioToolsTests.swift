// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Foundation
import Testing

@testable import Convert

/// Synthetic audio files: silence, 440 Hz sine, silence.
private enum Synthetic {
  static let rate = 44100.0

  static func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("convert-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// `lead` seconds of silence, `tone` of sine (amplitude 0.5), `tail` of silence.
  /// With `channels == 2` the right channel has half the amplitude.
  static func write(
    to url: URL, lead: Double, tone: Double, tail: Double, channels: Int = 1, settings: [String: Any]? = nil
  ) throws {
    let format: [String: Any] =
      settings ?? [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
    let file = try AVAudioFile(forWriting: url, settings: format)
    let frames = Int((lead + tone + tail) * rate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
      let data = buffer.floatChannelData
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    let first = Int(lead * rate)
    let last = Int((lead + tone) * rate)
    for channel in 0..<Int(file.processingFormat.channelCount) {
      for index in 0..<frames {
        let inside = index >= first && index < last
        let amplitude: Float = channel == 0 ? 0.5 : 0.25
        data[channel][index] = inside ? amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / rate)) : 0
      }
    }
    try file.write(from: buffer)
  }

  static func duration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
  }

  static func peak(_ url: URL, channel: Int) throws -> Float {
    let file = try AVAudioFile(forReading: url)
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
      let data = buffer.floatChannelData
    else { return 0 }
    try file.read(into: buffer)
    return (0..<Int(buffer.frameLength)).map { abs(data[channel][$0]) }.max() ?? 0
  }
}

@Suite("Audio: waveform and silence")
struct AudioAnalysisTests {
  @Test("silence at the ends is found at the right frame")
  func silenceBounds() throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.wav")
    try Synthetic.write(to: url, lead: 1, tone: 2, tail: 1)
    let range = try #require(try AudioSupport.nonSilentRange(url: url))
    #expect(abs(range.lowerBound - 1.0) < 0.01)
    #expect(abs(range.upperBound - 3.0) < 0.01)
  }

  @Test("an all-silent file has no range")
  func allSilent() throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.wav")
    try Synthetic.write(to: url, lead: 1, tone: 0, tail: 0)
    #expect(try AudioSupport.nonSilentRange(url: url) == nil)
  }

  @Test("the waveform has high peaks where the sine is and zero in silence")
  func waveformPeaks() async throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.wav")
    try Synthetic.write(to: url, lead: 1, tone: 2, tail: 1, channels: 2)
    let waveform = try await AudioSupport.waveform(url: url, columns: 40)
    #expect(abs(waveform.duration - 4) < 0.001)
    #expect(waveform.channelCount == 2)
    #expect(waveform.peaks.count == 2)
    let left = waveform.channel(0)
    #expect(left.count == 40)
    #expect(left[0] == 0)
    #expect(left[39] == 0)
    #expect(left[20] > 0.45)
    #expect(waveform.channel(1)[20] > 0.2 && waveform.channel(1)[20] < 0.3)
  }

  @Test("time is written as m:ss.cc")
  func timeFormat() {
    #expect(AudioTime.format(0) == "0:00.00")
    #expect(AudioTime.format(41.74) == "0:41.74")
    #expect(AudioTime.format(75.5) == "1:15.50")
  }
}

@Suite("Audio: trim")
struct AudioTrimTests {
  @Test("the WAV trim lasts as long as the selection and leaves the original untouched")
  func trimWav() async throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.wav")
    try Synthetic.write(to: url, lead: 1, tone: 2, tail: 1)
    let output = try await AudioSupport.trim(source: url, start: 1, end: 3)
    #expect(output.lastPathComponent == "a-trimmed.wav")
    #expect(abs(try Synthetic.duration(output) - 2) < 0.01)
    #expect(abs(try Synthetic.duration(url) - 4) < 0.001)
    #expect(try Synthetic.peak(output, channel: 0) > 0.45)
  }

  @Test("an empty selection is an error and leaves no file")
  func emptySelection() async throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.wav")
    try Synthetic.write(to: url, lead: 0, tone: 1, tail: 0)
    await #expect(throws: AudioToolError.self) {
      _ = try await AudioSupport.trim(source: url, start: 0.5, end: 0.5)
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a-trimmed.wav").path))
  }

  @Test("the M4A trim goes through the AppleM4A export")
  func trimM4A() async throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.m4a")
    try Synthetic.write(
      to: url, lead: 1, tone: 2, tail: 1,
      settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Synthetic.rate, AVNumberOfChannelsKey: 1])
    let output = try await AudioSupport.trim(source: url, start: 1, end: 3)
    #expect(output.pathExtension == "m4a")
    #expect(abs(try Synthetic.duration(output) - 2) < 0.1)
  }

  @Test("a non-PCM format comes out as M4A")
  func outputExtension() {
    #expect(AudioSupport.outputExtension(for: URL(fileURLWithPath: "/tmp/a.mp3")) == "m4a")
    #expect(AudioSupport.outputExtension(for: URL(fileURLWithPath: "/tmp/a.AIFF")) == "aiff")
    #expect(AudioSupport.outputExtension(for: URL(fileURLWithPath: "/tmp/a.caf")) == "caf")
  }
}

@Suite("Audio: channels")
struct AudioChannelsTests {
  @Test("stereo: levels per channel; mono source duplicated")
  func stereoLevels() throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.wav")
    try Synthetic.write(to: url, lead: 0, tone: 1, tail: 0, channels: 2)
    let mix = ChannelMix(layout: .stereo, left: 1, right: 0.5)
    let output = try AudioSupport.convertChannels(source: url, mix: mix)
    #expect(output.lastPathComponent == "a-stereo.wav")
    let file = try AVAudioFile(forReading: output)
    #expect(file.processingFormat.channelCount == 2)
    #expect(abs(try Synthetic.peak(output, channel: 0) - 0.5) < 0.01)
    #expect(abs(try Synthetic.peak(output, channel: 1) - 0.125) < 0.01)

    let monoSource = folder.appendingPathComponent("m.wav")
    try Synthetic.write(to: monoSource, lead: 0, tone: 1, tail: 0, channels: 1)
    let duplicated = try AudioSupport.convertChannels(
      source: monoSource, mix: ChannelMix(layout: .stereo, left: 1, right: 1))
    #expect(try AVAudioFile(forReading: duplicated).processingFormat.channelCount == 2)
    #expect(abs(try Synthetic.peak(duplicated, channel: 1) - 0.5) < 0.01)
  }

  @Test("mono: sum of the channels with levels, without exceeding 1")
  func monoSum() throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.wav")
    try Synthetic.write(to: url, lead: 0, tone: 1, tail: 0, channels: 2)
    let mix = ChannelMix(layout: .mono, left: 1, right: 1)
    let output = try AudioSupport.convertChannels(source: url, mix: mix)
    #expect(output.lastPathComponent == "a-mono.wav")
    #expect(try AVAudioFile(forReading: output).processingFormat.channelCount == 1)
    // (0.5 + 0.25) / 2 = 0.375 peak.
    #expect(abs(try Synthetic.peak(output, channel: 0) - 0.375) < 0.01)
    #expect(mix.sample(left: 0.5, right: 0.25, channel: 0) == 0.375)
    #expect(ChannelMix(layout: .mono, left: 0.2, right: 0.3).monoScale == 1)
  }

  @Test("the mono preview has the same drawing on both lanes")
  func previewPeaks() {
    let waveform = AudioWaveform(duration: 1, sampleRate: 44100, channelCount: 2, peaks: [[1, 0.5], [0, 0.5]])
    let mono = ChannelMix(layout: .mono, left: 1, right: 1).previewPeaks(of: waveform)
    #expect(mono.left == mono.right)
    #expect(mono.left == [0.5, 0.5])
    let stereo = ChannelMix(layout: .stereo, left: 0.5, right: 1).previewPeaks(of: waveform)
    #expect(stereo.left == [0.5, 0.25])
    #expect(stereo.right == [0, 0.5])
  }
}

@Suite("Audio: bleeps")
struct BleepTests {
  @Test("overlapping ranges merge")
  func merge() {
    var ranges = BleepRanges(duration: 10)
    ranges.add(from: 1, to: 2)
    ranges.add(from: 5, to: 6)
    ranges.add(from: 1.5, to: 3)
    #expect(ranges.count == 2)
    #expect(ranges.items.map(\.start) == [1, 5])
    #expect(ranges.items.map(\.end) == [3, 6])
    ranges.add(from: 3, to: 5)
    #expect(ranges.count == 1)
    #expect(ranges.items[0].start == 1 && ranges.items[0].end == 6)
  }

  @Test("the ends are clamped to the duration, in any order")
  func clamp() {
    var ranges = BleepRanges(duration: 5)
    ranges.add(from: 6, to: 4)
    ranges.add(from: -1, to: 0.5)
    #expect(ranges.items.map(\.start) == [0, 4])
    #expect(ranges.items.map(\.end) == [0.5, 5])
  }

  @Test("below 0.05 s nothing is created")
  func minimumDuration() {
    var ranges = BleepRanges(duration: 5)
    #expect(ranges.add(from: 1, to: 1.04) == nil)
    #expect(ranges.items.isEmpty)
    #expect(ranges.add(from: 1, to: 1.05) != nil)
  }

  @Test("edges don't cross their neighbors or the minimum duration; deleting works by id")
  func edges() throws {
    var ranges = BleepRanges(duration: 10)
    let firstID = ranges.add(from: 1, to: 2)
    let first = try #require(firstID)
    let secondID = ranges.add(from: 4, to: 5)
    let second = try #require(secondID)
    ranges.setEdge(of: second, isStart: true, to: 0)
    #expect(ranges.items[1].start == 2)
    ranges.setEdge(of: first, isStart: false, to: 9)
    #expect(ranges.items[0].end == 2)
    ranges.setEdge(of: first, isStart: false, to: 0)
    #expect(abs(ranges.items[0].end - 1.05) < 1e-9)
    ranges.setEdge(of: second, isStart: false, to: 99)
    #expect(ranges.items[1].end == 10)
    #expect(ranges.range(at: 1.02)?.id == first)
    #expect(ranges.range(at: 0.5) == nil)
    ranges.remove(id: first)
    #expect(ranges.count == 1)
  }

  @Test("rendering replaces the audio with a 1 kHz sine, with 5 ms fades")
  func rendering() throws {
    let rate = 44100.0
    let format = try #require(
      AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
    let frames = Int(rate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<2 { for index in 0..<frames { data[channel][index] = 0.2 } }
    BleepRenderer.apply(to: buffer, startFrame: 0, ranges: [0.25...0.5])

    // Outside the interval the audio does not change.
    #expect(data[0][0] == 0.2)
    #expect(data[1][Int(0.9 * rate)] == 0.2)
    // Mid-interval there is only the bleep, identical on both channels.
    let mid = Int(0.375 * rate)
    let expected = BleepRenderer.tone(atFrame: Int64(mid), rate: rate)
    #expect(abs(data[0][mid] - expected) < 1e-6)
    #expect(data[0][mid] == data[1][mid])
    // The amplitude does not exceed 0.5 and the bleep really is a 1 kHz sine (period of 44.1 frames).
    let peak = (Int(0.26 * rate)..<Int(0.49 * rate)).map { abs(data[0][$0]) }.max() ?? 0
    #expect(peak > 0.49 && peak <= 0.5 + 1e-6)
    // At the first frame of the interval the bleep is still at zero (fade), then rises.
    let first = Int((0.25 * rate).rounded())
    #expect(data[0][first] == 0.2)
    #expect(
      BleepRenderer.gain(atFrame: Int64(first + 110), first: Int64(first), last: Int64(first + 11025), fade: 220) == 0.5
    )
  }

  @Test("block rendering gives the same result as a single block")
  func chunkedRendering() throws {
    let rate = 8000.0
    let format = try #require(
      AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
    func make(_ count: Int) throws -> AVAudioPCMBuffer {
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
      buffer.frameLength = AVAudioFrameCount(count)
      let data = try #require(buffer.floatChannelData)
      for index in 0..<count { data[0][index] = 0.1 }
      return buffer
    }
    let whole = try make(8000)
    BleepRenderer.apply(to: whole, startFrame: 0, ranges: [0.3...0.6])
    let second = try make(4000)
    BleepRenderer.apply(to: second, startFrame: 4000, ranges: [0.3...0.6])
    let wholeData = try #require(whole.floatChannelData)
    let secondData = try #require(second.floatChannelData)
    for index in 0..<4000 { #expect(wholeData[0][4000 + index] == secondData[0][index]) }
  }

  @Test("applying bleeps to a file creates -bleeped next to it and keeps the duration")
  func applyFile() throws {
    let folder = try Synthetic.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a.wav")
    try Synthetic.write(to: url, lead: 0, tone: 2, tail: 0)
    let output = try AudioSupport.applyBleeps(source: url, ranges: [0.5...1.0])
    #expect(output.lastPathComponent == "a-bleeped.wav")
    #expect(abs(try Synthetic.duration(output) - 2) < 0.001)
  }
}
