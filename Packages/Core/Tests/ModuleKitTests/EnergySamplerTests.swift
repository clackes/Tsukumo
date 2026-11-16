// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import ModuleKit

@Suite("EnergySampler")
struct EnergySamplerTests {
  private func snapshot(
    at offset: Duration, cpu: UInt64 = 0, energy: UInt64 = 0, idle: UInt64 = 0, interrupts: UInt64 = 0,
    footprint: UInt64 = 0, base: ContinuousClock.Instant
  ) -> EnergySnapshot {
    EnergySnapshot(
      timestamp: base + offset, cpuNanoseconds: cpu, billedEnergyNanojoules: energy, idleWakeups: idle,
      interruptWakeups: interrupts, physicalFootprintBytes: footprint
    )
  }

  @Test("consumption is the difference of the counters divided by the time")
  func rateFromDeltas() throws {
    let base = ContinuousClock.now
    let first = snapshot(at: .zero, cpu: 1_000_000_000, energy: 5_000_000_000, idle: 100, interrupts: 50, base: base)
    let second = snapshot(
      at: .seconds(2), cpu: 1_100_000_000, energy: 5_300_000_000, idle: 110, interrupts: 60,
      footprint: 40_000_000, base: base
    )

    let rate = try #require(EnergyRate(from: first, to: second))
    #expect(abs(rate.cpuPercent - 5) < 0.0001)
    #expect(abs(rate.milliwatts - 150) < 0.0001)
    #expect(abs(rate.wakeupsPerSecond - 10) < 0.0001)
    #expect(rate.physicalFootprintBytes == 40_000_000)
  }

  @Test("zero or reversed interval: no value")
  func invalidInterval() {
    let base = ContinuousClock.now
    let first = snapshot(at: .zero, base: base)
    #expect(EnergyRate(from: first, to: first) == nil)
    #expect(EnergyRate(from: snapshot(at: .seconds(1), base: base), to: first) == nil)
  }

  @Test("counters that go backwards are zero, not a huge number")
  func countersGoingBackwards() throws {
    let base = ContinuousClock.now
    let rate = try #require(
      EnergyRate(
        from: snapshot(at: .zero, cpu: 500, energy: 500, idle: 5, base: base),
        to: snapshot(at: .seconds(1), cpu: 100, energy: 100, idle: 1, base: base)
      )
    )
    #expect(rate.cpuPercent == 0)
    #expect(rate.milliwatts == 0)
    #expect(rate.wakeupsPerSecond == 0)
  }

  @Test("the real reading of our process works and is monotonic")
  func liveSnapshot() throws {
    let first = try #require(EnergySampler.snapshot())
    var sink = 0.0
    for index in 0..<200_000 { sink += Double(index).squareRoot() }
    #expect(sink > 0)
    let second = try #require(EnergySampler.snapshot())

    #expect(first.physicalFootprintBytes > 0)
    #expect(second.cpuNanoseconds >= first.cpuNanoseconds)
    #expect(second.billedEnergyNanojoules >= first.billedEnergyNanojoules)
    #expect(EnergySampler.snapshot(pid: -1) == nil)
  }
}
