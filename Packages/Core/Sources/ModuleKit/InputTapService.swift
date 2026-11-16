// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import Synchronization

/// The app's two taps (DESIGN.md §4.3). A possible third HID tap for the media
/// keys is the hard limit and does not exist until spike 5 requires it.
public enum TapKind: String, Sendable, Hashable, CaseIterable {
  /// `.listenOnly`: observes without being able to modify. Permission: Input Monitoring.
  case listen
  /// `.defaultTap`: can consume or modify events. Permission: Accessibility.
  case active
}

public enum InputTapError: Error, Equatable {
  /// The system did not create the tap: permission missing or not yet effective
  /// (happens until the process is restarted after the grant).
  case tapUnavailable(TapKind)
  case emptyMask
}

/// Handler of a subscriber. Runs on the tap thread, not on the MainActor: it must
/// be O(1) and thread-safe. Returning `nil` consumes the event (active tap only).
public typealias InputTapHandler = @Sendable (CGEventType, CGEvent) -> CGEvent?

/// Dispatches an event to the subscribers. Called by the backend from the tap thread.
public typealias InputTapDispatch = @Sendable (CGEventType, CGEvent) -> CGEvent?

/// A tap installed in the system.
public protocol InstalledTap: AnyObject, Sendable {
  func uninstall()
}

/// Creates the real taps. Abstract so the logic can be tried without permissions.
public protocol EventTapBackend: Sendable {
  func install(kind: TapKind, mask: CGEventMask, dispatch: @escaping InputTapDispatch) -> (any InstalledTap)?
}

/// Subscription to a tap. Must be put in the module's `ResourceBag`.
@MainActor
public final class InputTapSubscription {
  private var onCancel: (@MainActor () -> Void)?

  init(onCancel: @escaping @MainActor () -> Void) {
    self.onCancel = onCancel
  }

  public func cancel() {
    onCancel?()
    onCancel = nil
  }
}

/// At most one tap per type in the whole app. Each module subscribes with an
/// event mask; the tap uses the union of the masks, is recreated
/// when the union changes and removed when it is left with no subscribers.
@MainActor
public final class InputTapService {
  private struct Subscriber: Sendable {
    let id: UInt64
    let mask: CGEventMask
    let handler: InputTapHandler
  }

  /// Subscribers of a tap, read from the tap thread and written by the MainActor.
  /// The generation says which system tap is the good one: while a tap is being
  /// replaced the two coexist for a moment, and the old one must let events
  /// pass without delivering them, or subscribers would see them twice.
  private final class Roster: Sendable {
    private let state = Mutex<(subscribers: [Subscriber], generation: UInt64)>(([], 0))

    var generation: UInt64 { state.withLock { $0.generation } }

    func replace(_ new: [Subscriber]) {
      state.withLock { $0.subscribers = new }
    }

    /// Makes the tap of this generation active, with its subscribers, in one go.
    func activate(_ generation: UInt64, subscribers: [Subscriber]) {
      state.withLock { $0 = (subscribers, generation) }
    }

    func dispatch(type: CGEventType, event: CGEvent, canConsume: Bool, generation: UInt64) -> CGEvent? {
      let bit = CGEventMask(1) << CGEventMask(type.rawValue)
      let current: [Subscriber]? = state.withLock { $0.generation == generation ? $0.subscribers : nil }
      guard let current else { return event }
      var event = event
      for subscriber in current where subscriber.mask & bit != 0 {
        let result = subscriber.handler(type, event)
        guard canConsume else { continue }
        guard let result else { return nil }
        event = result
      }
      return event
    }
  }

  private struct Tap {
    var subscribers: [Subscriber] = []
    var installed: (any InstalledTap)?
    var mask: CGEventMask = 0
    let roster = Roster()
  }

  private let backend: any EventTapBackend
  private var taps: [TapKind: Tap] = [:]
  private var nextID: UInt64 = 0

  public init(backend: any EventTapBackend = CGEventTapBackend()) {
    self.backend = backend
  }

  /// Mask currently installed per tap type; absent if the tap does not exist.
  public var installedMasks: [TapKind: CGEventMask] {
    taps.compactMapValues { $0.installed == nil ? nil : $0.mask }
  }

  public func subscriberCount(_ kind: TapKind) -> Int {
    taps[kind]?.subscribers.count ?? 0
  }

  /// Subscribes a handler. If the tap cannot be created, the subscription is not
  /// left registered and `.tapUnavailable` is thrown.
  public func subscribe(
    _ kind: TapKind,
    mask: CGEventMask,
    handler: @escaping InputTapHandler
  ) throws(InputTapError) -> InputTapSubscription {
    guard mask != 0 else { throw .emptyMask }
    nextID += 1
    let id = nextID
    var tap = taps[kind] ?? Tap()
    let before = tap
    tap.subscribers.append(Subscriber(id: id, mask: mask, handler: handler))

    guard reconcile(&tap, kind: kind) else {
      taps[kind] = before
      before.roster.replace(before.subscribers)
      throw .tapUnavailable(kind)
    }
    taps[kind] = tap
    return InputTapSubscription { [weak self] in self?.unsubscribe(id, from: kind) }
  }

  private func unsubscribe(_ id: UInt64, from kind: TapKind) {
    guard var tap = taps[kind] else { return }
    tap.subscribers.removeAll { $0.id == id }
    _ = reconcile(&tap, kind: kind)
    taps[kind] = tap.subscribers.isEmpty ? nil : tap
  }

  /// Aligns the system tap with the subscribers. `false` if a tap was needed and
  /// it could not be created; in that case the previous tap stays as it was.
  private func reconcile(_ tap: inout Tap, kind: TapKind) -> Bool {
    let union = tap.subscribers.reduce(CGEventMask(0)) { $0 | $1.mask }

    if union == 0 {
      tap.installed?.uninstall()
      tap.installed = nil
      tap.mask = 0
      tap.roster.replace([])
      return true
    }

    if tap.installed == nil || union != tap.mask {
      let roster = tap.roster
      let canConsume = kind == .active
      // The new tap is born inactive: until it becomes the good generation
      // it lets everything pass, and the old one stops delivering at the same instant.
      let generation = roster.generation &+ 1
      let replacement = backend.install(kind: kind, mask: union) { type, event in
        roster.dispatch(type: type, event: event, canConsume: canConsume, generation: generation)
      }
      guard let replacement else { return false }
      roster.activate(generation, subscribers: tap.subscribers)
      tap.installed?.uninstall()
      tap.installed = replacement
      tap.mask = union
    }
    tap.roster.replace(tap.subscribers)
    return true
  }
}

extension ResourceBag {
  /// Subscription to a tap of the `InputTapService`.
  @discardableResult
  public func addInputTap(_ subscription: InputTapSubscription) -> Token {
    add(.monitor) { subscription.cancel() }
  }
}
