// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI

/// Screen-bend animation tied to the MacBook's hinge
/// (DESIGN.md §2.4, spike 7). The base code comes from fx-xf/duo (MIT).
@MainActor
public final class DuoModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "duo",
    nameKey: "Duo",
    symbol: "macbook",
    tint: .indigo,
    permissions: [.screenRecording],
    energyClass: .low
  )

  private let context: ModuleContext
  private let model = DuoModel()
  private var engine: BendEngine?

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    let prefs: DuoPrefs = context.settings.value(forKey: "prefs", moduleID: Self.descriptor.id) ?? DuoPrefs()
    model.prefs = prefs
    guard let engine = BendEngine(resources: context.resources) else {
      model.sensorAvailable = false
      throw DuoError.noLidSensor
    }
    model.sensorAvailable = true
    engine.prefs = prefs
    self.engine = engine
    model.onChange = { [weak self] prefs in
      guard let self else { return }
      engine.prefs = prefs
      try? self.context.settings.set(prefs, forKey: "prefs", moduleID: Self.descriptor.id)
    }
    model.onPreview = { engine.preview() }
    engine.onAngle = { [weak model] angle in model?.report(angle) }
  }

  public func stop() async {
    engine?.onAngle = nil
    engine?.shutdown()
    model.currentAngle = nil
    engine = nil
    model.onChange = nil
    model.onPreview = nil
  }

  public var settings: AnyView { AnyView(DuoSettingsView(model: model)) }

  public var health: ModuleHealth {
    get async { engine == nil ? .broken("hinge sensor missing") : .ok }
  }
}

enum DuoError: Error {
  case noLidSensor
}

@MainActor
@Observable
final class DuoModel {
  var prefs = DuoPrefs() { didSet { if prefs != oldValue { onChange?(prefs) } } }
  var sensorAvailable = true
  /// Current hinge angle in whole degrees; `nil` until a reading arrives.
  var currentAngle: Int?
  var onChange: ((DuoPrefs) -> Void)?
  var onPreview: (() -> Void)?

  /// Updates only when the whole degree changes: observed views
  /// redraw at most once per degree, and never with the lid still.
  func report(_ angle: Double) {
    let degrees = Int(angle.rounded())
    if degrees != currentAngle { currentAngle = degrees }
  }
}

struct DuoSettingsView: View {
  @Bindable var model: DuoModel

  var body: some View {
    Form {
      Section {
        Label("Close the display slowly: below the start angle, the desktop folds", systemImage: "macbook")
        Button("Try the Effect") { model.onPreview?() }
      } header: {
        Text("How It Works")
      } footer: {
        Text(
          """
          Requires Screen Recording permission. Capture runs only while the hinge is moving \
          and frames stay in memory.
          """)
      }
      Section {
        LabeledContent("Current angle") {
          Text(verbatim: model.currentAngle.map { "\($0)°" } ?? "—")
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy(duration: TsukumoTokens.Motion.quick), value: model.currentAngle)
        }
        .help(Text("Open and close the lid to see which angle to set the values below to."))
        degreeSlider(
          "Starts below", value: $model.prefs.activationAngle, range: DuoPrefs.activationRange,
          help: "The fold starts only when the lid is below this angle.")
        degreeSlider(
          "Fully folded at", value: $model.prefs.startAngle, range: DuoPrefs.startAngleRange,
          help: "Degrees of closing that fold the screen completely.")
        degreeSlider(
          "Dead zone", value: $model.prefs.deadZone, range: DuoPrefs.deadZoneRange,
          help: "Degrees ignored before the fold begins: they absorb small jolts.")
      } header: {
        Text("Hinge")
      } footer: {
        Text("With \"Starts below\" at 140° the fold starts at any opening.")
      }
      Section {
        LabeledContent("Perspective") {
          Slider(value: $model.prefs.perspective, in: 0.25...2).frame(width: 200)
        }
        LabeledContent("Motion") {
          Slider(value: $model.prefs.motion, in: 0...1).frame(width: 200)
        }
        LabeledContent("Blur") {
          Slider(value: $model.prefs.blur, in: 0...1).frame(width: 200)
        }
        LabeledContent("Shadow") {
          Slider(value: $model.prefs.shadow, in: 0...1).frame(width: 200)
        }
      } header: {
        Text("Appearance")
      }
      if !model.sensorAvailable {
        Section {
          Label("This Mac doesn't have a hinge angle sensor", systemImage: "exclamationmark.triangle")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text("Duo"))
  }

  private func degreeSlider(
    _ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, help: LocalizedStringKey
  ) -> some View {
    LabeledContent(title) {
      HStack(spacing: 8) {
        Slider(value: value, in: range, step: 1).frame(width: 200)
        Text(verbatim: "\(Int(value.wrappedValue))°")
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
    }
    .help(Text(help))
  }
}
