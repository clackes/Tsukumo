// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing

@testable import ModuleKit

@MainActor
@Suite("ResourceBag")
struct ResourceBagTests {
  @Test("cancelAll closes everything in reverse order and leaves the bag empty")
  func cancelAllEmptiesBag() {
    let bag = ResourceBag()
    var closed: [Int] = []
    bag.add(.other) { closed.append(1) }
    bag.add(.window) { closed.append(2) }
    bag.add(.other) { closed.append(3) }

    #expect(bag.count == 3)
    #expect(bag.snapshot == [.other: 2, .window: 1])

    bag.cancelAll()

    #expect(closed == [3, 2, 1])
    #expect(bag.isEmpty)
  }

  @Test("cancel(token) closes a single resource, only once")
  func cancelSingleToken() {
    let bag = ResourceBag()
    var closed = 0
    let token = bag.add(.other) { closed += 1 }
    bag.add(.other) {}

    bag.cancel(token)
    bag.cancel(token)

    #expect(closed == 1)
    #expect(bag.count == 1)
  }

  @Test("timer tolerance does not drop below 10% of the interval")
  func leewayFloor() {
    #expect(ResourceBag.leeway(interval: .seconds(10), requested: nil) == .seconds(1))
    #expect(ResourceBag.leeway(interval: .seconds(10), requested: .milliseconds(1)) == .seconds(1))
    #expect(ResourceBag.leeway(interval: .seconds(10), requested: .seconds(3)) == .seconds(3))
  }

  @Test("a timer fires and stops when the bag is closed")
  func timerFiresAndStops() async throws {
    let bag = ResourceBag()
    var ticks = 0
    bag.addTimer(every: .milliseconds(20)) { ticks += 1 }
    #expect(bag.snapshot == [.timer: 1])

    try await waitUntil { ticks >= 2 }
    bag.cancelAll()
    let frozen = ticks
    try await Task.sleep(for: .milliseconds(120))

    #expect(ticks == frozen)
    #expect(bag.isEmpty)
  }

  @Test("an observer receives notifications only while the bag is open")
  func observerLifecycle() {
    let bag = ResourceBag()
    let center = NotificationCenter()
    let name = Notification.Name("tsukumo.test")
    var received = 0
    bag.addObserver(name, center: center) { received += 1 }

    center.post(name: name, object: nil)
    #expect(received == 1)

    bag.cancelAll()
    center.post(name: name, object: nil)
    #expect(received == 1)
  }

  @Test("global .mouseMoved monitors are rejected")
  func mouseMovedMonitorRejected() {
    let bag = ResourceBag()
    #expect(!ResourceBag.isAllowedGlobalMonitorMask(.mouseMoved))
    #expect(!ResourceBag.isAllowedGlobalMonitorMask([.leftMouseDown, .mouseMoved]))
    #expect(ResourceBag.isAllowedGlobalMonitorMask([.leftMouseDown, .leftMouseDragged, .leftMouseUp]))
    #expect(throws: ResourceBagError.mouseMovedMonitorForbidden) {
      try bag.addGlobalMonitor(matching: [.leftMouseDown, .mouseMoved]) { _ in }
    }
    #expect(bag.isEmpty)
  }
}

/// Waits for a condition on the MainActor, with a time limit.
@MainActor
func waitUntil(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !(await condition()) {
    guard ContinuousClock.now < deadline else {
      Issue.record("Condition not reached within \(timeout)")
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}
