// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import DesignSystem
import ModuleKit
import SwiftUI

/// Skeleton of the Settings window: module sidebar and detail page.
struct SettingsView: View {
  private typealias Page = SettingsPage

  @Bindable var model: AppModel

  private var selection: Binding<Page?> {
    Binding(get: { model.settingsPage }, set: { model.settingsPage = $0 ?? .general })
  }

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Label("General", systemImage: "gearshape")
          .tag(Page.general)
        Section("Modules") {
          ForEach(model.registry.entries, id: \.descriptor.id) { entry in
            ModuleRow(model: model, descriptor: entry.descriptor)
              .tag(Page.module(entry.descriptor.id))
          }
        }
      }
      .navigationSplitViewColumnWidth(min: TsukumoTokens.Size.sidebarMinWidth, ideal: 230, max: 300)
    } detail: {
      switch model.settingsPage {
      case .module(let id):
        if let entry = model.registry.entries.first(where: { $0.descriptor.id == id }) {
          ModulePage(model: model, descriptor: entry.descriptor)
            .id(id)
        }
      case .general:
        GeneralPage(model: model)
      }
    }
    .frame(minWidth: TsukumoTokens.Size.settingsMinWidth, minHeight: TsukumoTokens.Size.settingsMinHeight)
  }
}

private struct ModuleRow: View {
  let model: AppModel
  let descriptor: ModuleDescriptor

  var body: some View {
    HStack(spacing: TsukumoTokens.Spacing.sm) {
      ModuleIcon(symbol: descriptor.symbol, color: descriptor.tint.color, size: 22)
      Text(model.name(of: descriptor))
        .lineLimit(1)
      Spacer(minLength: 0)
      if model.registry.isRunning(descriptor.id) {
        Circle()
          .fill(.green)
          .frame(width: 7, height: 7)
          .accessibilityLabel(Text("Running"))
      }
    }
  }
}

private struct GeneralPage: View {
  let model: AppModel
  private static let sponsorsURL = URL(string: "https://github.com/sponsors/clackes")

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.xs) {
          Text(verbatim: "Tsukumo")
            .font(.title2.weight(.semibold))
          Text("One app instead of twelve.")
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, TsukumoTokens.Spacing.xs)
      }
      Section {
        LabeledContent("Version", value: Self.version)
        LabeledContent("Modules running") {
          Text(verbatim: "\(runningCount) / \(model.registry.entries.count)")
            .monospacedDigit()
        }
      } footer: {
        Text("A module that is off costs nothing: it is never even instantiated.")
      }
      Section("Startup") {
        Toggle(
          "Open Tsukumo at login",
          isOn: Binding(
            get: { model.launchesAtLogin },
            set: { model.setLaunchAtLogin($0) }
          ))
      }
      Section {
        Toggle(
          "Show Tsukumo's main menu bar icon",
          isOn: Binding(
            get: { model.showsMenuBarIcon },
            set: { model.setShowsMenuBarIcon($0) }
          ))
      } header: {
        Text("Menu Bar")
      } footer: {
        Text("The arrow for showing hidden icons stays visible.")
      }
      Section {
        Button("Review permissions…") { model.onReviewPermissions?() }
      } header: {
        Text("Permissions")
      } footer: {
        Text("All module permissions on one page, as on first launch.")
      }
      Section {
        if let url = Self.feedbackURL(kind: .bug) {
          Link(destination: url) {
            Label("Report a Problem", systemImage: "ladybug")
          }
        }
        if let url = Self.feedbackURL(kind: .idea) {
          Link(destination: url) {
            Label("Suggest an Idea", systemImage: "lightbulb")
          }
        }
      } header: {
        Text("Feedback")
      } footer: {
        Text(
          """
          Opens a GitHub issue prefilled with the Tsukumo and macOS versions. You can read and \
          edit it before sending. A GitHub account is required; the app never sends anything on its own.
          """)
      }
      Section {
        if let url = Self.sponsorsURL {
          Link(destination: url) {
            Label("GitHub Sponsors", systemImage: "heart")
          }
        }
      } header: {
        Text("Support the Project")
      } footer: {
        Text("Tsukumo is free, with no paywall. The link opens in your browser; the app makes no network requests.")
      }
      EnergySection()
    }
    .formStyle(.grouped)
    .navigationTitle(Text("General"))
  }

  private var runningCount: Int {
    model.registry.entries.count { model.registry.isRunning($0.descriptor.id) }
  }

  enum FeedbackKind {
    case bug, idea
  }

  /// New issue in the public repo, with only app and system versions: no
  /// personal data, and it is submitted from the browser, not from the app.
  static func feedbackURL(kind: FeedbackKind) -> URL? {
    let system = ProcessInfo.processInfo.operatingSystemVersionString
    let body: String
    let label: String
    switch kind {
    case .bug:
      label = "bug"
      body = """
        **What happened**


        **What you expected**


        **How to reproduce it (module, steps)**


        ---
        Tsukumo \(version) · macOS \(system)
        """
    case .idea:
      label = "enhancement"
      body = """
        **The idea**


        **What you would use it for**


        ---
        Tsukumo \(version) · macOS \(system)
        """
    }
    var components = URLComponents(string: "https://github.com/clackes/Tsukumo/issues/new")
    components?.queryItems = [
      URLQueryItem(name: "labels", value: label),
      URLQueryItem(name: "body", value: body),
    ]
    return components?.url
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }
}

private struct ModulePage: View {
  let model: AppModel
  let descriptor: ModuleDescriptor

  var body: some View {
    let state = model.registry.state(of: descriptor.id)
    Form {
      Section {
        Toggle(isOn: enabledBinding) {
          HStack(spacing: TsukumoTokens.Spacing.md) {
            ModuleIcon(symbol: descriptor.symbol, color: descriptor.tint.color, size: 34)
            VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.xxs) {
              Text(model.name(of: descriptor))
                .font(.headline)
              Text(stateLabel(state))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
        }
        .toggleStyle(.switch)
        .disabled(state == .starting)
        // One checkmark for each menu bar icon the turned-on module has.
        ForEach(model.registry.surfaces.statusItems(of: descriptor.id)) { item in
          Toggle(
            isOn: Binding(
              get: { item.isVisible },
              set: { model.registry.surfaces.setStatusItemVisible($0, autosaveName: item.id) }
            )
          ) {
            Text("Show in the menu bar")
          }
        }
      }

      Section {
        LabeledContent("Energy use") { Text(energyLabel) }
        if descriptor.permissions.isEmpty {
          LabeledContent("Permissions") { Text("None") }
        }
      } footer: {
        if case .suspended(let reason) = state {
          Label {
            Text(verbatim: reason)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          .foregroundStyle(.orange)
        }
      }

      if !descriptor.permissions.isEmpty {
        PermissionsSection(
          model: model,
          permissions: descriptor.permissions.sorted { $0.rawValue < $1.rawValue },
          blocking: model.missingPermissions[descriptor.id] ?? []
        )
      }

      Section {
        // The module's page is built only if the module is turned on.
        if let module = model.registry.module(descriptor.id) {
          module.settings
        } else {
          Text("Turn the module on to see its settings.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text(model.name(of: descriptor)))
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { model.registry.state(of: descriptor.id) != .off },
      set: { enabled in
        Task { await model.setEnabled(enabled, id: descriptor.id) }
      }
    )
  }

  private func stateLabel(_ state: ModuleState) -> LocalizedStringKey {
    switch state {
    case .off: "Off"
    case .starting: "Starting"
    case .running: "Running"
    case .suspended: "Paused"
    }
  }

  private var energyLabel: LocalizedStringKey {
    switch descriptor.energyClass {
    case .zero: "Zero"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    }
  }
}
