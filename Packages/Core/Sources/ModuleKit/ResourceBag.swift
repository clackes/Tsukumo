// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// Errors of the `ResourceBag`.
public enum ResourceBagError: Error, Equatable {
  /// DESIGN.md §5.2 rule 9: no global `.mouseMoved` monitor.
  case mouseMovedMonitorForbidden
  /// `NSEvent` did not install the monitor (missing permission or empty mask).
  case monitorUnavailable
}

/// Container of all the live resources of a module (DESIGN.md §4.2, rule 5).
///
/// Every resource (observer, timer, subscription, monitor, window, status item…)
/// enters here as a cancellation action. `cancelAll()` closes them all: this is what
/// makes the "zero cost when off" verifiable.
@MainActor
public final class ResourceBag {
  public enum Kind: String, Sendable, CaseIterable {
    case observer, timer, subscription, task, monitor, process, connection, statusItem, window, other
  }

  /// Token of a single registered resource.
  public struct Token: Hashable, Sendable {
    fileprivate let id: UInt64
  }

  private struct Entry {
    let kind: Kind
    let cancel: @MainActor () -> Void
  }

  private var entries: [UInt64: Entry] = [:]
  private var order: [UInt64] = []
  private var nextID: UInt64 = 0
  /// After `close()` the bag accepts no more resources: it closes them as soon as they arrive.
  public private(set) var isClosed = false

  public init() {}

  public var count: Int { entries.count }
  public var isEmpty: Bool { entries.isEmpty }

  /// Number of live resources per type (for diagnostics, §3.6).
  public var snapshot: [Kind: Int] {
    entries.values.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
  }

  /// Registers a generic resource through its cancellation action.
  @discardableResult
  public func add(_ kind: Kind, cancel: @escaping @MainActor () -> Void) -> Token {
    nextID += 1
    guard !isClosed else {
      // The module has already been turned off (for example during a `start()` still
      // in progress): the resource must not survive.
      cancel()
      return Token(id: nextID)
    }
    entries[nextID] = Entry(kind: kind, cancel: cancel)
    order.append(nextID)
    return Token(id: nextID)
  }

  /// Closes a single resource. Does nothing if the token is already closed.
  public func cancel(_ token: Token) {
    guard let entry = entries.removeValue(forKey: token.id) else { return }
    order.removeAll { $0 == token.id }
    entry.cancel()
  }

  /// Closes all the resources, in reverse order of registration.
  public func cancelAll() {
    let pending = order.reversed().compactMap { entries[$0] }
    entries.removeAll()
    order.removeAll()
    for entry in pending {
      entry.cancel()
    }
  }

  /// Closes everything for good: every resource added afterwards is
  /// cancelled immediately. Used by the registry when it turns the module off.
  public func close() {
    isClosed = true
    cancelAll()
  }
}

// MARK: - Typed resources

extension ResourceBag {
  /// Minimum leeway allowed: 10% of the interval (DESIGN.md §5.2 rule 1).
  public static func leeway(interval: Duration, requested: Duration?) -> Duration {
    let minimum = interval / 10
    guard let requested else { return minimum }
    return max(requested, minimum)
  }

  /// Repeating timer on the main queue. The tolerance never drops below
  /// 10% of the interval, whatever value is requested.
  @discardableResult
  public func addTimer(
    every interval: Duration,
    tolerance: Duration? = nil,
    handler: @escaping @MainActor () -> Void
  ) -> Token {
    let leeway = Self.leeway(interval: interval, requested: tolerance)
    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(
      deadline: .now() + interval.timeInterval,
      repeating: interval.timeInterval,
      leeway: .nanoseconds(Int(leeway.timeInterval * 1_000_000_000))
    )
    source.setEventHandler {
      MainActor.assumeIsolated(handler)
    }
    source.activate()
    return add(.timer) { source.cancel() }
  }

  /// `NotificationCenter` observer delivered on the main thread.
  @discardableResult
  public func addObserver(
    _ name: Notification.Name,
    object: AnyObject? = nil,
    center: NotificationCenter = .default,
    handler: @escaping @MainActor () -> Void
  ) -> Token {
    nonisolated(unsafe) let observer = center.addObserver(forName: name, object: object, queue: .main) { _ in
      MainActor.assumeIsolated(handler)
    }
    return add(.observer) { center.removeObserver(observer) }
  }

  /// `Task` cancelled when the bag is closed.
  @discardableResult
  public func addTask(_ task: Task<Void, Never>) -> Token {
    add(.task) { task.cancel() }
  }

  /// Subscription to the `EventBus`.
  @discardableResult
  public func addSubscription(_ subscription: EventSubscription) -> Token {
    add(.subscription) { subscription.cancel() }
  }

  /// `true` if the mask is allowed for a global monitor.
  public nonisolated static func isAllowedGlobalMonitorMask(_ mask: NSEvent.EventTypeMask) -> Bool {
    !mask.contains(.mouseMoved)
  }

  /// Global `NSEvent` monitor. Rejects `.mouseMoved` (DESIGN.md §5.2 rule 9).
  @discardableResult
  public func addGlobalMonitor(
    matching mask: NSEvent.EventTypeMask,
    handler: @escaping @MainActor (NSEvent) -> Void
  ) throws(ResourceBagError) -> Token {
    guard Self.isAllowedGlobalMonitorMask(mask) else { throw .mouseMovedMonitorForbidden }
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
      MainActor.assumeIsolated { handler(event) }
    }
    guard let monitor else { throw .monitorUnavailable }
    nonisolated(unsafe) let handle = monitor
    return add(.monitor) { NSEvent.removeMonitor(handle) }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
