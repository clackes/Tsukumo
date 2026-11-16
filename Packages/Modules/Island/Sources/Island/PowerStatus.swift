// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import IOKit.ps
import ModuleKit

/// Power state read from IOKit, without polling.
struct PowerStatus: Equatable, Sendable {
  var percent: Int?
  var isCharging = false
  var isPluggedIn = false

  /// Battery symbol for the current level.
  var symbol: String {
    if isCharging || (isPluggedIn && percent != nil) { return "battery.100percent.bolt" }
    guard let percent else { return "powerplug" }
    switch percent {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
  }

  /// Interprets a source's description (`IOPSGetPowerSourceDescription`).
  static func parse(_ description: [String: Any]) -> PowerStatus? {
    guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { return nil }
    var status = PowerStatus()
    if let current = description[kIOPSCurrentCapacityKey] as? Int,
      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
    {
      status.percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
    }
    status.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
    status.isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    return status
  }

  /// Instant reading. On Macs without a battery it always reads as plugged in.
  static func current() -> PowerStatus {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
        let status = parse(description)
      else { continue }
      return status
    }
    return PowerStatus(percent: nil, isCharging: false, isPluggedIn: true)
  }
}

/// Notifies power changes with a run loop source: zero wakeups at rest.
@MainActor
enum PowerObserver {
  private final class Box: Sendable {
    let handler: @MainActor @Sendable () -> Void
    init(handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }
  }

  /// Registers the source in the `ResourceBag`; `false` if IOKit does not create it.
  @discardableResult
  static func install(in resources: ResourceBag, handler: @escaping @MainActor @Sendable () -> Void) -> Bool {
    let box = Unmanaged.passRetained(Box(handler: handler))
    let callback: IOPowerSourceCallbackType = { context in
      guard let context else { return }
      let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
      MainActor.assumeIsolated { box.handler() }
    }
    guard let source = IOPSNotificationCreateRunLoopSource(callback, box.toOpaque())?.takeRetainedValue() else {
      box.release()
      return false
    }
    // `.commonModes`: the source must fire also during menu and window tracking.
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    resources.add(.observer) {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      box.release()
    }
    return true
  }
}
