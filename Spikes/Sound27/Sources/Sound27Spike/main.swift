// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only
//
// Spike 27 (DESIGN.md §2.4.1, SPIKES.md #27): Core Audio process tap for
// per-app mixer and output. This runner tries the two minimal things needed
// to decide whether the API is usable:
//   1) list the process objects with active output;
//   2) create a "stereo mixdown" tap on a given PID, with mute "when read",
//      install an IOProc, count the frames received, then destroy the tap.
//
// Usage:
//   swift run Sound27Spike             # list processes with active audio
//   swift run Sound27Spike <pid> [sec] # tap on the given PID (default 3 s)

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

@MainActor
enum Spike {
  static let defaultSeconds: Double = 3

  static func run() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
      listProcesses()
      return
    }
    guard let pid = pid_t(args[1]) else {
      fputs("Invalid PID: \(args[1])\n", stderr)
      exit(2)
    }
    let seconds = args.count >= 3 ? (Double(args[2]) ?? defaultSeconds) : defaultSeconds
    tap(pid: pid, seconds: seconds)
  }

  static func listProcesses() {
    let all = CoreAudioProcessList.allEntries()
    print("Total process objects: \(all.count)")
    let running = all.filter { $0.isRunningOutput }
    if running.isEmpty {
      print("None with active audio output.")
    } else {
      print("With active output:")
      print("PID\tAudioObjectID\tBundle/nome")
      for entry in running {
        print("\(entry.pid)\t\(entry.id)\t\(entry.bundleID ?? "–")")
      }
    }
    if all.count > 0, running.isEmpty {
      print("\nFirst 10 process objects:")
      for entry in all.prefix(10) {
        print("  pid=\(entry.pid)\tid=\(entry.id)\tbundle=\(entry.bundleID ?? "–")\toutput=\(entry.isRunningOutput)")
      }
    }
  }

  static func tap(pid: pid_t, seconds: Double) {
    let processObject: AudioObjectID
    if let found = CoreAudioProcessList.objectID(for: pid) {
      processObject = found
      print("Process object for PID \(pid): \(processObject)")
    } else {
      processObject = AudioObjectID(pid)  // fallback: some APIs tolerate the bare PID
      print("Process object for PID \(pid) not found; trying the PID as ID: \(processObject)")
    }

    let description: CATapDescription
    if #available(macOS 26, *), CommandLine.arguments.contains("--bundle") {
      // On 26 `bundleIDs` exists: try via bundle id.
      description = CATapDescription(stereoMixdownOfProcesses: [])
      description.bundleIDs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && pid_t($0) == nil }
      print("Tap via bundleIDs: \(description.bundleIDs)")
    } else {
      description = CATapDescription(stereoMixdownOfProcesses: [processObject])
      print("Tap via processes: [\(processObject)]")
    }
    description.name = "Tsukumo Sound spike 27"
    description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
    description.isPrivate = true
    description.isExclusive = false

    var tapID = AudioObjectID(kAudioObjectUnknown)
    let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
    if createStatus != noErr {
      fputs("AudioHardwareCreateProcessTap failed: OSStatus \(createStatus) (\(fourCC(createStatus)))\n", stderr)
      exit(4)
    }
    print("Tap created: AudioObjectID \(tapID)")

    defer {
      let destroy = AudioHardwareDestroyProcessTap(tapID)
      print("Tap destroyed: OSStatus \(destroy)\(destroy == noErr ? "" : " (\(fourCC(destroy)))")")
    }

    // Input stream format of the tap (0x7374696E = kAudioTapPropertyFormat).
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var formatAddress = AudioObjectPropertyAddress(
      mSelector: 0x74666D74,  // 'tfmt' – kAudioTapPropertyFormat
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let fmtStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
    print(
      "Tap stream format (OSStatus \(fmtStatus)): \(asbd.mSampleRate) Hz, "
        + "\(asbd.mChannelsPerFrame) channels, \(asbd.mBitsPerChannel) bit")

    // IOProc that counts the received frames.
    var frames = UInt64(0)
    var buffers = UInt64(0)
    let state = CounterState()
    let procID = UnsafeMutablePointer<AudioDeviceIOProcID?>.allocate(capacity: 1)
    procID.initialize(to: nil)
    defer { procID.deallocate() }
    let unmanaged = Unmanaged.passUnretained(state).toOpaque()
    let createProc = AudioDeviceCreateIOProcIDWithBlock(procID, tapID, nil) {
      _, inputData, _, _, _ in
      let s = Unmanaged<CounterState>.fromOpaque(unmanaged).takeUnretainedValue()
      s.ingest(inputData)
    }
    if createProc != noErr {
      fputs("AudioDeviceCreateIOProcID failed: OSStatus \(createProc) (\(fourCC(createProc)))\n", stderr)
      exit(5)
    }
    guard let io = procID.pointee else {
      fputs("IOProc is nil\n", stderr)
      exit(6)
    }
    let startStatus = AudioDeviceStart(tapID, io)
    if startStatus != noErr {
      fputs("AudioDeviceStart failed: OSStatus \(startStatus) (\(fourCC(startStatus)))\n", stderr)
      _ = AudioDeviceDestroyIOProcID(tapID, io)
      exit(7)
    }
    print("IOProc started; collecting \(seconds) s...")

    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    frames = state.frames
    buffers = state.buffers

    let stopStatus = AudioDeviceStop(tapID, io)
    let destroyProc = AudioDeviceDestroyIOProcID(tapID, io)
    print(
      "Buffers received: \(buffers); total frames: \(frames); "
        + "stop=\(stopStatus) destroyProc=\(destroyProc)")
  }

  static func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [
      UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
    ]
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    return printable ? "'" + String(bytes: bytes, encoding: .ascii)! + "'" : String(status)
  }
}

/// State shared between IOProc and main thread; `AudioBufferList` in a callback is
/// a variable-length struct, read by hand.
final class CounterState: @unchecked Sendable {
  var buffers: UInt64 = 0
  var frames: UInt64 = 0

  func ingest(_ data: UnsafePointer<AudioBufferList>) {
    buffers &+= 1
    let n = Int(data.pointee.mNumberBuffers)
    let base = UnsafeRawPointer(data).advanced(by: MemoryLayout<UInt32>.size)
      .assumingMemoryBound(to: AudioBuffer.self)
    for i in 0..<n {
      let buffer = base[i]
      let bytesPerFrame = max(buffer.mNumberChannels * 4, 1)  // float32 per canale
      frames &+= UInt64(buffer.mDataByteSize / bytesPerFrame)
    }
  }
}

enum CoreAudioProcessList {
  struct Entry {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
  }

  static func allEntries() -> [Entry] { all() }

  static func running() -> [Entry] {
    all().filter { $0.isRunningOutput }
  }

  static func objectID(for pid: pid_t) -> AudioObjectID? {
    all().first { $0.pid == pid }?.id
  }

  private static func all() -> [Entry] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: 0x70726F23,  // 'pro#' – kAudioHardwarePropertyProcessObjectList
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
      return []
    }
    return ids.compactMap { id in
      guard let pid = property(id, selector: 0x70706964, initial: pid_t(-1)), pid > 0 else {
        return nil  // 'ppid'
      }
      let bundle = stringProperty(id, selector: 0x70626964)  // 'pbid'
      let running = property(id, selector: 0x7069726F, initial: UInt32(0)) ?? 0  // 'piro'
      return Entry(id: id, pid: pid, bundleID: bundle, isRunningOutput: running == 1)
    }
  }

  private static func property<T: BitwiseCopyable>(_ id: AudioObjectID, selector: AudioObjectPropertySelector, initial: T) -> T? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, UnsafeMutableRawPointer($0))
    }
    return status == noErr ? value : nil
  }

  private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var cf: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &cf) {
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let cf else { return nil }
    return cf as String
  }
}

Spike.run()
