// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// Shared frequency: 5 s with popovers closed, 1 s with at least one visible surface.
public enum SamplingCadence: Sendable {
  case background
  case visible

  fileprivate var interval: Duration {
    switch self {
    case .background: .seconds(5)
    case .visible: .seconds(1)
    }
  }
}

/// A single sampling source for Monitor and Battery. The timer exists
/// only with active subscribers and stops when the screen is off, on lock or in Low Power.
@MainActor
public final class SharedSampler {
  public typealias SampleHandler = @MainActor () -> Void

  private struct Subscriber {
    let cadence: SamplingCadence
    let handler: SampleHandler
  }

  private var subscribers: [UInt64: Subscriber] = [:]
  private var nextID: UInt64 = 0
  private let resources = ResourceBag()
  private var timer: ResourceBag.Token?
  private var timerInterval: Duration?
  private var observers: [ResourceBag.Token] = []
  private var screenIsAwake = true
  private var isLocked = false
  private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

  public init() {}

  public var subscriberCount: Int { subscribers.count }
  public var isSampling: Bool { timer != nil }

  /// Subscribes a source; cancelling the token recomputes the shared timer.
  @discardableResult
  public func subscribe(
    cadence: SamplingCadence = .background,
    handler: @escaping SampleHandler
  ) -> SharedSampleSubscription {
    nextID += 1
    let id = nextID
    subscribers[id] = Subscriber(cadence: cadence, handler: handler)
    if subscribers.count == 1 { installPowerObservers() }
    reconcileTimer()
    return SharedSampleSubscription(id: id, sampler: self)
  }

  /// Switches between slow polling and visible frequency without adding a timer.
  public func setCadence(_ cadence: SamplingCadence, for subscriptionID: UInt64) {
    guard let subscriber = subscribers[subscriptionID] else { return }
    subscribers[subscriptionID] = Subscriber(cadence: cadence, handler: subscriber.handler)
    reconcileTimer()
  }

  /// Simplified hook for a module: returns the subscription token.
  @discardableResult
  public func addSubscription(
    to bag: ResourceBag,
    cadence: SamplingCadence = .background,
    handler: @escaping SampleHandler
  ) -> SharedSampleSubscription {
    let subscription = subscribe(cadence: cadence, handler: handler)
    bag.addSharedSampleSubscription(subscription)
    return subscription
  }

  private func unsubscribe(_ id: UInt64) {
    subscribers[id] = nil
    if subscribers.isEmpty {
      observers.forEach(resources.cancel)
      observers.removeAll()
    }
    reconcileTimer()
  }

  private func installPowerObservers() {
    // Without subscribers we observe nothing, so the state may be stale:
    // restart from the current values (whoever subscribes does so with the screen on and unlocked).
    screenIsAwake = true
    isLocked = false
    lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    let workspace = NSWorkspace.shared.notificationCenter
    observers.append(
      resources.addObserver(NSWorkspace.screensDidSleepNotification, center: workspace) { [weak self] in
        self?.screenIsAwake = false
        self?.reconcileTimer()
      })
    observers.append(
      resources.addObserver(NSWorkspace.screensDidWakeNotification, center: workspace) { [weak self] in
        self?.screenIsAwake = true
        self?.reconcileTimer()
      })
    let distributed = DistributedNotificationCenter.default()
    observers.append(
      resources.addObserver(
        Notification.Name("com.apple.screenIsLocked"), center: distributed
      ) { [weak self] in
        self?.isLocked = true
        self?.reconcileTimer()
      })
    observers.append(
      resources.addObserver(
        Notification.Name("com.apple.screenIsUnlocked"), center: distributed
      ) { [weak self] in
        self?.isLocked = false
        self?.reconcileTimer()
      })
    observers.append(
      resources.addObserver(Notification.Name("NSProcessInfoPowerStateDidChangeNotification")) { [weak self] in
        self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        self?.reconcileTimer()
      })
  }

  private func reconcileTimer() {
    let shouldRun = !subscribers.isEmpty && screenIsAwake && !isLocked
    guard shouldRun else {
      if let timer { resources.cancel(timer); self.timer = nil }
      timerInterval = nil
      return
    }

    let interval: Duration
    if lowPower {
      interval = .seconds(10)
    } else if subscribers.values.allSatisfy({ $0.cadence == .background }) {
      interval = .seconds(5)
    } else {
      interval = .seconds(1)
    }
    // Same interval: the timer stays as it is, without losing phase.
    guard timer == nil || timerInterval != interval else { return }
    if let timer { resources.cancel(timer); self.timer = nil }
    timerInterval = interval
    timer = resources.addTimer(every: interval, tolerance: interval / 4) { [weak self] in
      guard let self, self.screenIsAwake, !self.isLocked else { return }
      for subscriber in self.subscribers.values { subscriber.handler() }
    }
  }
}

/// Adjustable subscription to adapt the frequency when a view appears or disappears.
@MainActor
public final class SharedSampleSubscription {
  public let id: UInt64
  private weak var sampler: SharedSampler?

  fileprivate init(id: UInt64, sampler: SharedSampler) {
    self.id = id
    self.sampler = sampler
  }

  public func setCadence(_ cadence: SamplingCadence) {
    sampler?.setCadence(cadence, for: id)
  }

  public func cancel() {
    sampler?.cancel(id)
    sampler = nil
  }
}

extension SharedSampler {
  fileprivate func cancel(_ id: UInt64) { unsubscribe(id) }
}

extension ResourceBag {
  @discardableResult
  public func addSharedSampleSubscription(_ subscription: SharedSampleSubscription) -> Token {
    add(.subscription) { subscription.cancel() }
  }
}
