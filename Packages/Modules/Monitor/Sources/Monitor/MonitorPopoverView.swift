// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import SwiftUI

/// Content of the Monitor popover: rings, CPU history, network and temperatures.
/// No continuous animation: the view redraws only when a
/// sample arrives and only while the panel is open. Animations are short springs
/// on open (rings and charts drawing themselves) and at every new sample.
struct MonitorPopoverView: View {
  let model: MonitorModel
  /// Closes the panel after an action (opening Activity Monitor).
  var onDismiss: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.md) {
      PopoverHeader(Text("Monitor"), symbol: "chart.bar.fill", tint: .green) { uptime }
      gauges
      cpuSection
      networkSection
      if !MonitorFormat.temperatureEntries(model.temperature).isEmpty { temperatureSection }
      ActivityMonitorRow(onOpen: onDismiss)
    }
  }

  // MARK: Header

  private var uptime: some View {
    let text = MonitorFormat.uptime(MonitorFormat.secondsSinceBoot())
    return Label(text, systemImage: "clock")
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .accessibilityLabel(Text("Up for \(text)"))
  }

  // MARK: Rings

  private var gauges: some View {
    PopoverSection {
      Grid(alignment: .top, horizontalSpacing: TsukumoTokens.Spacing.sm, verticalSpacing: TsukumoTokens.Spacing.md) {
        GridRow {
          RingGauge(
            title: Text("CPU"), detail: cpuAverageDetail, percent: model.cpuPercent,
            level: model.cpuPercent.map { GaugeLevel(usage: $0) } ?? .normal)
          let memory = MonitorFormat.usage(used: model.memoryUsedBytes, total: model.memoryTotalBytes)
          RingGauge(
            title: Text("Memory"),
            detail: model.memoryTotalBytes > 0
              ? Text(verbatim: MonitorFormat.bytePair(model.memoryUsedBytes, model.memoryTotalBytes)) : nil,
            percent: memory, level: memory.map { GaugeLevel(usage: $0) } ?? .normal)
        }
        GridRow {
          let disk = MonitorFormat.usage(used: model.diskUsedBytes, total: model.diskTotalBytes)
          RingGauge(
            title: Text("Disk"),
            detail: model.diskTotalBytes > 0
              ? Text("\(MonitorFormat.bytes(model.diskTotalBytes &- model.diskUsedBytes)) free") : nil,
            percent: disk, level: disk.map { GaugeLevel(usage: $0) } ?? .normal)
          if let battery = model.battery {
            RingGauge(
              title: Text("Battery"), detail: Text(batteryState(battery)), percent: Double(battery.percentage),
              level: GaugeLevel(
                batteryPercent: battery.percentage, isPluggedIn: battery.state != .discharging),
              symbol: battery.state == .charging ? "bolt.fill" : nil)
          } else {
            NetworkTile(received: model.receivedBytesPerSecond, sent: model.sentBytesPerSecond)
          }
        }
      }
      .frame(maxWidth: .infinity)
    }
  }

  private var cpuAverageDetail: Text? {
    guard !model.cpuHistory.isEmpty else { return nil }
    let values = model.cpuHistory.elements
    let average = Int((values.reduce(0, +) / Double(values.count)).rounded())
    return Text("avg \(average)%")
  }

  private func batteryState(_ battery: BatteryReading) -> LocalizedStringKey {
    switch battery.state {
    case .charging: "Charging"
    case .full: "Carica completa"
    case .pluggedIn: "Collegata"
    case .discharging: "On battery"
    }
  }

  // MARK: CPU

  private var cpuSection: some View {
    PopoverSection(Text("CPU, Last Minute")) {
      Sparkline(
        series: [Sparkline.Series(values: model.cpuHistory.elements, color: cpuColor, filled: true)],
        capacity: MonitorModel.historyCapacity, scale: 100
      )
      .frame(height: 38)
      .accessibilityHidden(true)
    }
  }

  private var cpuColor: Color {
    model.cpuPercent.map { GaugeLevel(usage: $0).color } ?? .green
  }

  // MARK: Network

  private var networkSection: some View {
    PopoverSection(Text("Network")) {
      HStack(spacing: TsukumoTokens.Spacing.md) {
        RateLabel(symbol: "arrow.down.circle.fill", color: .blue, rate: model.receivedBytesPerSecond)
        RateLabel(symbol: "arrow.up.circle.fill", color: .orange, rate: model.sentBytesPerSecond)
      }
      let history = model.networkHistory.elements
      // Scale shared by the two lines, with a minimum: with an idle network noise does not become a mountain.
      let peak = max(history.map { max($0.received, $0.sent) }.max() ?? 0, 10_000)
      Sparkline(
        series: [
          Sparkline.Series(values: history.map(\.received), color: .blue, filled: false),
          Sparkline.Series(values: history.map(\.sent), color: .orange, filled: false),
        ],
        capacity: MonitorModel.historyCapacity, scale: peak
      )
      .frame(height: 30)
      .accessibilityHidden(true)
    }
  }

  // MARK: Temperatures

  private var temperatureSection: some View {
    PopoverSection(Text("Temperature")) {
      HStack(spacing: TsukumoTokens.Spacing.sm) {
        ForEach(MonitorFormat.temperatureEntries(model.temperature), id: \.label) { entry in
          TemperatureChip(label: entry.label, symbol: entry.symbol, celsius: entry.value)
        }
      }
    }
  }
}

// MARK: - Components

/// Capacity ring: large value in the center, name below, detail in small type.
private struct RingGauge: View {
  let title: Text
  var detail: Text?
  let percent: Double?
  let level: GaugeLevel
  var symbol: String?

  private static let diameter: CGFloat = 64
  private static let line: CGFloat = 7
  /// On open the ring starts from zero and fills up.
  @State private var drawn = false

  private var fraction: Double { drawn ? min(max(percent ?? 0, 0), 100) / 100 : 0 }

  var body: some View {
    VStack(spacing: TsukumoTokens.Spacing.xs) {
      ZStack {
        Circle().stroke(.primary.opacity(0.1), lineWidth: Self.line)
        Circle()
          .trim(from: 0, to: fraction)
          .stroke(level.color.gradient, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .opacity(fraction > 0 ? 1 : 0)
          .animation(.spring(response: 0.6, dampingFraction: 0.82), value: fraction)
          .animation(.easeInOut(duration: 0.4), value: level)
        VStack(spacing: 0) {
          if let symbol {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(level.color)
          }
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(verbatim: percent.map { String(Int($0.rounded())) } ?? "—")
              .font(.system(size: 20, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .contentTransition(.numericText())
              .animation(.snappy(duration: 0.35), value: percent.map { Int($0.rounded()) })
            if percent != nil {
              Text(verbatim: "%").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
          }
        }
      }
      .frame(width: Self.diameter, height: Self.diameter)
      title.font(.caption.weight(.semibold))
      if let detail {
        detail.font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .onAppear { drawn = true }
  }
}

/// In place of the battery on Macs that do not have one: network speed in the same format.
private struct NetworkTile: View {
  let received: Double?
  let sent: Double?

  var body: some View {
    VStack(spacing: TsukumoTokens.Spacing.xs) {
      ZStack {
        Circle().stroke(.primary.opacity(0.1), lineWidth: 7)
        Image(systemName: "arrow.up.arrow.down")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.blue)
      }
      .frame(width: 64, height: 64)
      Text("Network").font(.caption.weight(.semibold))
      VStack(spacing: 0) {
        Text(verbatim: "↓ " + (received.map { MonitorFormat.rate($0) } ?? "—"))
        Text(verbatim: "↑ " + (sent.map { MonitorFormat.rate($0) } ?? "—"))
      }
      .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

private struct RateLabel: View {
  let symbol: String
  let color: Color
  let rate: Double?

  var body: some View {
    HStack(spacing: TsukumoTokens.Spacing.xs) {
      Image(systemName: symbol).foregroundStyle(color)
      Text(verbatim: rate.map { MonitorFormat.rate($0) } ?? "—")
        .font(.callout.weight(.medium))
        .monospacedDigit()
        .contentTransition(.numericText())
        .animation(.snappy(duration: 0.35), value: rate.map { MonitorFormat.rate($0) })
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct TemperatureChip: View {
  let label: String
  let symbol: String
  let celsius: Double

  var body: some View {
    HStack(spacing: TsukumoTokens.Spacing.xs) {
      Image(systemName: symbol).font(.callout).foregroundStyle(tint)
        .animation(.easeInOut(duration: 0.4), value: tint)
      VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: label).font(.caption2).foregroundStyle(.secondary)
        Text(verbatim: "\(Int(celsius.rounded()))°")
          .font(.callout.weight(.semibold))
          .monospacedDigit()
          .contentTransition(.numericText())
          .animation(.snappy(duration: 0.35), value: Int(celsius.rounded()))
      }
    }
    .padding(.horizontal, TsukumoTokens.Spacing.sm)
    .padding(.vertical, TsukumoTokens.Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.primary.opacity(0.06), in: Capsule())
    .accessibilityElement(children: .combine)
  }

  /// Hot sensor: orange from 70 °C, red from 85 °C.
  private var tint: Color {
    celsius >= 85 ? .red : celsius >= 70 ? .orange : .secondary
  }
}

/// Row at the bottom of the panel: opens Activity Monitor.
private struct ActivityMonitorRow: View {
  var onOpen: (() -> Void)?

  var body: some View {
    Button {
      open()
    } label: {
      HStack {
        Label("Open Activity Monitor", systemImage: "waveform.path.ecg.rectangle")
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
      }
      .font(.callout)
      .padding(.horizontal, TsukumoTokens.Spacing.sm)
      .padding(.vertical, TsukumoTokens.Spacing.sm)
      .contentShape(Rectangle())
      .modifier(HoverHighlight())
    }
    .buttonStyle(.plain)
  }

  private func open() {
    onOpen?()
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }
}

/// Line chart without axes: the latest sample sits on the right and the curve grows
/// from the right until the buffer is full. `scale` is the full-scale value.
struct Sparkline: View {
  struct Series {
    let values: [Double]
    let color: Color
    let filled: Bool
  }

  let series: [Series]
  let capacity: Int
  let scale: Double
  /// On open the line is drawn from left to right.
  @State private var drawn = false

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(.primary.opacity(0.04))
      ForEach(series.indices, id: \.self) { index in
        let item = series[index]
        if item.filled {
          SparklineShape(values: item.values, capacity: capacity, scale: scale, closed: true)
            .fill(
              LinearGradient(
                colors: [item.color.opacity(0.45), item.color.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            )
            .opacity(drawn ? 1 : 0)
        }
        SparklineShape(values: item.values, capacity: capacity, scale: scale, closed: false)
          .trim(from: 0, to: drawn ? 1 : 0)
          .stroke(item.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
      }
    }
    .animation(.easeOut(duration: 0.7), value: drawn)
    .onAppear { drawn = true }
  }
}

struct SparklineShape: Shape {
  let values: [Double]
  let capacity: Int
  let scale: Double
  let closed: Bool

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard !values.isEmpty, capacity > 1, scale > 0 else { return path }
    let step = rect.width / CGFloat(capacity - 1)
    let inset: CGFloat = 1.5
    let height = rect.height - inset * 2
    // The most recent sample sits on the right edge.
    let offset = capacity - values.count
    let points = values.enumerated().map { index, value in
      CGPoint(
        x: rect.minX + CGFloat(index + offset) * step,
        y: rect.maxY - inset - CGFloat(min(max(value / scale, 0), 1)) * height)
    }
    path.move(to: closed ? CGPoint(x: points[0].x, y: rect.maxY) : points[0])
    if closed { path.addLine(to: points[0]) }
    for point in points.dropFirst() { path.addLine(to: point) }
    if closed {
      path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
      path.closeSubpath()
    }
    return path
  }
}
