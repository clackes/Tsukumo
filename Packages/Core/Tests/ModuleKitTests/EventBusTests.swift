// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Testing

@testable import ModuleKit

@Suite("EventBus")
struct EventBusTests {
  static let events = EventChannel<Int>("test.events", buffering: .newest(8))
  static let status = EventChannel<String>("test.status", buffering: .latest)

  @Test("multicast: every subscriber receives all the events")
  func multicast() async {
    let bus = EventBus()
    let first = await bus.subscribe(to: Self.events)
    let second = await bus.subscribe(to: Self.events)
    #expect(await bus.subscriberCount(of: Self.events) == 2)

    for value in 1...3 {
      await bus.publish(value, on: Self.events)
    }
    first.subscription.cancel()
    second.subscription.cancel()

    var seenByFirst: [Int] = []
    for await value in first.stream { seenByFirst.append(value) }
    var seenBySecond: [Int] = []
    for await value in second.stream { seenBySecond.append(value) }

    #expect(seenByFirst == [1, 2, 3])
    #expect(seenBySecond == [1, 2, 3])
  }

  @Test("a state stream keeps only the latest value")
  func latestKeepsNewestOnly() async {
    let bus = EventBus()
    let subscriber = await bus.subscribe(to: Self.status)
    for value in ["a", "b", "c"] {
      await bus.publish(value, on: Self.status)
    }
    subscriber.subscription.cancel()

    var seen: [String] = []
    for await value in subscriber.stream { seen.append(value) }
    #expect(seen == ["c"])
  }

  @Test("cancelling the subscription removes it from the broadcaster's registry")
  func cancelRemovesSubscriber() async throws {
    let bus = EventBus()
    let subscriber = await bus.subscribe(to: Self.events)
    #expect(await bus.subscriberCount(of: Self.events) == 1)

    subscriber.subscription.cancel()

    try await waitUntil { await bus.subscriberCount(of: Self.events) == 0 }
    #expect(await bus.subscriberCount(of: Self.events) == 0)
  }

  @Test("publishing without subscribers accumulates nothing")
  func publishWithoutSubscribers() async {
    let bus = EventBus()
    await bus.publish(1, on: Self.events)
    let late = await bus.subscribe(to: Self.events)
    late.subscription.cancel()

    var seen: [Int] = []
    for await value in late.stream { seen.append(value) }
    #expect(seen.isEmpty)
  }
}
