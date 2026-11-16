// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI

/// Energy panel: Tsukumo's consumption measured with `proc_pid_rusage`.
/// Samples every 2 s only while the section is visible, i.e. shown and with
/// the window neither covered nor minimized to the Dock; otherwise nothing runs
/// (DESIGN.md §3.6).
struct EnergySection: View {
  @State private var rate: EnergyRate?
  @State private var previous: EnergySnapshot?
  @State private var resources: ResourceBag?
  @State private var isShown = false
  @State private var isWindowVisible = true

  var body: some View {
    Section {
      LabeledContent("CPU") { value(rate.map { percent($0.cpuPercent) }) }
      LabeledContent("Average power") { value(rate.map { milliwatts($0.milliwatts) }) }
      LabeledContent("Wakeups per second") { value(rate.map { wakeups($0.wakeupsPerSecond) }) }
      LabeledContent("Memory") {
        value(rate.map { $0.physicalFootprintBytes.formatted(.byteCount(style: .memory)) })
      }
    } header: {
      Text("Energy")
    } footer: {
      Text("App values over the last 2 seconds, measured only while this page is open.")
    }
    .background(WindowVisibilityReader { isWindowVisible = $0 })
    .onAppear { isShown = true }
    .onDisappear { isShown = false }
    .onChange(of: isShown && isWindowVisible, initial: true) { _, active in
      if active { start() } else { stop() }
    }
  }

  private func value(_ text: String?) -> some View {
    Text(verbatim: text ?? "–")
      .monospacedDigit()
      .foregroundStyle(text == nil ? .secondary : .primary)
  }

  private func start() {
    guard resources == nil else { return }
    let bag = ResourceBag()
    previous = EnergySampler.snapshot()
    bag.addTimer(every: .seconds(2), tolerance: .milliseconds(400)) { sample() }
    resources = bag
  }

  private func stop() {
    resources?.cancelAll()
    resources = nil
    previous = nil
    rate = nil
  }

  private func sample() {
    guard let current = EnergySampler.snapshot() else { return }
    if let previous {
      rate = EnergyRate(from: previous, to: current)
    }
    previous = current
  }

  private func percent(_ value: Double) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(1)))
  }

  private func milliwatts(_ value: Double) -> String {
    Measurement(value: value, unit: UnitPower.milliwatts)
      .formatted(
        .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
  }

  private func wakeups(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }
}

/// Reports whether the window containing the view is visible on screen
/// (`occlusionState`): fully covered, minimized to the Dock or hidden counts
/// as invisible. Notifications only, no polling.
private struct WindowVisibilityReader: NSViewRepresentable {
  let onChange: @MainActor (Bool) -> Void

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: ProbeView, context: Context) {
    view.onChange = onChange
  }

  static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
    view.stopObserving()
  }

  final class ProbeView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?
    private var observer: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard let window else { return }
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.report() }
      }
      // Outside SwiftUI's update pass: the state changes afterwards.
      Task { @MainActor [weak self] in self?.report() }
    }

    func stopObserving() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
    }

    private func report() {
      guard let window else { return }
      onChange?(window.occlusionState.contains(.visible))
    }
  }
}
