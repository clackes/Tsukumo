// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ModuleKit

/// Design backend 1 (DESIGN.md §2.1): mediaremote-adapter loaded inside
/// `/usr/bin/perl`, the only way to read the system "Now Playing" since
/// macOS 15.4. It sees any app that is playing (Music, Spotify, Safari, Chrome,
/// Podcasts…), with position and artwork, without permissions. The child process
/// lives only while the island is on and has no periodic wakeups at rest.
@MainActor
final class AdapterMediaBackend: MediaBackend {
  /// Script and library inside the app bundle.
  struct Payload {
    let script: URL
    let library: URL

    /// `nil` if the app was built without the adapter.
    static func inMainBundle() -> Payload? {
      let bundle = Bundle.main
      guard let script = bundle.url(forResource: "run", withExtension: "pl"),
        let frameworks = bundle.privateFrameworksURL
      else { return nil }
      let library = frameworks.appendingPathComponent("libMediaRemoteAdapter.dylib")
      guard FileManager.default.fileExists(atPath: library.path) else { return nil }
      return Payload(script: script, library: library)
    }
  }

  private let payload: Payload
  /// Called once if the process dies on its own: the module switches to backend 2.
  private let onFailure: @MainActor () -> Void
  private var process: Process?
  private var input: FileHandle?
  private var stopping = false
  /// `.process` entry in the bag: it must be closed even when the child dies on its own,
  /// otherwise it would stay alive (with the strong reference to `self`) until `cancelAll()`.
  private var resources: ResourceBag?
  private var processToken: ResourceBag.Token?

  init(payload: Payload, onFailure: @escaping @MainActor () -> Void) {
    self.payload = payload
    self.onFailure = onFailure
  }

  func start(in resources: ResourceBag, onChange: @escaping @MainActor @Sendable (NowPlaying?) -> Void) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [payload.script.path, payload.library.path, "loop"]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    // If the child is already dead, a write on the pipe must not kill the app with SIGPIPE.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    let splitter = LineSplitter()
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      for line in splitter.append(data) {
        guard case .update(let playing) = AdapterLineParser.parse(line, now: Date()) else { continue }
        // The main queue preserves the order of the lines.
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange(playing) } }
      }
    }
    process.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated() } }
    }

    do {
      try process.run()
    } catch {
      stdout.fileHandleForReading.readabilityHandler = nil
      onFailure()
      return
    }
    self.process = process
    input = stdin.fileHandleForWriting
    // Strong reference: the module clears `media` in `stop()` before the bag
    // closes, and with `weak` the perl would never be terminated.
    self.resources = resources
    processToken = resources.add(.process) { self.stop() }
  }

  var canSendCommands: Bool { process?.isRunning == true }

  @discardableResult
  func send(_ command: MediaCommand) -> Bool {
    guard let input, process?.isRunning == true else { return false }
    do {
      try input.write(contentsOf: Data((Self.inlineCommand(command) + "\n").utf8))
      return true
    } catch {
      return false
    }
  }

  @discardableResult
  func seek(to seconds: TimeInterval) -> Bool {
    guard let input, process?.isRunning == true else { return false }
    let line = String(format: "set_time %.3f\n", locale: Locale(identifier: "en_US_POSIX"), max(seconds, 0))
    do {
      try input.write(contentsOf: Data(line.utf8))
      return true
    } catch {
      return false
    }
  }

  /// Commands read by the adapter on its stdin (`executeInlineCommand`).
  static func inlineCommand(_ command: MediaCommand) -> String {
    switch command {
    case .togglePlayPause: "toggle_play_pause"
    case .next: "next_track"
    case .previous: "previous_track"
    }
  }

  private func stop() {
    stopping = true
    (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    try? input?.close()
    if process?.isRunning == true { process?.terminate() }
    process = nil
    input = nil
    processToken = nil
  }

  private func terminated() {
    guard !stopping, process != nil else { return }
    // Closing the bag entry runs `stop()`; without an entry (should not happen) call it by hand.
    if let resources, let processToken {
      self.processToken = nil
      resources.cancel(processToken)
    } else {
      stop()
    }
    resources = nil
    onFailure()
  }
}

/// Splits the child's output into lines. Only the pipe's read handler uses it,
/// and Foundation calls it serially: no lock needed.
private final class LineSplitter: @unchecked Sendable {
  private var buffer = Data()

  func append(_ data: Data) -> [Data] {
    buffer.append(data)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      lines.append(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
    }
    return lines
  }
}

/// A line from the adapter: `NIL` (nothing playing) or JSON
/// `{"type":"data","payload":{…}}` with the track.
enum AdapterLineParser {
  enum Line: Equatable {
    case update(NowPlaying?)
    case ignored
  }

  private struct Envelope: Decodable {
    let type: String?
    let payload: Fields
  }

  private struct Fields: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let isPlaying: Bool?
    let durationMicros: Double?
    let elapsedTimeMicros: Double?
    let timestampEpochMicros: Double?
    let bundleIdentifier: String?
    let artworkDataBase64: String?
  }

  static func parse(_ line: Data, now: Date) -> Line {
    guard let text = String(bytes: line, encoding: .utf8) else { return .ignored }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "NIL" { return .update(nil) }
    guard !trimmed.isEmpty, let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(trimmed.utf8)),
      envelope.type == nil || envelope.type == "data"
    else { return .ignored }
    let fields = envelope.payload
    guard let title = fields.title, !title.isEmpty else { return .update(nil) }
    // The position is valid at the timestamp instant: progress starts from there, without timers.
    let stamp = fields.timestampEpochMicros.map { Date(timeIntervalSince1970: $0 / 1_000_000) }
    return .update(
      NowPlaying(
        title: title,
        artist: fields.artist ?? "",
        album: fields.album ?? "",
        isPlaying: fields.isPlaying ?? false,
        duration: fields.durationMicros.flatMap { $0 > 0 ? $0 / 1_000_000 : nil },
        position: fields.elapsedTimeMicros.map { max($0 / 1_000_000, 0) },
        updatedAt: stamp.map { min($0, now) } ?? now,
        bundleID: fields.bundleIdentifier ?? "",
        artwork: fields.artworkDataBase64.flatMap { Data(base64Encoded: $0) }
      )
    )
  }
}
