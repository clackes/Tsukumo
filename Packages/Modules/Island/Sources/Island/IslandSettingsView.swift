// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit
import SwiftUI

@MainActor
struct IslandSettingsView: View {
  let model: IslandModel?
  let module: IslandModule

  var body: some View {
    Form {
      Section {
        Picker(
          "Open the island",
          selection: Binding(
            get: { model?.activation ?? .hover },
            set: { module.setActivation($0) }
          )
        ) {
          Text("On hover").tag(IslandActivation.hover)
          Text("On click").tag(IslandActivation.click)
        }
        .pickerStyle(.segmented)
        Toggle(
          "Blur around the open island",
          isOn: Binding(
            get: { model?.haloEnabled ?? false },
            set: { module.setHaloEnabled($0) }
          )
        )
      } footer: {
        Text("The island closes when the pointer leaves. The blur is off by default.")
      }

      Section {
        Toggle(
          "Show when power is connected",
          isOn: Binding(
            get: { model?.showCharging ?? false },
            set: { module.setShowCharging($0) }
          )
        )
        Toggle(
          "Show on track change",
          isOn: Binding(
            get: { model?.showTrackChanges ?? false },
            set: { module.setShowTrackChanges($0) }
          )
        )
        Picker(
          "While playing",
          selection: Binding(
            get: { model?.playbackIndicator ?? .waveform },
            set: { module.setPlaybackIndicator($0) }
          )
        ) {
          Text("Waveform").tag(IslandPlaybackIndicator.waveform)
          Text("Colored bars").tag(IslandPlaybackIndicator.bars)
          Text("Stop").tag(IslandPlaybackIndicator.still)
        }
        Toggle(
          "Show artwork for Music tracks",
          isOn: Binding(
            get: { model?.artworkEnabled ?? false },
            set: { module.setArtworkEnabled($0) }
          )
        )
        if model?.artworkEnabled == true, model?.artworkDenied == true {
          LabeledContent {
            Button("Open System Settings") {
              if let url = PermissionBroker.settingsURL(for: .automation) { NSWorkspace.shared.open(url) }
            }
          } label: {
            Text("Permission to control Music is required.").foregroundStyle(.secondary)
          }
        }
        Toggle(
          "Show song lyrics in the island",
          isOn: Binding(
            get: { model?.lyricsEnabled ?? false },
            set: { module.setLyricsEnabled($0) }
          )
        )
      } header: {
        Text("Activities")
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Tracks come from Music and Spotify. For artwork macOS asks for permission to control Music.")
          Text(
            """
            Lyrics come from lrclib.net: with lyrics on, in the island or on the lock screen, \
            the title, artist, album and duration of tracks are sent to that site.
            """)
        }
      }

      Section {
        Toggle(
          "Keep files in the island",
          isOn: Binding(
            get: { model?.shelfEnabled ?? false },
            set: { module.setShelfEnabled($0) }
          )
        )
      } footer: {
        Text("Drag a file onto the notch to park it: from there you can drag it elsewhere or send it with AirDrop.")
      }

      Section {
        Toggle(
          "Show the next event",
          isOn: Binding(
            get: { model?.calendarEnabled ?? false },
            set: { module.setCalendarEnabled($0) }
          )
        )
        if model?.calendarEnabled == true, model?.calendarAccess == .denied {
          LabeledContent {
            Button("Open System Settings") {
              if let url = PermissionBroker.settingsURL(for: .calendars) { NSWorkspace.shared.open(url) }
            }
          } label: {
            Text("Full calendar access is required.").foregroundStyle(.secondary)
          }
        }
      } footer: {
        Text(
          "Five minutes before an event the island announces it. With a Meet, Zoom or Teams link, Join appears."
        )
      }

      systemSection
    }
    .formStyle(.grouped)
    .onAppear { module.refreshHUDPermissions() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      module.refreshHUDPermissions()
    }
    .navigationTitle(Text("Island"))
    .disabled(model == nil)
  }

  // MARK: Lock screen and HUD

  private var systemSection: some View {
    Section {
      Toggle(
        "Show the lock when the screen is locked",
        isOn: Binding(get: { model?.lockEnabled ?? false }, set: { module.setLockEnabled($0) })
      )
      Toggle(
        "Show the island on the lock screen",
        isOn: Binding(get: { model?.lockScreenEnabled ?? false }, set: { module.setLockScreenEnabled($0) })
      )
      Toggle(
        "Show music on the lock screen",
        isOn: Binding(get: { model?.lockMediaEnabled ?? false }, set: { module.setLockMediaEnabled($0) })
      )
      Toggle(
        "Show lyrics next to the player",
        isOn: Binding(get: { model?.lockLyricsEnabled ?? false }, set: { module.setLockLyricsEnabled($0) })
      )
      .padding(.leading, 18)
      .disabled(model?.lockMediaEnabled != true)
      Toggle(
        isOn: Binding(get: { model?.lockBackdropEnabled ?? false }, set: { module.setLockBackdropEnabled($0) })
      ) {
        Text("Use artwork as background")
        Text(
          """
          Covers the clock, profile picture and password field. \
          Clicking the background shows them; Touch ID always works.
          """
        )
      }
      .padding(.leading, 18)
      .disabled(model?.lockMediaEnabled != true)
      Toggle(
        "Replace the volume and brightness HUDs",
        isOn: Binding(get: { model?.hudEnabled ?? false }, set: { module.setHUDEnabled($0) })
      )
      .disabled(model?.hudAccessibility != true && model?.hudEnabled != true)
      permissionRow(
        "Accessibility", detail: "Required for the HUD", granted: model?.hudAccessibility == true,
        permission: .accessibility
      ) { module.requestHUDAccessibility() }
      permissionRow(
        "Input Monitoring", detail: "Only if macOS asks for it", granted: model?.hudInputMonitoring == true,
        permission: .inputMonitoring
      ) { module.requestHUDInputMonitoring() }
      if model?.hudEnabled == true, model?.hudTapFailed == true {
        LabeledContent {
          Button("Restart Tsukumo") { try? LocalAppRelauncher.restart() }
        } label: {
          Text("macOS has not enabled key interception yet: grant the permissions above and restart.")
            .foregroundStyle(.orange)
        }
      }
    } header: {
      Text("System")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("With the HUD on, Tsukumo handles the volume and brightness keys and the bar appears under the notch.")
        Text("The lock screen and brightness use private macOS functions: they may stop working.")
      }
    }
  }

  private func permissionRow(
    _ title: LocalizedStringKey, detail: LocalizedStringKey, granted: Bool, permission: Permission,
    request: @escaping () -> Void
  ) -> some View {
    LabeledContent {
      if granted {
        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      } else {
        Button("Grant…") {
          request()
          if let url = PermissionBroker.settingsURL(for: permission) { NSWorkspace.shared.open(url) }
        }
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
