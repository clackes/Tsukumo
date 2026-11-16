// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import ModuleKit

private final class FakeTap: InstalledTap {
  let kind: TapKind
  let mask: CGEventMask
  let dispatch: InputTapDispatch
  private let removed = Mutex(false)

  init(kind: TapKind, mask: CGEventMask, dispatch: @escaping InputTapDispatch) {
    self.kind = kind
    self.mask = mask
    self.dispatch = dispatch
  }

  var isInstalled: Bool { !removed.withLock { $0 } }

  func uninstall() {
    removed.withLock { $0 = true }
  }
}

private final class FakeBackend: EventTapBackend {
  private let state = Mutex<(taps: [FakeTap], refuse: Bool)>(([], false))

  var taps: [FakeTap] { state.withLock { $0.taps } }
  var live: [FakeTap] { taps.filter(\.isInstalled) }
  func refuse(_ value: Bool) { state.withLock { $0.refuse = value } }

  func install(kind: TapKind, mask: CGEventMask, dispatch: @escaping InputTapDispatch) -> (any InstalledTap)? {
    state.withLock { state in
      guard !state.refuse else { return nil }
      let tap = FakeTap(kind: kind, mask: mask, dispatch: dispatch)
      state.taps.append(tap)
      return tap
    }
  }
}

private func mask(_ types: CGEventType...) -> CGEventMask {
  types.reduce(0) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
}

private func keyEvent(down: Bool = true) throws -> CGEvent {
  try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down))
}

@MainActor
@Suite("InputTapService")
struct InputTapServiceTests {
  private let backend = FakeBackend()

  @Test("without subscribers no tap exists")
  func noSubscribersNoTap() {
    let service = InputTapService(backend: backend)
    #expect(service.installedMasks.isEmpty)
    #expect(backend.taps.isEmpty)
  }

  @Test("the tap uses the union of the masks and is recreated only when it changes")
  func unionOfMasks() throws {
    let service = InputTapService(backend: backend)
    let first = try service.subscribe(.listen, mask: mask(.keyDown)) { _, event in event }
    #expect(backend.live.map(\.mask) == [mask(.keyDown)])

    // Same mask: no new tap.
    let second = try service.subscribe(.listen, mask: mask(.keyDown)) { _, event in event }
    #expect(backend.taps.count == 1)

    // Wider mask: the tap is recreated with the union, the old one removed.
    let third = try service.subscribe(.listen, mask: mask(.keyUp)) { _, event in event }
    #expect(backend.taps.count == 2)
    #expect(backend.live.map(\.mask) == [mask(.keyDown, .keyUp)])
    #expect(service.installedMasks == [.listen: mask(.keyDown, .keyUp)])

    // Removing the subscriber that widened the mask, the union narrows.
    third.cancel()
    #expect(backend.live.map(\.mask) == [mask(.keyDown)])

    first.cancel()
    #expect(backend.live.count == 1)
    second.cancel()
    #expect(backend.live.isEmpty)
    #expect(service.installedMasks.isEmpty)
    #expect(service.subscriberCount(.listen) == 0)
  }

  @Test("listen and active are two distinct taps, never more than one per type")
  func oneTapPerKind() throws {
    let service = InputTapService(backend: backend)
    let listen = try service.subscribe(.listen, mask: mask(.keyDown)) { _, event in event }
    let active = try service.subscribe(.active, mask: mask(.flagsChanged)) { _, event in event }
    let another = try service.subscribe(.active, mask: mask(.flagsChanged)) { _, event in event }

    #expect(backend.live.count == 2)
    #expect(Set(backend.live.map(\.kind)) == [.listen, .active])
    for subscription in [listen, active, another] { subscription.cancel() }
    #expect(backend.live.isEmpty)
  }

  @Test("a replaced tap lets events pass without delivering them: no duplicates")
  func replacedTapDoesNotDispatch() throws {
    let service = InputTapService(backend: backend)
    let downs = Mutex(0)
    let first = try service.subscribe(.active, mask: mask(.keyDown)) { _, _ in
      downs.withLock { $0 += 1 }
      return nil
    }
    let old = try #require(backend.live.first)
    // A wider mask recreates the tap.
    let second = try service.subscribe(.active, mask: mask(.keyUp)) { _, event in event }
    let current = try #require(backend.live.first)
    #expect(old !== current)

    // An event still in flight in the old tap passes intact and does not reach the subscribers.
    #expect(old.dispatch(.keyDown, try keyEvent()) != nil)
    #expect(downs.withLock { $0 } == 0)
    #expect(current.dispatch(.keyDown, try keyEvent()) == nil)
    #expect(downs.withLock { $0 } == 1)
    first.cancel()
    second.cancel()
  }

  @Test("events reach only the subscribers with the right mask")
  func dispatchRespectsMasks() throws {
    let service = InputTapService(backend: backend)
    let downs = Mutex(0)
    let ups = Mutex(0)
    let first = try service.subscribe(.listen, mask: mask(.keyDown)) { _, event in
      downs.withLock { $0 += 1 }
      return event
    }
    let second = try service.subscribe(.listen, mask: mask(.keyUp)) { _, event in
      ups.withLock { $0 += 1 }
      return event
    }
    let tap = try #require(backend.live.first)

    _ = tap.dispatch(.keyDown, try keyEvent())
    _ = tap.dispatch(.keyDown, try keyEvent())
    _ = tap.dispatch(.keyUp, try keyEvent(down: false))

    #expect(downs.withLock { $0 } == 2)
    #expect(ups.withLock { $0 } == 1)

    // After cancellation the handler is no longer called.
    first.cancel()
    let remaining = try #require(backend.live.first)
    _ = remaining.dispatch(.keyDown, try keyEvent())
    #expect(downs.withLock { $0 } == 2)
    second.cancel()
  }

  @Test("a listen tap never consumes; an active tap stops at the first one that consumes")
  func consumption() throws {
    let service = InputTapService(backend: backend)
    let listen = try service.subscribe(.listen, mask: mask(.keyDown)) { _, _ in nil }
    let listenTap = try #require(backend.live.first { $0.kind == .listen })
    #expect(listenTap.dispatch(.keyDown, try keyEvent()) != nil)

    let reachedSecond = Mutex(false)
    let consumer = try service.subscribe(.active, mask: mask(.keyDown)) { _, _ in nil }
    let follower = try service.subscribe(.active, mask: mask(.keyDown)) { _, event in
      reachedSecond.withLock { $0 = true }
      return event
    }
    let activeTap = try #require(backend.live.first { $0.kind == .active })
    #expect(activeTap.dispatch(.keyDown, try keyEvent()) == nil)
    #expect(!reachedSecond.withLock { $0 })

    for subscription in [listen, consumer, follower] { subscription.cancel() }
  }

  @Test("if the system refuses the tap the subscription is not left registered")
  func unavailableTap() throws {
    let service = InputTapService(backend: backend)
    backend.refuse(true)
    #expect(throws: InputTapError.tapUnavailable(.active)) {
      _ = try service.subscribe(.active, mask: mask(.keyDown)) { _, event in event }
    }
    #expect(service.subscriberCount(.active) == 0)
    #expect(service.installedMasks.isEmpty)

    // With a tap already active, a refusal on recreation leaves the existing one intact.
    backend.refuse(false)
    let existing = try service.subscribe(.active, mask: mask(.keyDown)) { _, event in event }
    backend.refuse(true)
    #expect(throws: InputTapError.tapUnavailable(.active)) {
      _ = try service.subscribe(.active, mask: mask(.keyUp)) { _, event in event }
    }
    #expect(backend.live.map(\.mask) == [mask(.keyDown)])
    #expect(service.subscriberCount(.active) == 1)
    existing.cancel()
  }

  @Test("an empty mask is an error")
  func emptyMask() {
    let service = InputTapService(backend: backend)
    #expect(throws: InputTapError.emptyMask) {
      _ = try service.subscribe(.listen, mask: 0) { _, event in event }
    }
  }

  @Test("the subscription in the ResourceBag is closed by cancelAll")
  func resourceBagIntegration() throws {
    let service = InputTapService(backend: backend)
    let bag = ResourceBag()
    bag.addInputTap(try service.subscribe(.listen, mask: mask(.keyDown)) { _, event in event })
    #expect(bag.snapshot == [.monitor: 1])
    #expect(backend.live.count == 1)

    bag.cancelAll()
    #expect(backend.live.isEmpty)
  }
}
