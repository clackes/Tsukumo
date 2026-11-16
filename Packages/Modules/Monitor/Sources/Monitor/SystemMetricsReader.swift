// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import IOKit.ps

public enum BatteryPowerState: String, Sendable, Equatable {
  case charging
  case discharging
  case full
  /// Power adapter connected but battery not charging (charge limit, maintenance).
  case pluggedIn

  /// State from the IOKit flags (`kIOPSIsChargingKey`, `kIOPSIsChargedKey`) and the power source.
  static func resolve(isCharging: Bool?, isCharged: Bool?, onACPower: Bool) -> BatteryPowerState {
    if isCharged == true { return .full }
    if isCharging == true { return .charging }
    return onACPower ? .pluggedIn : .discharging
  }
}

public struct BatteryReading: Sendable, Equatable {
  public let percentage: Int
  public let state: BatteryPowerState

  public init(percentage: Int, state: BatteryPowerState) {
    self.percentage = percentage
    self.state = state
  }
}

/// Cumulative bytes of a network interface.
public struct NetworkCounters: Sendable, Equatable {
  public let received: UInt64
  public let sent: UInt64

  public init(received: UInt64, sent: UInt64) {
    self.received = received
    self.sent = sent
  }
}

/// Cumulative counters and system values read from public APIs.
public struct SystemMetricsSample: Sendable, Equatable {
  public let timestamp: ContinuousClock.Instant
  public let cpuTicks: [UInt32]
  public let memoryUsedBytes: UInt64
  public let memoryTotalBytes: UInt64
  /// Counters per physical interface; `nil` if the read failed (the previous value is kept).
  public let network: [String: NetworkCounters]?
  public let diskUsedBytes: UInt64
  public let diskTotalBytes: UInt64
  public let battery: BatteryReading?

  public init(
    timestamp: ContinuousClock.Instant, cpuTicks: [UInt32], memoryUsedBytes: UInt64, memoryTotalBytes: UInt64,
    network: [String: NetworkCounters]?, diskUsedBytes: UInt64, diskTotalBytes: UInt64,
    battery: BatteryReading?
  ) {
    self.timestamp = timestamp
    self.cpuTicks = cpuTicks
    self.memoryUsedBytes = memoryUsedBytes
    self.memoryTotalBytes = memoryTotalBytes
    self.network = network
    self.diskUsedBytes = diskUsedBytes
    self.diskTotalBytes = diskTotalBytes
    self.battery = battery
  }
}

/// Reads kernel counters and public statistics. No subprocess or
/// access to private sensors: temperatures live in `TemperatureReader`.
public enum SystemMetricsReader {
  /// `mach_host_self()` returns a new reference to the port every time:
  /// we take it once instead of accumulating one per sample.
  private static let host = mach_host_self()

  public static func read() -> SystemMetricsSample {
    let cpuTicks = readCPUTicks()
    let memory = readMemory()
    let network = readNetworkCounters()
    let disk = readDisk()
    return SystemMetricsSample(
      timestamp: .now,
      cpuTicks: cpuTicks,
      memoryUsedBytes: memory.used,
      memoryTotalBytes: memory.total,
      network: network,
      diskUsedBytes: disk.used,
      diskTotalBytes: disk.total,
      battery: readBattery()
    )
  }

  private static func readCPUTicks() -> [UInt32] {
    var info = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return [] }
    return withUnsafeBytes(of: info.cpu_ticks) { Array($0.bindMemory(to: UInt32.self)) }
  }

  private static func readMemory() -> (used: UInt64, total: UInt64) {
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (0, ProcessInfo.processInfo.physicalMemory) }
    let pageSize = UInt64(getpagesize())
    // Like Activity Monitor: app memory (anonymous non-purgeable) + wired + compressed.
    let internalPages = UInt64(info.internal_page_count)
    let purgeable = UInt64(info.purgeable_count)
    let appPages = internalPages >= purgeable ? internalPages - purgeable : 0
    let usedPages = appPages + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
    return (usedPages * pageSize, ProcessInfo.processInfo.physicalMemory)
  }

  /// 64-bit counters from `NET_RT_IFLIST2`: the 32-bit ones from `getifaddrs`
  /// wrap around every 4 GB. We count only physical interfaces (`en*`,
  /// `pdp_ip*`), so VPN and bridge traffic is not summed twice.
  /// Counters stay per interface: an interface that appears or disappears
  /// must not produce an absurd speed. `nil` if the kernel does not answer.
  private static func readNetworkCounters() -> [String: NetworkCounters]? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    // The table may grow between measuring and reading (ENOMEM): retry with a margin.
    for _ in 0..<4 {
      var length = 0
      guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
      length += length / 4 + 1024
      var buffer = [UInt8](repeating: 0, count: length)
      if sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 {
        return parseInterfaces(buffer, length: length)
      }
      guard errno == ENOMEM else { return nil }
    }
    return nil
  }

  private static func parseInterfaces(_ buffer: [UInt8], length: Int) -> [String: NetworkCounters] {
    var result: [String: NetworkCounters] = [:]
    buffer.withUnsafeBytes { raw in
      var offset = 0
      while offset + MemoryLayout<if_msghdr>.size <= length {
        let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
        let messageLength = Int(header.ifm_msglen)
        guard messageLength > 0 else { break }
        defer { offset += messageLength }
        guard Int32(header.ifm_type) == RTM_IFINFO2,
          offset + MemoryLayout<if_msghdr2>.size <= length
        else { continue }
        let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(info.ifm_index), &name) != nil else { continue }
        let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let interface = String(bytes: bytes, encoding: .utf8) else { continue }
        guard interface.hasPrefix("en") || interface.hasPrefix("pdp_ip") else { continue }
        result[interface] = NetworkCounters(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
      }
    }
    return result
  }

  /// Used space as Finder shows it: the "available" space includes
  /// the reclaimable one (cache, purgeable), which `statfs` does not count. The query is
  /// more expensive than a syscall and the value changes slowly: it is re-read at most
  /// once a minute.
  private static func readDisk() -> (used: UInt64, total: UInt64) {
    diskCache.value(maxAge: .seconds(60)) {
      let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
      if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
        let total = values.volumeTotalCapacity, total > 0,
        let available = values.volumeAvailableCapacityForImportantUsage
      {
        let totalBytes = UInt64(total)
        let free = min(UInt64(max(available, 0)), totalBytes)
        return (totalBytes - free, totalBytes)
      }
      var info = statfs()
      guard statfs("/", &info) == 0 else { return (0, 0) }
      let blockSize = UInt64(info.f_bsize)
      let total = UInt64(info.f_blocks) * blockSize
      let available = UInt64(info.f_bavail) * blockSize
      return (total >= available ? total - available : 0, total)
    }
  }

  private static let diskCache = DiskCache()

  private static func readBattery() -> BatteryReading? {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
    for source in sources {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
        description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType,
        let current = description[kIOPSCurrentCapacityKey as String] as? Int,
        let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
        maximum > 0
      else { continue }
      let onAC = description[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue
      let state = BatteryPowerState.resolve(
        isCharging: description[kIOPSIsChargingKey as String] as? Bool,
        isCharged: description[kIOPSIsChargedKey as String] as? Bool,
        onACPower: onAC
      )
      return BatteryReading(percentage: current * 100 / maximum, state: state)
    }
    return nil
  }
}

/// Short-term memory of an expensive read.
private final class DiskCache: @unchecked Sendable {
  private let lock = NSLock()
  private var cached: (used: UInt64, total: UInt64)?
  private var readAt: ContinuousClock.Instant?

  func value(maxAge: Duration, read: () -> (used: UInt64, total: UInt64)) -> (used: UInt64, total: UInt64) {
    lock.withLock {
      let now = ContinuousClock.now
      if let cached, let readAt, now - readAt < maxAge { return cached }
      let fresh = read()
      cached = fresh
      readAt = now
      return fresh
    }
  }
}
