// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-FileCopyrightText: 2026 fx-xf
// SPDX-License-Identifier: GPL-3.0-only
//
// Adapted from fx-xf/duo (MIT), see THIRD-PARTY-NOTICES.md.

import Foundation
import IOKit
import IOKit.hid

/// Hinge angle read from the MacBook's HID sensor (spike 7).
///
/// Apple silicon MacBooks expose the sensor as an HID device with usage
/// page 0x20 and usage 0x8A ("las"). Feature report 1 contains the angle as a
/// 16-bit little-endian integer, in degrees: 0 closed, ~130 open. On the MacBook
/// Air M4 the value changes at most every ~100 ms and input reports arrive at
/// ~1 Hz: they are only used to notice that the hinge is moving, the active read
/// (`read()`) is done only during movement.
@MainActor
final class LidAngleSensor {
  private let manager: IOHIDManager
  private let device: IOHIDDevice
  private var buffer = [UInt8](repeating: 0, count: 8)
  private let reportBuffer: UnsafeMutablePointer<UInt8>
  private var isInvalidated = false
  private var onAngle: (@MainActor (Double) -> Void)?

  private static let usagePage = 0x20
  private static let usage = 0x8A
  private static let featureReportID: CFIndex = 1

  init?() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Int] = [
      kIOHIDPrimaryUsagePageKey: Self.usagePage,
      kIOHIDPrimaryUsageKey: Self.usage,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let device = Self.firstResponsiveDevice(in: manager)
    else {
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
      return nil
    }
    self.manager = manager
    self.device = device
    // Allocated only once the sensor is found: a failed `init` leaves no memory behind.
    reportBuffer = .allocate(capacity: 64)
  }

  /// Closes everything. Must be called from the module's `stop()`: the bag does not know it.
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    onAngle = nil
    IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, nil, nil)
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    reportBuffer.deallocate()
  }

  /// Current angle in degrees, or `nil` if the sensor does not respond.
  func read() -> Double? {
    var length = buffer.count
    let result = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
      guard let base = pointer.baseAddress else { return kIOReturnError }
      return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, Self.featureReportID, base, &length)
    }
    guard result == kIOReturnSuccess, length >= 3 else { return nil }
    return Self.degrees(high: buffer[2], low: buffer[1])
  }

  /// Kernel events (~1 Hz): no timer. Delivered on the main run loop.
  func observe(_ handler: @escaping @MainActor (Double) -> Void) {
    onAngle = handler
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(
      device, reportBuffer, 64,
      { context, _, _, _, _, report, length in
        guard let context, length >= 3 else { return }
        let low = report[1]
        let high = report[2]
        nonisolated(unsafe) let pointer = context
        MainActor.assumeIsolated {
          let sensor = Unmanaged<LidAngleSensor>.fromOpaque(pointer).takeUnretainedValue()
          if let angle = LidAngleSensor.degrees(high: high, low: low) { sensor.onAngle?(angle) }
        }
      }, context)
  }

  /// The sensor reports a few degrees beyond the mechanical stops.
  nonisolated static func degrees(high: UInt8, low: UInt8) -> Double? {
    let value = Double(Int(low) | (Int(high) << 8))
    return (0...360).contains(value) ? value : nil
  }

  private static func firstResponsiveDevice(in manager: IOHIDManager) -> IOHIDDevice? {
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
    for device in devices {
      guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
      var probe = [UInt8](repeating: 0, count: 8)
      var length = probe.count
      if IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, featureReportID, &probe, &length) == kIOReturnSuccess,
        length >= 3
      {
        return device
      }
      IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    return nil
  }
}
