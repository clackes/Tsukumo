// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MetricKit
import OSLog

/// Local diagnostics (DESIGN.md §3.6, §4.3): MetricKit subscriber, payload rotation
/// on disk, redacted export. **No network.** Files live in the app's
/// Application Support and are deleted after `retainDays`.
///
/// The stateful part (file system, dates, MetricKit subscription) is
/// separated from the pure rotation and redaction logic, so tests
/// cover everything without touching the disk.
@MainActor
public final class Diagnostics {
  public struct Configuration: Sendable {
    public var directory: URL
    public var retainDays: Int
    public var now: @Sendable () -> Date

    public init(directory: URL, retainDays: Int = 7, now: @escaping @Sendable () -> Date = Date.init) {
      self.directory = directory
      self.retainDays = retainDays
      self.now = now
    }
  }

  private let configuration: Configuration
  private let log = Logger(subsystem: "dev.local.tsukumo", category: "diagnostics")
  private var subscriber: MetricSubscriber?

  public init(configuration: Configuration) {
    self.configuration = configuration
  }

  /// Subscribes to MetricKit and creates the diagnostics folder if missing. To
  /// be called once at app start. Without the subscription the rest of the
  /// API still works: reads and rotation operate on what is
  /// on disk.
  public func start() throws {
    try FileManager.default.createDirectory(
      at: configuration.directory, withIntermediateDirectories: true)
    let subscriber = MetricSubscriber(sink: self)
    self.subscriber = subscriber
    MXMetricManager.shared.add(subscriber)
  }

  public func stop() {
    if let subscriber {
      MXMetricManager.shared.remove(subscriber)
      self.subscriber = nil
    }
  }

  /// List of the metric files currently saved, from newest to
  /// oldest.
  public func storedFiles() -> [URL] {
    let fm = FileManager.default
    let items =
      (try? fm.contentsOfDirectory(
        atPath: configuration.directory.path)) ?? []
    return items.filter { $0.hasSuffix(".json") }
      .map { configuration.directory.appendingPathComponent($0) }
      .sorted { Self.modified($0) > Self.modified($1) }
  }

  /// Deletes files older than `retainDays`.
  public func rotate() {
    let cutoff = configuration.now().addingTimeInterval(-TimeInterval(configuration.retainDays) * 86400)
    for url in storedFiles() where Self.modified(url) < cutoff {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func modified(_ url: URL) -> Date {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
      ?? .distantPast
  }

  /// Saves a MetricKit payload as JSON in a file with an ISO-8601 name.
  /// Public for tests too: so we can write it without waiting for
  /// MetricKit to deliver a payload.
  public func store(payloadJSON data: Data, date: Date? = nil) {
    let timestamp = date ?? configuration.now()
    let url = configuration.directory.appendingPathComponent(
      "metrics-\(DiagnosticsFormatter.filenameTimestamp(from: timestamp)).json")
    try? data.write(to: url, options: [.atomic])
    // The file's modification date is the source of truth for rotation:
    // we align it to the logical `now`, so tests with injected time
    // work and the file is not thrown away as soon as it is written.
    try? FileManager.default.setAttributes(
      [.modificationDate: timestamp], ofItemAtPath: url.path)
    rotate()
  }

  /// Redacted dump to pass to the "Send feedback" button (DESIGN §3.6):
  /// list of available files and context information, without personal
  /// content.
  public func redactedSummary(context: DiagnosticsContext) -> [String: Any] {
    [
      "osBuild": context.osBuild,
      "appVersion": context.appVersion,
      "appBuild": context.appBuild,
      "chip": context.chip,
      "enabledModules": context.enabledModules,
      "permissionStatus": context.permissionStatus,
      "compatVersion": context.compatVersion,
      "payloads": storedFiles().map(\.lastPathComponent),
      "generatedAt": DiagnosticsFormatter.iso8601(from: configuration.now()),
    ]
  }
}

/// Context information the app passes to `Diagnostics.redactedSummary`.
/// They are all already derivable from known sources; here we keep only what
/// DESIGN says (§3.6).
public struct DiagnosticsContext: Sendable {
  public var osBuild: String
  public var appVersion: String
  public var appBuild: String
  public var chip: String
  public var enabledModules: [String]
  public var permissionStatus: [String: String]
  public var compatVersion: Int

  public init(
    osBuild: String, appVersion: String, appBuild: String, chip: String,
    enabledModules: [String], permissionStatus: [String: String], compatVersion: Int
  ) {
    self.osBuild = osBuild
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.chip = chip
    self.enabledModules = enabledModules
    self.permissionStatus = permissionStatus
    self.compatVersion = compatVersion
  }
}

/// Pure formatting functions, separated for tests.
public enum DiagnosticsFormatter {
  public static func filenameTimestamp(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
    // ":" is not a valid file character on some volumes; we replace it.
    return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
  }

  public static func iso8601(from date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

/// The real MetricKit subscriber: isolated so `Diagnostics` stays testable
/// without instantiating `MXMetricManager`.
@MainActor
private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
  private let sink: Diagnostics

  init(sink: Diagnostics) { self.sink = sink }

  nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
    let encoded = payloads.map { $0.jsonRepresentation() }
    guard
      let combined = try? JSONSerialization.data(
        withJSONObject: encoded.compactMap { try? JSONSerialization.jsonObject(with: $0) })
    else { return }
    Task { @MainActor [sink] in sink.store(payloadJSON: combined) }
  }

  nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
    let encoded = payloads.map { $0.jsonRepresentation() }
    guard
      let combined = try? JSONSerialization.data(
        withJSONObject: encoded.compactMap { try? JSONSerialization.jsonObject(with: $0) })
    else { return }
    Task { @MainActor [sink] in sink.store(payloadJSON: combined) }
  }
}
