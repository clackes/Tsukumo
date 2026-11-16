// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SoundSettingsModel {
  var prefs = SoundPrefs() { didSet { if prefs != oldValue { onChange?(prefs) } } }
  @ObservationIgnored var onChange: ((SoundPrefs) -> Void)?
  /// Installed music apps; read when the page appears, not before.
  private(set) var installedApps: [MusicApp] = []

  func refreshInstalledApps() {
    let workspace = NSWorkspace.shared
    installedApps = MusicApp.known.filter {
      workspace.urlForApplication(withBundleIdentifier: $0.bundleID) != nil || $0.bundleID == prefs.alternativeBundleID
    }
  }
}

struct SoundSettingsView: View {
  @Bindable var model: SoundSettingsModel

  var body: some View {
    Form {
      Section {
        Toggle("Also switch the system effects output", isOn: $model.prefs.includeSystemEffects)
      } header: {
        Text("Output")
      } footer: {
        Text("Alerts and system sounds follow the output chosen in the menu.")
      }
      Section {
        Toggle("Block the Music app", isOn: $model.prefs.blockMusic)
        Picker("Open instead", selection: $model.prefs.alternativeBundleID) {
          Text("None").tag(String?.none)
          ForEach(model.installedApps) { app in
            Text(verbatim: app.name).tag(Optional(app.bundleID))
          }
        }
        .disabled(!model.prefs.blockMusic)
      } header: {
        Text("Music")
      } footer: {
        Text(
          "If Music starts on its own (play, headphones connected) it is quit right away. No permissions needed."
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text("Sound"))
    .onAppear { model.refreshInstalledApps() }
  }
}
