// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Buffering of a channel. Never `.unbounded` (DESIGN.md §4.3).
public enum EventBuffering: Sendable, Equatable {
  /// State stream: only the latest value counts.
  case latest
  /// Discrete events: the last `n`, with `n` small and documented.
  case newest(Int)

  var limit: Int {
    switch self {
    case .latest: 1
    case .newest(let count): max(1, count)
    }
  }
}

/// Typed channel of the `EventBus`. It is a constant value: declaring it does not
/// create anything until someone subscribes or publishes.
public struct EventChannel<Payload: Sendable>: Sendable {
  public let name: String
  public let buffering: EventBuffering

  public init(_ name: String, buffering: EventBuffering) {
    self.name = name
    self.buffering = buffering
  }
}

/// Token of a subscription. `cancel()` ends the subscriber's stream; the
/// broadcaster removes it from the registry through `onTermination`.
public struct EventSubscription: Sendable {
  private let onCancel: @Sendable () -> Void

  init(onCancel: @escaping @Sendable () -> Void) {
    self.onCancel = onCancel
  }

  public func cancel() {
    onCancel()
  }
}

/// Multicast broadcaster of a channel: one `Continuation` per subscriber.
/// A shared `AsyncStream` would have a single consumer.
public actor Broadcaster<Payload: Sendable> {
  private let buffering: EventBuffering
  private var continuations: [UInt64: AsyncStream<Payload>.Continuation] = [:]
  private var nextID: UInt64 = 0

  init(buffering: EventBuffering) {
    self.buffering = buffering
  }

  public var subscriberCount: Int { continuations.count }

  public func subscribe() -> (stream: AsyncStream<Payload>, subscription: EventSubscription) {
    nextID += 1
    let id = nextID
    let (stream, continuation) = AsyncStream.makeStream(
      of: Payload.self,
      bufferingPolicy: .bufferingNewest(buffering.limit)
    )
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.remove(id) }
    }
    return (stream, EventSubscription { continuation.finish() })
  }

  public func publish(_ payload: Payload) {
    for continuation in continuations.values {
      continuation.yield(payload)
    }
  }

  private func remove(_ id: UInt64) {
    continuations[id] = nil
  }
}

/// Event bus between modules: modules talk to each other only through here.
public actor EventBus {
  private var broadcasters: [String: any Sendable] = [:]

  public init() {}

  /// Broadcaster of the channel, created on first use.
  public func broadcaster<Payload>(for channel: EventChannel<Payload>) -> Broadcaster<Payload> {
    if let existing = broadcasters[channel.name] {
      guard let typed = existing as? Broadcaster<Payload> else {
        preconditionFailure("Channel '\(channel.name)' already registered with a different payload type")
      }
      return typed
    }
    let created = Broadcaster<Payload>(buffering: channel.buffering)
    broadcasters[channel.name] = created
    return created
  }

  public func subscribe<Payload>(
    to channel: EventChannel<Payload>
  ) async -> (stream: AsyncStream<Payload>, subscription: EventSubscription) {
    await broadcaster(for: channel).subscribe()
  }

  public func publish<Payload>(_ payload: Payload, on channel: EventChannel<Payload>) async {
    await broadcaster(for: channel).publish(payload)
  }

  public func subscriberCount<Payload>(of channel: EventChannel<Payload>) async -> Int {
    await broadcaster(for: channel).subscriberCount
  }
}
