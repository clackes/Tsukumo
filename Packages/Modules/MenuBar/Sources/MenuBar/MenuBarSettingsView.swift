// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import Darwin
import DesignSystem
import ModuleKit
import SwiftUI

@MainActor
struct MenuBarSettingsView: View {
  let model: MenuBarSettingsModel?
  let order: MenuBarOrderModel?
  let surfaces: SurfaceManager
  @State private var filter = ""

  /// Apps whose name or bundle id contains the filter text.
  private func filtered(_ applications: [MenuBarApplication]) -> [MenuBarApplication] {
    let query = filter.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return applications }
    return applications.filter {
      $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    Form {
      Section {
        if model?.needsFullDiskAccess == true {
          Text(
            "macOS protects these preferences with Full Disk Access. "
              + "Add Tsukumo in Privacy & Security, then restart it."
          )
          .foregroundStyle(.secondary)
          Button("Open Full Disk Access") {
            model?.openFullDiskAccessSettings()
          }
        }

        if let model, !model.applications.isEmpty {
          let shown = filtered(model.applications)
          let changeable = shown.filter(\.canChangeVisibility)
          HStack(spacing: TsukumoTokens.Spacing.sm) {
            TextField("Filter", text: $filter, prompt: Text("Filter apps"))
              .textFieldStyle(.roundedBorder)
            Button("Select All") {
              model.setAllowed(true, for: changeable.filter { !$0.isAllowed }.map(\.bundleID))
            }
            .disabled(changeable.allSatisfy(\.isAllowed))
            Button("Deselect All") {
              model.setAllowed(false, for: changeable.filter(\.isAllowed).map(\.bundleID))
            }
            .disabled(changeable.allSatisfy { !$0.isAllowed })
          }
          .disabled(model.needsFullDiskAccess)
          if shown.isEmpty {
            Text("No apps match “\(filter)”.")
              .foregroundStyle(.secondary)
          }
          ForEach(shown) { application in
            Toggle(
              isOn: Binding(
                get: { application.isAllowed },
                set: { model.setAllowed($0, for: application.bundleID) }
              )
            ) {
              HStack(spacing: TsukumoTokens.Spacing.sm) {
                if let icon = application.icon {
                  Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                }
                Text(application.name)
              }
            }
            .toggleStyle(.switch)
            .disabled(model.needsFullDiskAccess || !application.canChangeVisibility)
          }
        } else if let message = model?.errorMessage {
          Text(message)
            .foregroundStyle(.secondary)
        }
        if let message = model?.errorMessage, model?.applications.isEmpty == false {
          Text(message)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Menu bar apps")
      } footer: {
        Text(
          "Turn off an app to hide its icons. "
            + "The apps keep working; system items are managed below."
        )
      }

      Section {
        ForEach(MenuBarSystemItem.allCases) { item in
          Toggle(
            isOn: Binding(
              get: { model?.systemItems[item] ?? item.shownByDefault },
              set: { model?.setSystemItem(item, shown: $0) }
            )
          ) {
            Label(item.title, systemImage: item.symbol)
          }
          .toggleStyle(.switch)
        }
      } header: {
        Text("System Items")
      } footer: {
        Text("This is the same setting found in System Settings, Menu Bar.")
      }

      Section {
        let items = surfaces.statusItems.filter(\.canHide)
        if items.isEmpty {
          Text("No Tsukumo icons to hide.")
            .foregroundStyle(.secondary)
        }
        ForEach(items) { item in
          Toggle(
            isOn: Binding(
              get: { item.isVisible },
              set: { surfaces.setStatusItemVisible($0, autosaveName: item.id) }
            )
          ) {
            Text(verbatim: item.title)
          }
          .toggleStyle(.switch)
        }
      } header: {
        Text("Tsukumo icons")
      } footer: {
        Text(
          "Hidden icons come back with the arrow. The main icon is turned off entirely in General."
        )
      }

      MenuBarOrderSection(order: order)

      Section {
        Button("Refresh list") {
          Task {
            await model?.refresh()
            await order?.refresh()
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text("Menu Bar"))
    .task {
      await model?.refresh()
      await order?.refresh()
    }
  }
}

extension MenuBarSystemItem {
  var title: LocalizedStringKey {
    switch self {
    case .wifi: "Wi‑Fi"
    case .bluetooth: "Bluetooth"
    case .focus: "Focus"
    case .sound: "Sound"
    case .nowPlaying: "Now Playing"
    }
  }
}
