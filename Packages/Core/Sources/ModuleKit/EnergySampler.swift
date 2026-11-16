// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// Cumulative process counters read from `proc_pid_rusage` (DESIGN.md §3.6).
public struct EnergySnapshot: Sendable, Equatable {
  public var timestamp: ContinuousClock.Instant
  /// User + system CPU time, in nanoseconds.
  public var cpuNanoseconds: UInt64
  /// Energy billed to the process, in nanojoules.
  public var billedEnergyNanojoules: UInt64
  public var idleWakeups: UInt64
  public var interruptWakeups: UInt64
  /// Current physical footprint, in bytes.
  public var physicalFootprintBytes: UInt64

  public init(
    timestamp: ContinuousClock.Instant,
    cpuNanoseconds: UInt64,
    billedEnergyNanojoules: UInt64,
    idleWakeups: UInt64,
    interruptWakeups: UInt64,
    physicalFootprintBytes: UInt64
  ) {
    self.timestamp = timestamp
    self.cpuNanoseconds = cpuNanoseconds
    self.billedEnergyNanojoules = billedEnergyNanojoules
    self.idleWakeups = idleWakeups
    self.interruptWakeups = interruptWakeups
    self.physicalFootprintBytes = physicalFootprintBytes
  }
}

/// Consumption over the interval between two readings.
public struct EnergyRate: Sendable, Equatable {
  /// Percentage of one core (100 = one full core).
  public let cpuPercent: Double
  /// Average power in milliwatts.
  public let milliwatts: Double
  public let wakeupsPerSecond: Double
  public let physicalFootprintBytes: UInt64

  /// `nil` if the interval is zero or the readings are in reverse order.
  public init?(from previous: EnergySnapshot, to current: EnergySnapshot) {
    let elapsed = current.timestamp - previous.timestamp
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    guard seconds > 0 else { return nil }

    // The counters are monotonic; if they go backwards (should not happen) the value is zero.
    func delta(_ new: UInt64, _ old: UInt64) -> Double { new >= old ? Double(new - old) : 0 }

    cpuPercent = delta(current.cpuNanoseconds, previous.cpuNanoseconds) / (seconds * 1e9) * 100
    milliwatts = delta(current.billedEnergyNanojoules, previous.billedEnergyNanojoules) / 1e6 / seconds
    wakeupsPerSecond =
      (delta(current.idleWakeups, previous.idleWakeups)
        + delta(current.interruptWakeups, previous.interruptWakeups)) / seconds
    physicalFootprintBytes = current.physicalFootprintBytes
  }
}

/// Reader of our own process's counters. It is a single system call
/// per reading, with no subprocess; whoever uses it samples only while the Energy
/// panel is visible.
public enum EnergySampler {
  public static func snapshot(pid: pid_t = getpid()) -> EnergySnapshot? {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
      }
    }
    guard result == 0 else { return nil }

    // ri_user_time and ri_system_time are in mach units: convert them to nanoseconds.
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let machTicks = info.ri_user_time &+ info.ri_system_time
    let cpuNanoseconds = machTicks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))

    return EnergySnapshot(
      timestamp: .now,
      cpuNanoseconds: cpuNanoseconds,
      billedEnergyNanojoules: info.ri_billed_energy,
      idleWakeups: info.ri_pkg_idle_wkups,
      interruptWakeups: info.ri_interrupt_wkups,
      physicalFootprintBytes: info.ri_phys_footprint
    )
  }
}
