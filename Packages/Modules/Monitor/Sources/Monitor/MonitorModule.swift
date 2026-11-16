// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import Observation
import SwiftUI

@MainActor
@Observable
public final class MonitorModel {
  public private(set) var cpuPercent: Double?
  public private(set) var memoryUsedBytes: UInt64 = 0
  public private(set) var memoryTotalBytes: UInt64 = 0
  public private(set) var receivedBytesPerSecond: Double?
  public private(set) var sentBytesPerSecond: Double?
  public private(set) var diskUsedBytes: UInt64 = 0
  public private(set) var diskTotalBytes: UInt64 = 0
  public private(set) var battery: BatteryReading?
  /// Read only while the popover or Settings are visible.
  public internal(set) var temperature: TemperatureReading?
  /// Latest samples for the popover sparklines: they fill only when
  /// a sample arrives, without timers.
  static let historyCapacity = 60
  private(set) var cpuHistory = RingBuffer<Double>(capacity: MonitorModel.historyCapacity)
  private(set) var networkHistory = RingBuffer<NetworkRate>(capacity: MonitorModel.historyCapacity)

  private var previous: SystemMetricsSample?
  private var previousNetwork: (at: ContinuousClock.Instant, counters: [String: NetworkCounters])?
  /// Three times the sampler's slowest cadence (10 s in Low Power Mode).
  static let longestInterval: Double = 30

  /// After a pause (hidden item, user switch) it restarts from zero: no averages over the gap.
  func resetBaseline() {
    previous = nil
    previousNetwork = nil
    cpuPercent = nil
    receivedBytesPerSecond = nil
    sentBytesPerSecond = nil
    cpuHistory.removeAll()
    networkHistory.removeAll()
  }

  func update(_ sample: SystemMetricsSample) {
    if let previous {
      let seconds = (sample.timestamp - previous.timestamp).timeInterval
      if seconds > Self.longestInterval {
        // After sleep or screen lock the interval spans hours: the average would say
        // nothing. The sample is discarded, we restart from this one and the old values,
        // now false, do not stay on screen.
        cpuPercent = nil
      } else if seconds > 0 {
        if previous.cpuTicks.count == sample.cpuTicks.count, sample.cpuTicks.count >= 4 {
          // Ticks are 32-bit counters that wrap around: the difference is modular.
          let deltas = zip(previous.cpuTicks, sample.cpuTicks).map { UInt64($1 &- $0) }
          let total = deltas.reduce(0, +)
          let idle = deltas[2]
          cpuPercent = total > 0 ? Double(total - min(idle, total)) / Double(total) * 100 : nil
          if let cpuPercent { cpuHistory.append(cpuPercent) }
        }
      }
    }
    updateNetwork(sample)
    memoryUsedBytes = sample.memoryUsedBytes
    memoryTotalBytes = sample.memoryTotalBytes
    diskUsedBytes = sample.diskUsedBytes
    diskTotalBytes = sample.diskTotalBytes
    battery = sample.battery
    previous = sample
  }

  /// Network speed from per-interface counters. A failed read changes
  /// neither the values nor the reference.
  private func updateNetwork(_ sample: SystemMetricsSample) {
    guard let counters = sample.network else { return }
    defer { previousNetwork = (sample.timestamp, counters) }
    guard let previousNetwork else { return }
    let seconds = (sample.timestamp - previousNetwork.at).timeInterval
    if seconds > Self.longestInterval {
      receivedBytesPerSecond = nil
      sentBytesPerSecond = nil
    } else if seconds > 0 {
      let delta = Self.networkDelta(from: previousNetwork.counters, to: counters)
      receivedBytesPerSecond = Double(delta.received) / seconds
      sentBytesPerSecond = Double(delta.sent) / seconds
      networkHistory.append(NetworkRate(received: Double(delta.received) / seconds, sent: Double(delta.sent) / seconds))
    }
  }

  /// Bytes exchanged between two reads, interface by interface: new
  /// interfaces are ignored (there is no starting point) and a counter that drops
  /// (interface recreated) produces neither a negative nor a huge difference.
  static func networkDelta(
    from old: [String: NetworkCounters], to new: [String: NetworkCounters]
  ) -> (received: UInt64, sent: UInt64) {
    var received: UInt64 = 0
    var sent: UInt64 = 0
    for (name, now) in new {
      guard let before = old[name] else { continue }
      if now.received >= before.received { received += now.received - before.received }
      if now.sent >= before.sent { sent += now.sent - before.sent }
    }
    return (received, sent)
  }

  var cpuStatus: String {
    guard let cpuPercent else { return String(localized: "CPU —") }
    return String(localized: "CPU \(Int(cpuPercent.rounded()))%")
  }

  /// Only what the item shows: if it included memory, which changes at every
  /// sample, the item would be redrawn even with the title unchanged (§5.2 rule 11).
  var accessibilitySummary: String {
    String(localized: "Monitor, \(cpuStatus)")
  }
}

/// Monitor uses a single status item and a single SharedSampler. The sampler
/// subscribes only during start(); the popover goes to 1 s while open.
@MainActor
public final class MonitorModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "monitor",
    nameKey: "Monitor",
    symbol: "chart.bar.fill",
    tint: .green,
    energyClass: .low
  )

  public private(set) var model: MonitorModel?
  private let context: ModuleContext
  private var sampling: SharedSampleSubscription?
  private var samplingToken: ResourceBag.Token?
  private var visibilityObservation: NSKeyValueObservation?
  private var sessionIsActive = true
  private var lastSampleInstant: ContinuousClock.Instant?
  private var statusItem: StatusItemSurface?
  private var popover: StatusPopover?
  private var temperatures: TemperatureReader?
  private var lastTemperatureRead: ContinuousClock.Instant?
  private var isSettingsVisible = false

  /// Sensors are costly: no more than one read every three seconds, and only while visible.
  static let temperatureInterval: Duration = .seconds(3)

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    let model = MonitorModel()
    self.model = model

    statusItem = context.surfaces.makeStatusItem(
      autosaveName: "tsukumo.monitor",
      content: StatusItemContent(symbol: Self.descriptor.symbol, accessibilityLabel: String(localized: "Monitor")),
      moduleID: context.moduleID,
      in: context.resources
    )
    // Fixed-width digits: the title does not make the menu bar jiggle at every sample.
    statusItem?.item?.button?.font = .monospacedDigitSystemFont(
      ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    if let button = statusItem?.item?.button {
      let popover = StatusPopover(button: button) { [weak self] in
        AnyView(MonitorPopoverView(model: model) { self?.popover?.close() })
      }
      popover.onVisibilityChange = { [weak self] _ in
        self?.visibilityChanged()
        // The popover must not show a stale value until the next tick.
        self?.sampleIfStale()
      }
      self.popover = popover
      context.resources.add(.window) { popover.invalidate() }
    }

    // Sampling only with the item visible and the session active (fast user switch).
    visibilityObservation = statusItem?.item?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in self?.updateSampling() }
    }
    let workspace = NSWorkspace.shared.notificationCenter
    context.resources.addObserver(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { [weak self] in
      self?.sessionIsActive = false
      self?.updateSampling()
    }
    context.resources.addObserver(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { [weak self] in
      self?.sessionIsActive = true
      self?.updateSampling()
    }
    context.resources.add(.observer) { [weak self] in self?.visibilityObservation = nil }
    updateSampling()
  }

  public func stop() async {
    visibilityObservation = nil
    samplingToken = nil
    sampling = nil
    lastSampleInstant = nil
    temperatures = nil
    lastTemperatureRead = nil
    isSettingsVisible = false
    popover = nil
    statusItem = nil
    model = nil
  }

  public var settings: AnyView {
    AnyView(
      MonitorSettingsView(model: model) { [weak self] visible in
        self?.isSettingsVisible = visible
        self?.visibilityChanged()
      }
    )
  }

  private var isVisible: Bool { isSettingsVisible || popover?.isOpen == true }

  /// While visible it samples every second and reads temperatures right away;
  /// when closed the sensor reader is released.
  private func visibilityChanged() {
    guard model != nil else { return }
    updateSampling()
    sampling?.setCadence(isVisible ? .visible : .background)
    if isVisible {
      lastTemperatureRead = nil
      readTemperaturesIfDue()
    } else {
      temperatures = nil
      lastTemperatureRead = nil
      model?.temperature = nil
    }
  }

  /// The sampler subscription exists only if someone can see the result:
  /// item visible (or popover/Settings open) and the user's session active.
  private func updateSampling() {
    guard let model else { return }
    let itemVisible = statusItem?.item?.isVisible ?? true
    let shouldSample = sessionIsActive && (itemVisible || isVisible)
    if shouldSample, sampling == nil {
      let subscription = context.sampler.subscribe(cadence: isVisible ? .visible : .background) { [weak self] in
        self?.sample()
      }
      sampling = subscription
      samplingToken = context.resources.addSharedSampleSubscription(subscription)
      // After the pause the old reference is no longer valid.
      model.resetBaseline()
      sample()
    } else if !shouldSample, let samplingToken {
      context.resources.cancel(samplingToken)
      self.samplingToken = nil
      sampling = nil
    }
  }

  /// On popover open: if the last sample is more than
  /// a second old, one is taken right away.
  private func sampleIfStale() {
    if let lastSampleInstant, ContinuousClock.now - lastSampleInstant < .seconds(1) { return }
    sample()
  }

  private func readTemperaturesIfDue() {
    guard let model, isVisible else { return }
    let now = ContinuousClock.now
    if let lastTemperatureRead, now - lastTemperatureRead < Self.temperatureInterval { return }
    lastTemperatureRead = now
    // The HID client is created at the first read and dies with the module.
    if temperatures == nil { temperatures = TemperatureReader() }
    model.temperature = temperatures?.read()
  }

  /// The reads are a few syscalls (tens of microseconds): they stay on main,
  /// without creating a task and a thread hop at every sample.
  private func sample() {
    guard let model else { return }
    lastSampleInstant = .now
    model.update(SystemMetricsReader.read())
    readTemperaturesIfDue()
    statusItem?.updateIfChanged(
      StatusItemContent(
        symbol: Self.descriptor.symbol,
        title: model.cpuStatus,
        accessibilityLabel: model.accessibilitySummary
      )
    )
  }
}

private struct MonitorSettingsView: View {
  let model: MonitorModel?
  let onVisibility: (Bool) -> Void

  var body: some View {
    Form {
      Section {
        LabeledContent("Processor", value: model?.cpuStatus ?? String(localized: "Waiting for the first sample"))
        LabeledContent("Memory", value: memory)
        LabeledContent("Network received", value: rate(model?.receivedBytesPerSecond))
        LabeledContent("Network sent", value: rate(model?.sentBytesPerSecond))
        LabeledContent("Startup disk", value: disk)
        LabeledContent("Battery", value: battery)
        if let value = model?.temperature?.cpu {
          LabeledContent("Processor temperature", value: MonitorFormat.degrees(value))
        }
        if let value = model?.temperature?.battery {
          LabeledContent("Battery temperature", value: MonitorFormat.degrees(value))
        }
        if let value = model?.temperature?.storage {
          LabeledContent("Disk temperature", value: MonitorFormat.degrees(value))
        }
      } header: {
        Text("System")
      } footer: {
        Text("Temperatures are read only while this page or the Monitor panel is open.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text("Monitor"))
    .onAppear { onVisibility(true) }
    .onDisappear { onVisibility(false) }
  }

  private var memory: String {
    guard let model else { return "—" }
    return MonitorFormat.bytePair(model.memoryUsedBytes, model.memoryTotalBytes)
  }

  private var disk: String {
    guard let model else { return "—" }
    return MonitorFormat.bytePair(model.diskUsedBytes, model.diskTotalBytes)
  }

  private var battery: String {
    guard let battery = model?.battery else { return String(localized: "Unavailable") }
    let state =
      switch battery.state {
      case .charging: String(localized: "Charging")
      case .full: String(localized: "Carica completa")
      case .pluggedIn: String(localized: "Collegata")
      case .discharging: String(localized: "On battery")
      }
    return "\(battery.percentage)% · \(state)"
  }

  private func rate(_ value: Double?) -> String {
    guard let value else { return "—" }
    return MonitorFormat.rate(value)
  }
}

private extension Duration {
  var timeInterval: TimeInterval {
    let value = components
    return TimeInterval(value.seconds) + TimeInterval(value.attoseconds) / 1e18
  }
}
