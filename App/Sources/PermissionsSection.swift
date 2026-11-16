// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI

/// Permissions of a module with their state. The state is re-read only when the
/// page appears and when the app becomes active again (coming back from System
/// Settings): no polling.
struct PermissionsSection: View {
  let model: AppModel
  let permissions: [Permission]
  let blocking: [Permission]

  @State private var statuses: [Permission: PermissionStatus] = [:]

  var body: some View {
    Section {
      ForEach(permissions, id: \.self) { permission in
        row(permission, status: statuses[permission] ?? .unknown)
      }
    } header: {
      Text("Permissions")
    } footer: {
      if !blocking.isEmpty {
        Label("Grant the missing permissions, then turn the module on again.", systemImage: "lock.fill")
          .foregroundStyle(.orange)
      }
    }
    .onAppear(perform: refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refresh()
    }
  }

  private func row(_ permission: Permission, status: PermissionStatus) -> some View {
    LabeledContent {
      HStack(spacing: TsukumoTokens.Spacing.sm) {
        Text(label(status))
          .foregroundStyle(status == .granted ? .green : .secondary)
        switch status {
        case .granted, .unknown:
          if blocking.contains(permission), status == .granted {
            Button("Restart Tsukumo") {
              do {
                try LocalAppRelauncher.restart()
              } catch {
                NSApp.presentError(error)
              }
            }
          }
        case .notDetermined:
          Button("Allow…") {
            Task {
              statuses[permission] = await model.permissions.request(permission)
            }
          }
        case .denied:
          Button("Open System Settings") {
            Task {
              // Accessibility, Input Monitoring and Screen Recording have no
              // "never asked" state: without an explicit request Tsukumo does not
              // even appear in the System Settings list.
              let status = await model.permissions.request(permission)
              statuses[permission] = status
              if status != .granted, let url = PermissionBroker.settingsURL(for: permission) {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
      }
    } label: {
      Text(name(permission))
    }
  }

  private func refresh() {
    statuses = Dictionary(uniqueKeysWithValues: permissions.map { ($0, model.permissions.status(of: $0)) })
  }

  private func label(_ status: PermissionStatus) -> LocalizedStringKey {
    switch status {
    case .granted: "Granted"
    case .denied: "Not granted"
    case .notDetermined: "Not requested yet"
    case .unknown: "Requested on first use"
    }
  }

  private func name(_ permission: Permission) -> LocalizedStringKey {
    switch permission {
    case .accessibility: "Accessibility"
    case .inputMonitoring: "Input Monitoring"
    case .screenRecording: "Screen Recording"
    case .calendars: "Calendars"
    case .reminders: "Reminders"
    case .motion: "Motion"
    case .bluetooth: "Bluetooth"
    case .localNetwork: "Local Network"
    case .automation: "Automation"
    }
  }
}
