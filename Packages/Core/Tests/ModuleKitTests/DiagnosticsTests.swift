// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import ModuleKit

@MainActor
@Suite("Diagnostics: rotation and redaction")
struct DiagnosticsTests {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tsukumo-diag-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("store writes a file; storedFiles sees it")
  func storeAndList() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let diag = Diagnostics(configuration: .init(directory: dir, retainDays: 7))
    diag.store(payloadJSON: Data("{\"ok\": true}".utf8))
    let files = diag.storedFiles()
    #expect(files.count == 1)
    #expect(files[0].pathExtension == "json")
  }

  @Test("rotate deletes files older than retainDays")
  func rotation() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let diag = Diagnostics(configuration: .init(directory: dir, retainDays: 2, now: { now }))
    let oldFile = dir.appendingPathComponent("metrics-vecchio.json")
    try Data("{}".utf8).write(to: oldFile)
    // Old: 10 days ago.
    let tenDaysAgo = now.addingTimeInterval(-10 * 86400)
    try FileManager.default.setAttributes(
      [.modificationDate: tenDaysAgo], ofItemAtPath: oldFile.path)
    // Recent: saved just now.
    diag.store(payloadJSON: Data("{\"a\": 1}".utf8))
    let after = diag.storedFiles().map(\.lastPathComponent)
    #expect(!after.contains("metrics-vecchio.json"))
    #expect(after.count == 1)
  }

  @Test("filenameTimestamp replaces the colons")
  func filenameTimestamp() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let ts = DiagnosticsFormatter.filenameTimestamp(from: date)
    #expect(!ts.contains(":"))
    #expect(ts.contains("T"))
  }

  @Test("redactedSummary lists the files but does not read their content")
  func summary() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let diag = Diagnostics(configuration: .init(directory: dir, retainDays: 7, now: { now }))
    diag.store(payloadJSON: Data("{\"sensitive\": \"x\"}".utf8))
    let context = DiagnosticsContext(
      osBuild: "27A1", appVersion: "0.0.1", appBuild: "1", chip: "Apple M4",
      enabledModules: ["island", "sound"],
      permissionStatus: ["accessibility": "granted"], compatVersion: 3)
    let summary = diag.redactedSummary(context: context)
    #expect(summary["osBuild"] as? String == "27A1")
    #expect(summary["compatVersion"] as? Int == 3)
    let payloads = summary["payloads"] as? [String] ?? []
    #expect(payloads.count == 1)
    // The summary does not contain the file content.
    let serialized = try JSONSerialization.data(withJSONObject: summary)
    #expect(String(bytes: serialized, encoding: .utf8)?.contains("sensitive") == false)
  }
}
