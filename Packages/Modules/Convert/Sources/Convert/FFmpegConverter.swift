// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import ConverterKit
import Foundation

enum FFmpegError: LocalizedError {
  case unavailable
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable: String(localized: "The add-on engine isn't available")
    case .failed(let message): message
    }
  }
}

/// Tier 1 client: sends a job to the `Converter.xpc` helper and follows
/// its progress. The connection lives only for the duration of the job.
enum FFmpegConverter {
  /// ffmpeg is in the helper's bundle only if the build included it.
  static var isAvailable: Bool {
    let ffmpeg = Bundle.main.bundleURL
      .appendingPathComponent("Contents/XPCServices/Converter.xpc/Contents/Resources/ffmpeg")
    return FileManager.default.isExecutableFile(atPath: ffmpeg.path)
  }

  static func convert(
    _ source: URL, to preset: FFmpegPreset, progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> URL {
    guard isAvailable else { throw FFmpegError.unavailable }
    let output = OutputNamer.url(for: source, extension: preset.fileExtension)
    let job = FFmpegJob(input: source.path, output: output.path, preset: preset)
    let data = try JSONEncoder().encode(job)
    let session = XPCSession(progress: progress)
    defer { session.invalidate() }
    let failure: String? = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        session.run(data) { result in continuation.resume(with: result) }
      }
    } onCancel: {
      session.cancel()
    }
    if Task.isCancelled {
      // Succeeded but cancelled in the meantime: the file is no longer needed. It is removed only
      // if the job succeeded (otherwise the name might belong to someone else).
      if failure == nil { try? FileManager.default.removeItem(at: output) }
      throw CancellationError()
    }
    if let failure { throw FFmpegError.failed(failure) }
    return output
  }
}

/// Receives progress from the helper.
private final class ProgressReceiver: NSObject, ConverterProgressXPC, @unchecked Sendable {
  let handler: @Sendable (Double) -> Void
  init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }
  func progress(_ fraction: Double) { handler(fraction) }
}

/// One XPC connection per job. NSXPCConnection calls are
/// thread-safe; the completion state is protected by a lock.
private final class XPCSession: @unchecked Sendable {
  private let connection = NSXPCConnection(serviceName: ConverterService.name)
  private let lock = NSLock()
  private var completion: ((Result<String?, Error>) -> Void)?
  /// Cancellation can arrive before `run`: the flag remembers it.
  private var cancelled = false
  private var started = false

  init(progress: @escaping @Sendable (Double) -> Void) {
    connection.remoteObjectInterface = NSXPCInterface(with: ConverterXPC.self)
    connection.exportedInterface = NSXPCInterface(with: ConverterProgressXPC.self)
    connection.exportedObject = ProgressReceiver(progress)
    connection.invalidationHandler = { [weak self] in
      self?.finish(.failure(FFmpegError.failed(String(localized: "The add-on engine stopped unexpectedly"))))
    }
    connection.interruptionHandler = connection.invalidationHandler
    connection.resume()
  }

  func run(_ job: Data, completion: @escaping (Result<String?, Error>) -> Void) {
    // Flag and send under the same lock: `cancel()` cannot slip in between
    // and send `cancel` to the helper before `run`.
    let wasCancelled = lock.withLock { () -> Bool in
      self.completion = completion
      if cancelled { return true }
      started = true
      let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
        self?.finish(.failure(error))
      }
      (proxy as? ConverterXPC)?.run(job) { [weak self] failure in self?.finish(.success(failure)) }
      return false
    }
    // Cancelled before starting: close without disturbing the helper.
    if wasCancelled { finish(.failure(CancellationError())) }
  }

  func cancel() {
    lock.withLock {
      cancelled = true
      guard started else { return }
      (connection.remoteObjectProxy as? ConverterXPC)?.cancel()
    }
  }

  func invalidate() {
    connection.invalidationHandler = nil
    connection.interruptionHandler = nil
    connection.invalidate()
  }

  private func finish(_ result: Result<String?, Error>) {
    let completion = lock.withLock {
      defer { self.completion = nil }
      return self.completion
    }
    completion?(result)
  }
}
