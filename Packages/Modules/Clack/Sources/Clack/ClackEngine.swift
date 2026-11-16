// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

@preconcurrency import AVFoundation
import Carbon.HIToolbox
import Foundation
import Synchronization
import os

/// Where the sounds come from: a built-in pack or a file chosen by the user.
enum ClackSource: Sendable, Equatable {
  case pack(ClackPack)
  case file(URL)
  /// Folder of an imported Mechvibes pack.
  case mechvibes(URL)
}

/// Clack's audio engine (DESIGN.md §2.3).
///
/// All state lives on a dedicated serial queue: the tap callback only does an
/// `async` and returns. The engine starts at the first key press, goes into `pause()` after
/// inactivity (graph and buffers stay allocated, hardware IO stops) and
/// drops sounds that cannot start before the deadline.
final class ClackEngine: @unchecked Sendable {
  static let voiceCount = 24
  /// A sound must be able to start within 30 ms of its event, otherwise it is dropped.
  static let deadlineNanoseconds: UInt64 = 30_000_000

  private let queue = DispatchQueue(label: "dev.local.tsukumo.clack.audio", qos: .userInteractive)
  private let signposter = OSSignposter(subsystem: "dev.local.tsukumo", category: "clack")
  private let onRunningChange: @Sendable (Bool) -> Void

  // State confined to `queue`.
  private var engine: AVAudioEngine?
  private var voices: [AVAudioPlayerNode] = []
  private var nextVoice = 0
  private var buffers: [ClackSoundKind: [AVAudioPCMBuffer]] = [:]
  private var variantCursor: [ClackSoundKind: Int] = [:]
  private var mechvibes = MechvibesBuffers()
  private var isRunning = false
  /// After `shutdown()` a key press already queued must not recreate the engine.
  private var isShutDown = false
  private var lastEvent: UInt64 = 0
  private var volume: Float = 0.6
  private var source: ClackSource?
  private var playsKeyUp = true
  private(set) var droppedCount = 0

  init(onRunningChange: @escaping @Sendable (Bool) -> Void) {
    self.onRunningChange = onRunningChange
  }

  // MARK: From the tap thread

  /// O(1): no audio allocation, no engine start in here.
  func keyEvent(keyCode: UInt16, isDown: Bool, timestamp: UInt64) {
    // Password fields: no sound, so typing rhythm is not revealed.
    guard !IsSecureEventInputEnabled() else { return }
    queue.async { self.play(keyCode: keyCode, isDown: isDown, timestamp: timestamp) }
  }

  // MARK: Configuration (from MainActor)

  func configure(source: ClackSource, volume: Float, playsKeyUp: Bool) {
    queue.async {
      self.volume = volume
      self.playsKeyUp = playsKeyUp
      self.engine?.mainMixerNode.outputVolume = volume
      // Buffers are regenerated only if the source changes, not on every volume tweak.
      guard source != self.source else { return }
      self.source = source
      self.loadBuffers(source)
    }
  }

  /// Pauses if no keys arrive for `seconds`. Called by the module's timer.
  func pauseIfIdle(after seconds: Double) {
    queue.async {
      guard self.isRunning else { return }
      let idle = Self.now() &- self.lastEvent
      guard idle >= UInt64(seconds * 1_000_000_000) else { return }
      self.engine?.pause()
      self.setRunning(false)
    }
  }

  /// The output device changed: the engine stopped by itself.
  func configurationChanged() {
    queue.async {
      // The notification arrives late: if a key press has already restarted the engine,
      // the flag must stay true, otherwise the idle timer switches off
      // and the engine stays on doing nothing.
      guard self.isRunning, self.engine?.isRunning != true else { return }
      self.setRunning(false)
    }
  }

  /// Stops and frees everything. After this call the instance must not be used again.
  func shutdown() {
    queue.sync {
      isShutDown = true
      engine?.stop()
      voices.removeAll()
      buffers.removeAll()
      mechvibes = MechvibesBuffers()
      engine = nil
      isRunning = false
    }
  }

  // MARK: On the audio queue

  private func play(keyCode: UInt16, isDown: Bool, timestamp: UInt64) {
    guard !isShutDown, isDown || playsKeyUp else { return }
    lastEvent = Self.now()
    // Age is measured on arrival: the key press that wakes the engine must not
    // be lost just because starting the hardware takes longer than the deadline.
    let age = lastEvent &- timestamp
    // After a device change the engine stops by itself before the flag
    // updates: playing on a stopped engine raises an NSException (crash).
    if !isRunning || engine?.isRunning != true { start() }
    guard isRunning, engine?.isRunning == true else { return }
    guard timestamp == 0 || age <= Self.deadlineNanoseconds else {
      droppedCount += 1
      signposter.emitEvent("ClackDropped")
      return
    }
    guard !voices.isEmpty, let buffer = nextBuffer(keyCode: keyCode, isDown: isDown) else { return }
    let voice = voices[nextVoice]
    nextVoice = (nextVoice + 1) % voices.count
    voice.pan = ClackKeyboard.pan(for: keyCode)
    voice.scheduleBuffer(buffer, at: nil, options: .interrupts)
    if !voice.isPlaying { voice.play() }
  }

  /// Mechvibes pack: one sound per key, on key down only. Otherwise rotating variants.
  private func nextBuffer(keyCode: UInt16, isDown: Bool) -> AVAudioPCMBuffer? {
    if !mechvibes.isEmpty { return isDown ? mechvibes.buffer(for: keyCode) : nil }
    let kind: ClackSoundKind = !isDown ? .up : ClackKeyboard.isWide(keyCode) ? .downWide : .down
    guard let variants = buffers[kind], !variants.isEmpty else { return nil }
    let cursor = variantCursor[kind, default: 0]
    variantCursor[kind] = (cursor + 1) % variants.count
    return variants[cursor]
  }

  private func start() {
    let engine = self.engine ?? makeEngine()
    self.engine = engine
    do {
      try engine.start()
      setRunning(true)
    } catch {
      signposter.emitEvent("ClackStartFailed")
    }
  }

  /// Graph created once: 24 voices pre-allocated on the mixer. The IO buffer stays
  /// the device default (we do not lower it for the whole system).
  private func makeEngine() -> AVAudioEngine {
    let engine = AVAudioEngine()
    let format = Self.format
    voices = (0..<Self.voiceCount).map { _ in
      let node = AVAudioPlayerNode()
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: format)
      return node
    }
    engine.mainMixerNode.outputVolume = volume
    engine.prepare()
    return engine
  }

  private func loadBuffers(_ source: ClackSource) {
    var loaded: [ClackSoundKind: [AVAudioPCMBuffer]] = [:]
    switch source {
    case .pack(let pack):
      for kind in [ClackSoundKind.down, .downWide, .up] {
        loaded[kind] = (0..<ClackSynth.variantsPerKind).compactMap { variant in
          Self.buffer(from: ClackSynth.samples(pack: pack, kind: kind, variant: variant, sampleRate: Self.sampleRate))
        }
      }
    case .file(let url):
      // One sound per key press; no sound on release.
      let buffer = Self.buffer(fromFile: url).map { [$0] } ?? []
      loaded[.down] = buffer
      loaded[.downWide] = buffer
    case .mechvibes(let directory):
      mechvibes = MechvibesBuffers.load(directory: directory)
    }
    if case .mechvibes = source {} else { mechvibes = MechvibesBuffers() }
    buffers = loaded
    variantCursor.removeAll()
  }

  private func setRunning(_ running: Bool) {
    guard isRunning != running else { return }
    isRunning = running
    onRunningChange(running)
  }

  // MARK: Utilities

  static let sampleRate: Double = 48_000
  static var format: AVAudioFormat {
    // Non-interleaved stereo Float32: the mixer's standard format.
    AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) ?? AVAudioFormat()
  }

  static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channels = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      for channel in 0..<Int(buffer.format.channelCount) {
        channels[channel].update(from: base, count: samples.count)
      }
    }
    return buffer
  }

  /// Maximum length of a custom sound: beyond it, it is trimmed.
  static let customMaxSeconds: Double = 1.5

  /// Reads an audio file (WAV, AIFF, MP3, M4A, CAF…) and converts it to the engine's
  /// format. `nil` if the file is not readable.
  static func buffer(fromFile url: URL, maxSeconds: Double = customMaxSeconds) -> AVAudioPCMBuffer? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let input = file.processingFormat
    let frames = AVAudioFrameCount(min(Double(file.length), input.sampleRate * maxSeconds))
    guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames),
      (try? file.read(into: source, frameCount: frames)) != nil, source.frameLength > 0
    else { return nil }

    let output = format
    guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
    let capacity = AVAudioFrameCount(Double(source.frameLength) * output.sampleRate / input.sampleRate) + 64
    guard let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
    let consumed = Mutex(false)
    var failure: NSError?
    converter.convert(to: result, error: &failure) { _, status in
      let alreadyConsumed = consumed.withLock { value in
        defer { value = true }
        return value
      }
      guard !alreadyConsumed else {
        status.pointee = .endOfStream
        return nil
      }
      status.pointee = .haveData
      return source
    }
    return failure == nil && result.frameLength > 0 ? result : nil
  }

  /// Maximum length of a Mechvibes pack's single file.
  static let packMaxSeconds: Double = 180

  /// Copies a span of a buffer into the engine format; `nil` if the span is outside the file.
  static func slice(_ source: AVAudioPCMBuffer, startMs: Double, durationMs: Double) -> AVAudioPCMBuffer? {
    let rate = source.format.sampleRate
    let start = Int((startMs / 1000 * rate).rounded())
    let wanted = Int((min(durationMs / 1000, customMaxSeconds) * rate).rounded())
    let count = min(wanted, Int(source.frameLength) - start)
    guard start >= 0, count > 0,
      let result = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count)),
      let input = source.floatChannelData, let output = result.floatChannelData
    else { return nil }
    result.frameLength = AVAudioFrameCount(count)
    for channel in 0..<Int(source.format.channelCount) {
      output[channel].update(from: input[channel] + start, count: count)
    }
    return result
  }

  /// Same clock as `CGEvent.timestamp`: nanoseconds since boot, excluding sleep time.
  static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}
