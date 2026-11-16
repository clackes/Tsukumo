// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Formatting of Monitor values, shared by popover and Settings.
enum MonitorFormat {
  /// "16 KB/s": decimal units (B, KB, MB, GB), one decimal below 10. Below half a
  /// byte per second it is "0 KB/s", not "Zero kB/s" as the system formatter would write it.
  static func rate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
    var value = max(bytesPerSecond, 0)
    guard value >= 0.5 else { return "0 KB/s" }
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var unit = 0
    while value >= 999.5, unit < units.count - 1 {
      value /= 1000
      unit += 1
    }
    let digits = unit > 0 && value < 9.95 ? 1 : 0
    let number = value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    return "\(number) \(units[unit])"
  }

  static func degrees(_ celsius: Double) -> String {
    Measurement(value: celsius, unit: UnitTemperature.celsius).formatted(
      .measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0)))
    )
  }

  private static let gigabyte = 1_073_741_824.0
  private static let gigabyteStyle = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))

  /// "11.2 / 16 GB": the unit only once, at most one decimal.
  static func bytePair(_ used: UInt64, _ total: UInt64) -> String {
    "\(gigabytes(used)) / \(gigabytes(total)) GB"
  }

  /// "11.2 GB".
  static func bytes(_ value: UInt64) -> String {
    "\(gigabytes(value)) GB"
  }

  private static func gigabytes(_ value: UInt64) -> String {
    (Double(value) / gigabyte).formatted(gigabyteStyle)
  }

  /// Usage percentage 0...100, `nil` if the total is unknown.
  static func usage(used: UInt64, total: UInt64) -> Double? {
    guard total > 0 else { return nil }
    return min(Double(used) / Double(total) * 100, 100)
  }

  /// Seconds since the Mac booted, sleep included (`ProcessInfo.systemUptime` excludes it).
  static func secondsSinceBoot() -> TimeInterval {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
    return Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)))
  }

  /// "3 d 4 h" / "12 min": at most two units, in the user's language.
  static func uptime(_ seconds: TimeInterval, locale: Locale = .current) -> String {
    Duration.seconds(max(seconds, 60)).formatted(
      .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2).locale(locale))
  }

  struct TemperatureEntry: Equatable {
    let label: String
    let symbol: String
    let value: Double
  }

  /// Sensors with a value: label, symbol and degrees. Empty if there is nothing to show.
  static func temperatureEntries(_ reading: TemperatureReading?) -> [TemperatureEntry] {
    guard let reading else { return [] }
    let batteryLabel = String(localized: "Batt.")
    return [
      reading.cpu.map { TemperatureEntry(label: "CPU", symbol: "cpu", value: $0) },
      reading.battery.map { TemperatureEntry(label: batteryLabel, symbol: "battery.100percent", value: $0) },
      reading.storage.map { TemperatureEntry(label: "SSD", symbol: "internaldrive", value: $0) },
    ].compactMap { $0 }
  }

  /// A single compact line: "CPU 34° · Batt. 23° · SSD 29°".
  static func temperatureParts(_ reading: TemperatureReading?) -> [String] {
    temperatureEntries(reading).map { "\($0.label) \(Int($0.value.rounded()))°" }
  }
}
