// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import IOKit

/// Temperatures in degrees Celsius; `nil` where the Mac has no sensor.
public struct TemperatureReading: Sendable, Equatable {
  /// The hottest point of the processor.
  public var cpu: Double?
  public var battery: Double?
  public var storage: Double?

  public init(cpu: Double? = nil, battery: Double? = nil, storage: Double? = nil) {
    self.cpu = cpu
    self.battery = battery
    self.storage = storage
  }

  public var isEmpty: Bool { cpu == nil && battery == nil && storage == nil }

  /// Some sensors answer with out-of-range values (for example −22 °C): they are discarded.
  static func isPlausible(_ value: Double) -> Bool { value > 0 && value < 130 }

  /// Processor: the hottest sensor. Battery and disk: the average of their sensors.
  static func summarize(cpu: [Double], battery: [Double], storage: [Double]) -> TemperatureReading {
    func average(_ values: [Double]) -> Double? {
      let valid = values.filter(isPlausible)
      return valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count)
    }
    return TemperatureReading(
      cpu: cpu.filter(isPlausible).max(),
      battery: average(battery),
      storage: average(storage)
    )
  }
}

/// Apple Silicon thermal sensors via IOKit's HID event client.
///
/// The functions are not in the public headers: they are resolved with `dlsym` and, if
/// one is missing, the reader is not created and Monitor shows the rest. Reading all
/// the processor sensors costs about 17 ms on M-series: for this reason they are
/// read only while the menu or Settings are visible.
@MainActor
final class TemperatureReader {
  private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
  private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
  private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
  private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
  private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
  private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

  /// `kIOHIDEventTypeTemperature` and its value field.
  private static let temperatureType: Int64 = 15
  private static let temperatureField: Int32 = 15 << 16
  /// HID page and usage of Apple temperature sensors.
  private static let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]

  private let copyEvent: CopyEvent
  private let getFloat: GetFloat
  private let client: AnyObject
  private let cpu: [AnyObject]
  private let battery: [AnyObject]
  private let storage: [AnyObject]

  /// `nil` if the private functions do not exist or the Mac exposes no sensors.
  init?() {
    guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
    func symbol<Function>(_ name: String, as type: Function.Type) -> Function? {
      dlsym(handle, name).map { unsafeBitCast($0, to: type) }
    }
    guard
      let create = symbol("IOHIDEventSystemClientCreate", as: Create.self),
      let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
      let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
      let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
      let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
      let getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloat.self),
      let client = create(kCFAllocatorDefault)?.takeRetainedValue()
    else { return nil }
    _ = setMatching(client, Self.matching as CFDictionary)

    var cpu: [AnyObject] = []
    var battery: [AnyObject] = []
    var storage: [AnyObject] = []
    for service in copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? [] {
      let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
      switch Self.group(of: name) {
      case .cpu: cpu.append(service)
      case .battery: battery.append(service)
      case .storage: storage.append(service)
      case nil: break
      }
    }
    guard !cpu.isEmpty || !battery.isEmpty || !storage.isEmpty else { return nil }
    self.client = client
    self.copyEvent = copyEvent
    self.getFloat = getFloat
    self.cpu = cpu
    self.battery = battery
    self.storage = storage
  }

  enum Group: Equatable { case cpu, battery, storage }

  /// Sensor name → group. "tdie" are the sensors on the processor die.
  static func group(of name: String) -> Group? {
    if name.contains("tdie") { return .cpu }
    if name.contains("battery") { return .battery }
    if name.hasPrefix("NAND") { return .storage }
    return nil
  }

  func read() -> TemperatureReading {
    TemperatureReading.summarize(cpu: values(of: cpu), battery: values(of: battery), storage: values(of: storage))
  }

  private func values(of services: [AnyObject]) -> [Double] {
    services.compactMap { service in
      guard let event = copyEvent(service, Self.temperatureType, 0, 0)?.takeRetainedValue() else { return nil }
      return getFloat(event, Self.temperatureField)
    }
  }
}
