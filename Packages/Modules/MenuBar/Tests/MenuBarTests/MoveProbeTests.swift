// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import MenuBar

/// Manual probe, off by default: lists the bar icons and, if
/// requested, moves one with the real ⌘ drag.
///
///     TSUKUMO_MENUBAR_PROBE=list swift test --filter MoveProbe
///     TSUKUMO_MENUBAR_PROBE="<id icona>|-1" swift test --filter MoveProbe
///
/// Accessibility is needed for the terminal that launches the tests.
@Suite struct MoveProbeTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TSUKUMO_MENUBAR_PROBE"] != nil))
  @MainActor func probe() async throws {
    let request = ProcessInfo.processInfo.environment["TSUKUMO_MENUBAR_PROBE"] ?? "list"
    let model = MenuBarOrderModel()
    await model.refresh()
    for item in model.items { print("icon \(item.id) | \(item.title) | \(item.frame)") }
    let parts = request.split(separator: "|")
    guard parts.count == 2, let offset = Int(parts[1]) else { return }
    let id = String(parts[0])
    let before = try #require(model.items.firstIndex { $0.id == id })
    let started = ContinuousClock.now
    await model.move(id, by: offset)
    print("move took \(ContinuousClock.now - started), message: \(model.message ?? "none")")
    for item in model.items { print("after \(item.id) | \(item.frame.minX)") }
    #expect(model.items.firstIndex { $0.id == id } == before + offset)
    #expect(model.message == nil)
  }
}
