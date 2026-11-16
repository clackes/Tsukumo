// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import Synchronization

/// A tap on the output stream of a single process, plus a private aggregate device
/// that routes that stream to a real device, with a
/// **scale factor** applied sample by sample in a real-time IOProc
/// (DESIGN.md §2.4.1, spike 27).
///
/// It lives only while the app it is bound to has a volume other than 100% or
/// an output other than the default one: with a neutral mix no tap exists,
/// no IOProc, no aggregate device (§4.2, zero cost).
@available(macOS 14.4, *)
final class ProcessTap {
  /// Linear amplitude scale applied to the samples, from 0 to 1 (0 = mute).
  /// Written by the main actor and read by the real-time IOProc: no lock, only
  /// atomic read of an aligned `Float32`.
  private let scaleBox: Scalar

  let processObjectID: AudioObjectID
  let outputDeviceUID: String
  let aggregateDeviceID: AudioObjectID
  let tapID: AudioObjectID
  private var ioProcID: AudioDeviceIOProcID?
  /// The IOProc runs only while the app is really playing (DESIGN.md §2.4.1,
  /// §5.2 rule 10): a running IO keeps the hardware awake at every buffer.
  private var isIORunning = false
  /// Listener on the process's `IsRunningOutput`. `nil` if Core Audio did not
  /// accept it: in that case the IO stays always on, as a fallback.
  private var runningListener: AudioObjectPropertyListenerBlock?
  /// Called on the main queue when the IO does not restart: with the tap
  /// muting the app at the source, a stopped IO means silence. The controller
  /// recreates the tap or removes it.
  var onFailure: (@MainActor @Sendable () -> Void)?
  private static let runningAddress = AudioObjectPropertyAddress(
    mSelector: kAudioProcessPropertyIsRunningOutput,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  /// Prefix of the UID of the aggregate devices created by the mixer: the rest of the
  /// module uses it to filter them out of the `Uscita audio` ("Audio output") list,
  /// because `kAudioAggregateDeviceIsPrivateKey` hides the device from other
  /// processes, not from the same app that created it.
  static let aggregateUIDPrefix = "dev.local.tsukumo.sound.agg."

  private static let log = Logger(subsystem: "dev.local.tsukumo", category: "sound.tap")

  /// Scalar container: `AudioDeviceIOProcID` is a C pointer and its block
  /// captures this reference. Keeping the scalar in a class object lets us
  /// update it from the main actor without locks.
  final class Scalar: Sendable {
    /// Bits of the `Float32`: written by the main actor, read by the real-time thread.
    private let bits: Atomic<UInt32>
    /// IOProc callbacks received: the main actor checks that they grow
    /// after every IO start (see `scheduleHeartbeatCheck`).
    let ticks = Atomic<UInt64>(0)
    init(_ initial: Double) { bits = Atomic(Self.gain(for: initial).bitPattern) }
    var current: Float32 { Float32(bitPattern: bits.load(ordering: .relaxed)) }
    func set(_ newValue: Double) { bits.store(Self.gain(for: newValue).bitPattern, ordering: .relaxed) }

    /// The slider is perceptual: linear gain grows with the cube, so
    /// 50% really sounds like "half" (about -18 dB) and not almost full (-6 dB).
    static func gain(for volume: Double) -> Float32 {
      let clamped = max(0, min(1, volume))
      return Float32(clamped * clamped * clamped)
    }
  }

  /// Builds tap and aggregate device. Fails if Core Audio refuses (for
  /// example without the system audio recording permission on 14.2+).
  init?(processObjectID: AudioObjectID, outputDeviceUID: String, initialScale: Double) {
    // swiftlint:disable:previous function_body_length
    self.processObjectID = processObjectID
    self.outputDeviceUID = outputDeviceUID
    self.scaleBox = Scalar(initialScale)

    // 1. Tap description: only this process, muted at the source while
    //    we are reading it, private tap (not visible to other apps).
    let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
    description.name = "Tsukumo Sound process \(processObjectID)"
    // `.muted` and not `.mutedWhenTapped`: while the IOProc is stopped (app
    // silent) the app must stay muted at the source, otherwise on resume it
    // would play at full volume until the IO restarts.
    description.muteBehavior = CATapMuteBehavior.muted
    description.isPrivate = true
    description.isExclusive = false

    var createdTap = AudioObjectID(kAudioObjectUnknown)
    let createStatus = AudioHardwareCreateProcessTap(description, &createdTap)
    guard createStatus == noErr else {
      Self.log.error("AudioHardwareCreateProcessTap failed (\(createStatus, privacy: .public))")
      return nil
    }
    self.tapID = createdTap

    // 2. Private aggregate device with the real device as the main clock
    //    source and the tap as the input subdevice.
    let aggregateUID = "\(Self.aggregateUIDPrefix)\(processObjectID).\(UUID().uuidString)"
    let subTap: [String: Any] = [
      kAudioSubTapUIDKey as String: description.uuid.uuidString,
      kAudioSubTapDriftCompensationKey as String: 1,
    ]
    let subOutput: [String: Any] = [
      kAudioSubDeviceUIDKey as String: outputDeviceUID,
      kAudioSubDeviceDriftCompensationKey as String: 1,
    ]
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey as String: "Tsukumo Sound mixer",
      kAudioAggregateDeviceUIDKey as String: aggregateUID,
      kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
      kAudioAggregateDeviceIsPrivateKey as String: 1,
      kAudioAggregateDeviceIsStackedKey as String: 0,
      kAudioAggregateDeviceTapListKey as String: [subTap],
      kAudioAggregateDeviceSubDeviceListKey as String: [subOutput],
    ]

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
    guard aggregateStatus == noErr else {
      Self.log.error("AudioHardwareCreateAggregateDevice failed (\(aggregateStatus, privacy: .public))")
      _ = AudioHardwareDestroyProcessTap(createdTap)
      return nil
    }
    self.aggregateDeviceID = aggregateID

    // 3. Aggregate IOProc: reads the input from the tap, writes to the real device's
    //    output. The scale factor is read atomically on every
    //    callback: the main actor can change it without stopping the IO.
    let scaleBox = self.scaleBox
    var ioProc: AudioDeviceIOProcID?
    let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
      scaleBox.ticks.add(1, ordering: .relaxed)
      Self.copyAndScale(input: inputData, output: outputData, scale: scaleBox.current)
    }
    let procStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil, block)
    guard procStatus == noErr, let proc = ioProc else {
      Self.log.error("AudioDeviceCreateIOProcIDWithBlock failed (\(procStatus, privacy: .public))")
      _ = AudioHardwareDestroyAggregateDevice(aggregateID)
      _ = AudioHardwareDestroyProcessTap(createdTap)
      return nil
    }
    self.ioProcID = proc
    // Only the tap's stream: the device's own inputs (the microphone
    // of AirPods or a USB headset) left on would start the microphone and
    // put Bluetooth headphones into call profile.
    Self.useOnlyTapInput(aggregateID, proc)

    let startStatus = AudioDeviceStart(aggregateID, proc)
    if startStatus != noErr {
      Self.log.error("AudioDeviceStart failed (\(startStatus, privacy: .public))")
      _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
      _ = AudioHardwareDestroyAggregateDevice(aggregateID)
      _ = AudioHardwareDestroyProcessTap(createdTap)
      return nil
    }
    isIORunning = true
    scheduleHeartbeatCheck()

    // 4. From here the IO follows the app: stopped when it is silent, on when it plays.
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.syncIO() }
    var address = Self.runningAddress
    if AudioObjectAddPropertyListenerBlock(processObjectID, &address, .main, listener) == noErr {
      runningListener = listener
      syncIO()
    }
  }

  /// Aligns the IOProc with the app's state. Called on the main queue.
  private func syncIO() {
    guard let proc = ioProcID, runningListener != nil else { return }
    var address = Self.runningAddress
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    // If the read fails (process exited) leave everything as it is: the
    // controller throws the tap away when the process disappears from the list.
    guard AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &running) == noErr else { return }
    let wanted = running != 0
    guard wanted != isIORunning else { return }
    if wanted {
      let status = AudioDeviceStart(aggregateDeviceID, proc)
      if status == noErr {
        isIORunning = true
        scheduleHeartbeatCheck()
      } else {
        Self.log.error("AudioDeviceStart on resume failed (\(status, privacy: .public))")
        reportFailure()
      }
    } else {
      _ = AudioDeviceStop(aggregateDeviceID, proc)
      isIORunning = false
    }
  }

  /// `AudioDeviceStart` can succeed even when the aggregate is dead (after
  /// screen lock, sleep or change of the real device): the IOProc is never
  /// called and, with the tap muting at the source, the app stays silent.
  /// A single check after every start, no recurring timer.
  private func scheduleHeartbeatCheck() {
    let before = scaleBox.ticks.load(ordering: .relaxed)
    // The tap lives on the main queue, like this block.
    nonisolated(unsafe) weak let weakSelf = self
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.heartbeatDelay) {
      guard let self = weakSelf, self.isIORunning else { return }
      guard self.scaleBox.ticks.load(ordering: .relaxed) == before else { return }
      Self.log.error("No callback from the IOProc after start: tap stalled")
      self.reportFailure()
    }
  }

  private static let heartbeatDelay: TimeInterval = 3

  /// Asynchronous: the controller destroys this tap, and removing a listener from
  /// inside its own callback can block Core Audio.
  private func reportFailure() {
    if let onFailure { DispatchQueue.main.async { MainActor.assumeIsolated { onFailure() } } }
  }

  deinit {
    if let runningListener {
      var address = Self.runningAddress
      AudioObjectRemovePropertyListenerBlock(processObjectID, &address, .main, runningListener)
    }
    if let proc = ioProcID {
      _ = AudioDeviceStop(aggregateDeviceID, proc)
      _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
    }
    _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    _ = AudioHardwareDestroyProcessTap(tapID)
  }

  /// Updates the volume without recreating the tap: the scale factor changes
  /// atomically for the IOProc at the next callback.
  func setScale(_ value: Double) { scaleBox.set(value) }
  /// Current value of the scale factor, for the UI.
  var currentScale: Float32 { scaleBox.current }

  /// Turns off for this IOProc all the input streams of the aggregate
  /// except the last one, which is the tap (subdevices come first).
  private static func useOnlyTapInput(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) {
    var streams = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var bytes: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr else { return }
    let count = Int(bytes) / MemoryLayout<AudioStreamID>.size
    guard count > 1 else { return }
    var usage = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    // `AudioHardwareIOProcStreamUsage`: pointer to the IOProc, number of streams,
    // then a `UInt32` per stream.
    let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
    let size = headerSize + count * MemoryLayout<UInt32>.size
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    defer { raw.deallocate() }
    raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
    raw.storeBytes(of: UInt32(count), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
    for index in 0..<count {
      let isOn: UInt32 = index == count - 1 ? 1 : 0
      raw.storeBytes(of: isOn, toByteOffset: headerSize + index * MemoryLayout<UInt32>.size, as: UInt32.self)
    }
    let status = AudioObjectSetPropertyData(device, &usage, 0, nil, UInt32(size), raw)
    if status != noErr { log.error("IOProcStreamUsage refused (\(status, privacy: .public))") }
  }

  /// Copies the tap (the last input buffer, interleaved stereo) to the outputs
  /// of the real device, channel by channel, applying the gain.
  /// Handles interleaved outputs with several channels (HDMI, interfaces), non-interleaved
  /// outputs (one buffer per channel) and mono (average of L and R). Extra
  /// channels stay at zero. No allocation: runs on the real-time thread.
  static func copyAndScale(
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>,
    scale: Float32
  ) {
    let inList = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer<AudioBufferList>(mutating: input))
    let outList = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outList {
      if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    guard scale > 0, let tap = inList.last, let inData = tap.mData else { return }
    let inChannels = max(Int(tap.mNumberChannels), 1)
    let inPtr = inData.assumingMemoryBound(to: Float32.self)
    let inFrames = Int(tap.mDataByteSize) / (MemoryLayout<Float32>.size * inChannels)
    let totalOut = outList.reduce(0) { $0 + Int($1.mNumberChannels) }
    var channelBase = 0
    for buffer in outList {
      let outChannels = Int(buffer.mNumberChannels)
      defer { channelBase += outChannels }
      guard outChannels > 0, let outData = buffer.mData else { continue }
      let outPtr = outData.assumingMemoryBound(to: Float32.self)
      let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
      let frames = min(inFrames, outFrames)
      for channel in 0..<outChannels {
        let global = channelBase + channel
        if totalOut == 1 && inChannels >= 2 {
          for frame in 0..<frames {
            let left = inPtr[frame * inChannels]
            let right = inPtr[frame * inChannels + 1]
            outPtr[frame] = (left + right) * 0.5 * scale
          }
        } else if global < inChannels {
          for frame in 0..<frames {
            outPtr[frame * outChannels + channel] = inPtr[frame * inChannels + global] * scale
          }
        }
      }
    }
  }
}

/// String keys of `AudioHardwareCreateAggregateDevice` not exposed by
/// Swift as strings: the framework defines them in `AudioHardwareBase.h`.
private let kAudioSubTapUIDKey = "uid"
private let kAudioSubTapDriftCompensationKey = "drift"
