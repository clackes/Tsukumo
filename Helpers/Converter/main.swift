// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import ConverterKit
import Foundation

/// XPC helper of Convert tier 1 (DESIGN.md §4.1): runs LGPL ffmpeg for one
/// job at a time, with arguments built only from the `ConverterKit` presets.
/// launchd starts it on the first request and shuts it down when it stays idle.
final class ConverterJob: NSObject, ConverterXPC, @unchecked Sendable {
  private let connection: NSXPCConnection
  private let lock = NSLock()
  private var process: Process?
  /// `cancel()` can arrive before the process exists: the flag remembers it.
  private var cancelRequested = false

  init(connection: NSXPCConnection) {
    self.connection = connection
  }

  private enum Launch {
    case started, cancelled, failed(Error)
  }

  func run(_ job: Data, reply: @escaping @Sendable (String?) -> Void) {
    guard let job = try? JSONDecoder().decode(FFmpegJob.self, from: job) else {
      reply("Invalid request")
      return
    }
    do {
      try job.validate()
    } catch {
      reply(error.message)
      return
    }
    guard let ffmpeg = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) else {
      reply("ffmpeg is not included in this build")
      return
    }

    // ffmpeg writes to a hidden temporary name next to the output and renames it
    // at the end of the job: a failure deletes only the temporary file, never a
    // file that might belong to another job.
    let temporary = job.temporaryOutput(token: UUID().uuidString)
    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = job.commandLine(writingTo: temporary)
    // Children inherit the priority: ffmpeg runs at utility QoS (§5.1, §5.2 rule 6).
    process.qualityOfService = .utility
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice

    // XPC proxies are thread-safe.
    nonisolated(unsafe) let progress = connection.remoteObjectProxy as? ConverterProgressXPC
    let state = ProgressState()
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      // Empty data = end of stream: without this the handler would spin idle.
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      state.appendLog(String(decoding: data, as: UTF8.self))
    }
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      for line in state.progressLines(String(decoding: data, as: UTF8.self)) {
        if let seconds = FFmpegProgress.outTime(in: line), let total = state.duration, total > 0 {
          progress?.progress(min(max(seconds / total, 0), 1))
        }
      }
    }
    process.terminationHandler = { [weak self] finished in
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      // What ffmpeg wrote in the last moments may still be in the pipe.
      if let rest = try? stderr.fileHandleForReading.readToEnd(), !rest.isEmpty {
        state.appendLog(String(decoding: rest, as: UTF8.self))
      }
      let cancelled = self?.lock.withLock { () -> Bool in
        self?.process = nil
        return self?.cancelRequested ?? false
      }
      defer { ConverterJob.exitWhenIdle() }
      if finished.terminationStatus == 0, finished.terminationReason == .exit {
        if ConverterJob.renameWithoutOverwriting(temporary, to: job.output) {
          reply(nil)
        } else {
          try? FileManager.default.removeItem(atPath: temporary)
          reply("Can't save the converted file (a file with that name already exists)")
        }
        return
      }
      try? FileManager.default.removeItem(atPath: temporary)
      if cancelled == true {
        reply("Cancelled")
      } else if finished.terminationReason == .uncaughtSignal {
        reply("ffmpeg stopped (signal \(finished.terminationStatus))")
      } else {
        reply(state.lastError)
      }
    }

    ConverterJob.counter.withLock { ConverterJob.running += 1 }
    // The lock stays held between the `cancelRequested` check, the launch and
    // the assignment: a `cancel()` in between waits and then finds the process.
    let launch: Launch = lock.withLock {
      if cancelRequested { return .cancelled }
      do {
        try process.run()
        self.process = process
        return .started
      } catch {
        return .failed(error)
      }
    }
    switch launch {
    case .started:
      break
    case .cancelled:
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      ConverterJob.exitWhenIdle()
      reply("Cancelled")
    case .failed(let error):
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      ConverterJob.exitWhenIdle()
      reply("Can't start ffmpeg: \(error.localizedDescription)")
    }
  }

  func cancel() {
    let running = lock.withLock { () -> Process? in
      cancelRequested = true
      return process
    }
    running?.terminate()
  }

  /// Renames atomically and fails if the destination already exists.
  static func renameWithoutOverwriting(_ source: String, to destination: String) -> Bool {
    renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0
  }

  /// Jobs in progress across the whole helper.
  nonisolated(unsafe) static var running = 0
  static let counter = NSLock()

  /// "XPC only during the job" (DESIGN.md §5.1): 5 s after the last job the helper
  /// exits; launchd restarts it on the next request.
  static func exitWhenIdle() {
    counter.withLock { running -= 1 }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
      if counter.withLock({ running }) == 0 { exit(0) }
    }
  }
}

/// State read from the two pipes, on different queues.
final class ProgressState: @unchecked Sendable {
  private let lock = NSLock()
  private var log = ""
  private var cachedDuration: Double?
  private var stdoutLines = LineBuffer()

  var duration: Double? { lock.withLock { cachedDuration } }

  func appendLog(_ text: String) {
    lock.withLock {
      log += text
      if log.utf8.count > 64_000 { log = String(log.suffix(32_000)) }
      if cachedDuration == nil { cachedDuration = FFmpegProgress.duration(in: log) }
    }
  }

  /// Complete `-progress` lines: a piece cut in half waits for the rest.
  func progressLines(_ text: String) -> [String] {
    lock.withLock { stdoutLines.append(text) }
  }

  /// Last lines of stderr, for a useful error message.
  var lastError: String {
    let lines = lock.withLock { log }.split(separator: "\n").suffix(3)
    return lines.isEmpty ? "ffmpeg failed" : lines.joined(separator: " ")
  }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: ConverterXPC.self)
    connection.remoteObjectInterface = NSXPCInterface(with: ConverterProgressXPC.self)
    let job = ConverterJob(connection: connection)
    connection.exportedObject = job
    connection.invalidationHandler = { job.cancel() }
    connection.interruptionHandler = { job.cancel() }
    connection.resume()
    return true
  }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
