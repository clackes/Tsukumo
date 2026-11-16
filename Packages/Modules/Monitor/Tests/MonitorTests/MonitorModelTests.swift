// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import Monitor

@MainActor
@Suite("Monitor")
struct MonitorModelTests {
  private func sample(
    at instant: ContinuousClock.Instant, ticks: [UInt32], received: UInt64 = 0, sent: UInt64 = 0
  ) -> SystemMetricsSample {
    networkSample(at: instant, ticks: ticks, interfaces: ["en0": NetworkCounters(received: received, sent: sent)])
  }

  private func networkSample(
    at instant: ContinuousClock.Instant, ticks: [UInt32] = [1, 1, 1, 1], interfaces: [String: NetworkCounters]?
  ) -> SystemMetricsSample {
    SystemMetricsSample(
      timestamp: instant, cpuTicks: ticks, memoryUsedBytes: 4, memoryTotalBytes: 8,
      network: interfaces, diskUsedBytes: 1, diskTotalBytes: 2, battery: nil
    )
  }

  @Test("the first sample has no percentages or speeds yet")
  func firstSampleHasNoRates() {
    let model = MonitorModel()
    model.update(sample(at: .now, ticks: [1, 1, 1, 1]))
    #expect(model.cpuPercent == nil)
    #expect(model.receivedBytesPerSecond == nil)
    #expect(model.memoryUsedBytes == 4)
  }

  @Test("CPU and network are computed from the difference between two samples")
  func ratesFromDeltas() {
    let model = MonitorModel()
    let start = ContinuousClock.now
    model.update(sample(at: start, ticks: [100, 50, 800, 0], received: 1_000, sent: 500))
    model.update(sample(at: start + .seconds(2), ticks: [130, 60, 860, 0], received: 5_000, sent: 1_500))
    #expect(model.cpuPercent == 40)
    #expect(model.receivedBytesPerSecond == 2_000)
    #expect(model.sentBytesPerSecond == 500)
    #expect(model.cpuStatus == "CPU 40%")
  }

  @Test("after a long pause (sleep, lock) the sample doesn't average over hours")
  func longGapIsDiscarded() {
    let model = MonitorModel()
    let start = ContinuousClock.now
    model.update(sample(at: start, ticks: [100, 50, 800, 0], received: 1_000, sent: 500))
    model.update(sample(at: start + .seconds(2), ticks: [130, 60, 860, 0], received: 5_000, sent: 1_500))
    // Three hours later: no average over the period and no stale values on screen.
    let wake = start + .seconds(3 * 3600)
    model.update(sample(at: wake, ticks: [9_000, 60, 900_000, 0], received: 9_000_000, sent: 1_500))
    #expect(model.cpuPercent == nil)
    #expect(model.receivedBytesPerSecond == nil)
    #expect(model.sentBytesPerSecond == nil)
    // The next sample restarts from the wake-up one.
    model.update(sample(at: wake + .seconds(1), ticks: [9_050, 60, 900_050, 0], received: 9_001_000, sent: 1_500))
    #expect(model.cpuPercent == 50)
    #expect(model.receivedBytesPerSecond == 1_000)
  }

  @Test("a failed network read changes neither speed nor baseline")
  func failedNetworkReadKeepsValues() {
    let model = MonitorModel()
    let start = ContinuousClock.now
    model.update(networkSample(at: start, interfaces: ["en0": NetworkCounters(received: 1_000, sent: 0)]))
    model.update(networkSample(at: start + .seconds(1), interfaces: ["en0": NetworkCounters(received: 2_000, sent: 0)]))
    #expect(model.receivedBytesPerSecond == 1_000)
    model.update(networkSample(at: start + .seconds(2), interfaces: nil))
    #expect(model.receivedBytesPerSecond == 1_000)
    // The difference is computed from the last good read, over 2 s.
    model.update(networkSample(at: start + .seconds(3), interfaces: ["en0": NetworkCounters(received: 4_000, sent: 0)]))
    #expect(model.receivedBytesPerSecond == 1_000)
  }

  @Test("new or recreated interfaces don't produce absurd speeds")
  func networkDeltaPerInterface() {
    let old = ["en0": NetworkCounters(received: 1_000, sent: 100), "en1": NetworkCounters(received: 50_000, sent: 50)]
    let new = [
      "en0": NetworkCounters(received: 1_600, sent: 300),
      // Counter restarted from zero: ignored.
      "en1": NetworkCounters(received: 10, sent: 80),
      // New interface: no starting point.
      "en5": NetworkCounters(received: 9_000_000_000, sent: 9_000_000_000),
    ]
    let delta = MonitorModel.networkDelta(from: old, to: new)
    #expect(delta.received == 600)
    #expect(delta.sent == 230)
  }

  @Test("speeds are written in decimal units, without \"Zero kB\"")
  func rateFormatting() {
    let us = Locale(identifier: "en_US")
    #expect(MonitorFormat.rate(0, locale: us) == "0 KB/s")
    #expect(MonitorFormat.rate(0.4, locale: us) == "0 KB/s")
    #expect(MonitorFormat.rate(500, locale: us) == "500 B/s")
    #expect(MonitorFormat.rate(999.7, locale: us) == "1.0 KB/s")
    #expect(MonitorFormat.rate(1_500, locale: us) == "1.5 KB/s")
    #expect(MonitorFormat.rate(16_323, locale: us) == "16 KB/s")
    #expect(MonitorFormat.rate(2_340_000, locale: us) == "2.3 MB/s")
    #expect(MonitorFormat.rate(250_000_000, locale: us) == "250 MB/s")
    #expect(MonitorFormat.rate(-5, locale: us) == "0 KB/s")
    #expect(MonitorFormat.rate(1_500, locale: Locale(identifier: "it_IT")) == "1,5 KB/s")
  }

  @Test("battery state follows the IOKit flags")
  func batteryState() {
    #expect(BatteryPowerState.resolve(isCharging: true, isCharged: false, onACPower: true) == .charging)
    #expect(BatteryPowerState.resolve(isCharging: false, isCharged: true, onACPower: true) == .full)
    // Connected but not charging (80% limit): it is not "on battery".
    #expect(BatteryPowerState.resolve(isCharging: false, isCharged: false, onACPower: true) == .pluggedIn)
    #expect(BatteryPowerState.resolve(isCharging: false, isCharged: false, onACPower: false) == .discharging)
    #expect(BatteryPowerState.resolve(isCharging: nil, isCharged: nil, onACPower: false) == .discharging)
  }

  @Test("after resetBaseline no values remain and the first sample restarts from zero")
  func resetBaseline() {
    let model = MonitorModel()
    let start = ContinuousClock.now
    model.update(sample(at: start, ticks: [100, 50, 800, 0], received: 1_000))
    model.update(sample(at: start + .seconds(1), ticks: [130, 60, 860, 0], received: 2_000))
    model.resetBaseline()
    #expect(model.cpuPercent == nil && model.receivedBytesPerSecond == nil)
    model.update(sample(at: start + .seconds(60), ticks: [900, 60, 900, 0], received: 9_000))
    #expect(model.cpuPercent == nil && model.receivedBytesPerSecond == nil)
  }

  @Test("the item's accessibility label changes only with the displayed title")
  func accessibilityFollowsTitle() {
    let model = MonitorModel()
    let start = ContinuousClock.now
    model.update(sample(at: start, ticks: [1, 1, 1, 1]))
    let before = model.accessibilitySummary
    model.update(sample(at: start + .seconds(1), ticks: [1, 1, 1, 1]))
    #expect(model.accessibilitySummary == before)
    #expect(before.contains(model.cpuStatus))
  }

  @Test("32-bit tick wraparound doesn't skew the percentage")
  func tickWraparound() {
    let model = MonitorModel()
    let start = ContinuousClock.now
    model.update(sample(at: start, ticks: [UInt32.max - 9, 0, 0, 0]))
    model.update(sample(at: start + .seconds(1), ticks: [10, 0, 20, 0]))
    #expect(model.cpuPercent == 50)
  }

  @Test("temperatures: the processor takes the maximum, out-of-range values are discarded")
  func temperatureSummary() {
    let reading = TemperatureReading.summarize(cpu: [31.2, 44.8, -22, 300], battery: [22, 24, -21.9], storage: [])
    #expect(reading.cpu == 44.8)
    #expect(reading.battery == 23)
    #expect(reading.storage == nil)
    #expect(TemperatureReading.summarize(cpu: [], battery: [], storage: []).isEmpty)
  }

  @Test("sensors are grouped by name")
  func temperatureGroups() {
    #expect(TemperatureReader.group(of: "PMU tdie7") == .cpu)
    #expect(TemperatureReader.group(of: "PMU2 tdie10") == .cpu)
    #expect(TemperatureReader.group(of: "gas gauge battery") == .battery)
    #expect(TemperatureReader.group(of: "NAND CH0 temp") == .storage)
    #expect(TemperatureReader.group(of: "PMU tdev3") == nil)
    #expect(TemperatureReader.group(of: "PMU tcal") == nil)
  }

  @Test("where sensors exist, the real reading is plausible")
  func realTemperatures() {
    // On virtualized runners sensors may be missing: the reader is then not created.
    guard let reader = TemperatureReader() else { return }
    let reading = reader.read()
    #expect(!reading.isEmpty)
    for value in [reading.cpu, reading.battery, reading.storage].compactMap(\.self) {
      #expect(TemperatureReading.isPlausible(value))
    }
  }

  @Test("the menu uses short text: unit only once and temperatures on one line")
  func compactMenuTexts() {
    let pair = MonitorFormat.bytePair(12 * 1_073_741_824, 16 * 1_073_741_824)
    #expect(pair == "12 / 16 GB")
    #expect(MonitorFormat.rate(0.4).hasSuffix("/s"))
    #expect(!MonitorFormat.rate(16_323.307901).contains("byte/s"))
    #expect(!MonitorFormat.rate(0).contains("Zero"))
    let parts = MonitorFormat.temperatureParts(TemperatureReading(cpu: 33.6, battery: nil, storage: 29.2))
    #expect(parts == ["CPU 34°", "SSD 29°"])
    #expect(MonitorFormat.temperatureParts(nil).isEmpty)
  }

  @Test("the real reading returns plausible values")
  func realRead() {
    let reading = SystemMetricsReader.read()
    #expect(reading.cpuTicks.count == 4)
    #expect(reading.memoryTotalBytes > 0)
    #expect(reading.memoryUsedBytes > 0 && reading.memoryUsedBytes <= reading.memoryTotalBytes)
    #expect(reading.diskTotalBytes >= reading.diskUsedBytes)
  }
}
