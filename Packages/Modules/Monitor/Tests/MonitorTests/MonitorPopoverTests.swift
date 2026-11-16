// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import Monitor

@Suite("Monitor popover")
struct MonitorPopoverTests {
  @Test("the ring buffer keeps the latest samples and drops the oldest")
  func ringBufferKeepsLatest() {
    var buffer = RingBuffer<Int>(capacity: 3)
    #expect(buffer.isEmpty)
    for value in 1...5 { buffer.append(value) }
    #expect(buffer.elements == [3, 4, 5])
    #expect(buffer.count == 3)
    #expect(buffer.last == 5)
    buffer.removeAll()
    #expect(buffer.isEmpty)
    buffer.append(9)
    #expect(buffer.elements == [9])
  }

  @Test("color thresholds: green below 60, yellow below 85, red above")
  func usageThresholds() {
    #expect(GaugeLevel(usage: 0) == .normal)
    #expect(GaugeLevel(usage: 59.9) == .normal)
    #expect(GaugeLevel(usage: 60) == .warning)
    #expect(GaugeLevel(usage: 84.9) == .warning)
    #expect(GaugeLevel(usage: 85) == .critical)
    #expect(GaugeLevel(usage: 100) == .critical)
    #expect(GaugeLevel.normal.color == .green)
    #expect(GaugeLevel.warning.color == .yellow)
    #expect(GaugeLevel.critical.color == .red)
  }

  @Test("battery: inverted, and on the power adapter it is never an alarm")
  func batteryThresholds() {
    #expect(GaugeLevel(batteryPercent: 100) == .normal)
    #expect(GaugeLevel(batteryPercent: 40) == .normal)
    #expect(GaugeLevel(batteryPercent: 39) == .warning)
    #expect(GaugeLevel(batteryPercent: 15) == .warning)
    #expect(GaugeLevel(batteryPercent: 14) == .critical)
    #expect(GaugeLevel(batteryPercent: 5, isPluggedIn: true) == .normal)
  }

  @MainActor
  @Test("the model fills the history only when samples arrive, up to 60")
  func modelHistoryIsBounded() {
    let model = MonitorModel()
    let start = ContinuousClock.now
    func sample(_ second: Int) -> SystemMetricsSample {
      SystemMetricsSample(
        timestamp: start + .seconds(second), cpuTicks: [UInt32(second * 50), 0, UInt32(second * 50), 0],
        memoryUsedBytes: 4, memoryTotalBytes: 8,
        network: ["en0": NetworkCounters(received: UInt64(second * 1_000), sent: 0)],
        diskUsedBytes: 1, diskTotalBytes: 2, battery: nil)
    }
    model.update(sample(0))
    #expect(model.cpuHistory.isEmpty)
    #expect(model.networkHistory.isEmpty)
    for second in 1...80 { model.update(sample(second)) }
    #expect(model.cpuHistory.count == MonitorModel.historyCapacity)
    #expect(model.networkHistory.count == MonitorModel.historyCapacity)
    #expect(model.cpuHistory.last == 50)
    #expect(model.networkHistory.last == NetworkRate(received: 1_000, sent: 0))
    model.resetBaseline()
    #expect(model.cpuHistory.isEmpty)
  }

  @Test("uso in percentuale e durata dall'avvio")
  func formatting() {
    #expect(MonitorFormat.usage(used: 1, total: 0) == nil)
    #expect(MonitorFormat.usage(used: 1, total: 4) == 25)
    #expect(MonitorFormat.usage(used: 9, total: 4) == 100)
    let us = Locale(identifier: "en_US")
    #expect(MonitorFormat.uptime(3 * 86_400 + 4 * 3_600 + 12, locale: us) == "3d 4h")
    #expect(MonitorFormat.temperatureEntries(TemperatureReading(cpu: 40)).map(\.label) == ["CPU"])
  }

  /// Renders the content (without glass) on a dark background into `TSUKUMO_MONITOR_OUT`: to look at it by eye.
  @MainActor
  @Test("popover rendering to file (only with TSUKUMO_MONITOR_OUT)")
  func renderToPNG() throws {
    guard let out = ProcessInfo.processInfo.environment["TSUKUMO_MONITOR_OUT"] else { return }
    let model = MonitorModel()
    let start = ContinuousClock.now
    for second in 0...60 {
      let busy = UInt32(second * 40 + (second % 7) * 30)
      model.update(
        SystemMetricsSample(
          timestamp: start + .seconds(second), cpuTicks: [busy, 0, UInt32(second * 100), 0],
          memoryUsedBytes: 11_600_000_000, memoryTotalBytes: 17_179_869_184,
          network: ["en0": NetworkCounters(received: UInt64(second * second * 9_000), sent: UInt64(second * 3_000))],
          diskUsedBytes: 700_000_000_000, diskTotalBytes: 994_000_000_000,
          battery: BatteryReading(percentage: 87, state: .charging)))
    }
    model.temperature = TemperatureReading(cpu: 46, battery: 31, storage: 38)
    if let probe = ProcessInfo.processInfo.environment["TSUKUMO_MONITOR_PROBE"], let screen = NSScreen.main {
      // Real window: glass is only visible composed by the system.
      let host = NSHostingView(rootView: StatusPopoverChrome(content: MonitorPopoverView(model: model)))
      let size = host.fittingSize
      let panel = NSPanel(
        contentRect: CGRect(
          x: screen.frame.maxX - size.width - 40, y: screen.frame.maxY - size.height - 40,
          width: size.width, height: size.height),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.level = .screenSaver
      panel.contentView = host
      panel.orderFrontRegardless()
      RunLoop.main.run(until: Date().addingTimeInterval(0.9))
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = ["-x", "-l", String(panel.windowNumber), probe]
      try capture.run()
      capture.waitUntilExit()
      panel.close()
    }
    let view = MonitorPopoverView(model: model)
      .padding(12)
      .frame(width: 320)
      .background(Color(white: 0.16))
      .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: out))
  }
}
