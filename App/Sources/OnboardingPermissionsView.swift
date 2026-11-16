// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI

/// Full Disk Access: it is not a permission that can be requested with a
/// prompt or read with an API. It is inferred by trying to list a protected
/// folder (the one the Menu Bar module needs to read).
enum FullDiskAccess {
  static var isGranted: Bool {
    let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter"
    return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
  }

  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}

/// All permissions of all modules on a single page (DESIGN.md §6.1):
/// requested once, at first launch, instead of module by module.
/// The state is re-read when the app becomes active again (coming back from
/// System Settings): no polling.
struct OnboardingPermissionsView: View {
  let model: AppModel
  /// `true` if a permission that only takes effect after a relaunch was granted in the meantime.
  let onFinish: (_ needsRestart: Bool) -> Void

  @State private var statuses: [Permission: PermissionStatus] = [:]
  @State private var initial: [Permission: PermissionStatus] = [:]
  @State private var hasFullDiskAccess = FullDiskAccess.isGranted
  @State private var isAsking = false

  /// Permissions that only take effect in a new process (tap, capture).
  private static let restartSensitive: Set<Permission> = [.accessibility, .inputMonitoring, .screenRecording]

  var body: some View {
    VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.lg) {
      VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.sm) {
        Text("Permissions").font(.largeTitle).bold()
        Text("Grant them now, just once: after that every module works as soon as you turn it on.")
          .font(.title3)
          .foregroundStyle(.secondary)
        Text("macOS has you grant them in System Settings. Tsukumo sends nothing over the network.")
          .font(.callout)
          .foregroundStyle(.tertiary)
      }
      VStack(spacing: TsukumoTokens.Spacing.sm) {
        ForEach(permissions, id: \.self) { permission in
          row(
            Row(
              symbol: Self.symbol(permission), title: Self.name(permission), detail: Self.reason(permission),
              modules: moduleNames(using: permission)),
            granted: statuses[permission] == .granted
          ) {
            ask(permission, openSettings: true)
          }
        }
        row(
          Row(
            symbol: "externaldrive", title: "Full Disk Access",
            detail: "Optional. Only needed to hide other apps' icons from the menu bar.",
            modules: moduleNames(ids: ["menu-bar"])),
          granted: hasFullDiskAccess
        ) {
          if let url = FullDiskAccess.settingsURL { NSWorkspace.shared.open(url) }
        }
      }
      HStack {
        Button("Request all permissions") { askAll() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(isAsking || missing.isEmpty)
        Spacer()
        Button(finishTitle) { onFinish(needsRestart) }
          .controlSize(.large)
      }
    }
    .padding(TsukumoTokens.Spacing.xl)
    .frame(width: 620)
    .onAppear {
      refresh()
      initial = statuses
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refresh()
    }
  }

  // MARK: Data

  /// The permissions declared by the modules compiled into the app, among those macOS
  /// lets us check. The others (Automation, Bluetooth…) are requested by the
  /// system on first use and have no switch to prepare beforehand.
  private var permissions: [Permission] {
    let declared = model.registry.entries.reduce(into: Set<Permission>()) { $0.formUnion($1.descriptor.permissions) }
    return Permission.allCases.filter { declared.contains($0) && model.permissions.status(of: $0) != .unknown }
  }

  private var missing: [Permission] {
    permissions.filter { statuses[$0] != .granted }
  }

  private var finishTitle: LocalizedStringKey {
    if needsRestart { return "Restart Tsukumo and start" }
    return missing.isEmpty ? "Start" : "Continue without permissions"
  }

  private var needsRestart: Bool {
    Self.restartSensitive.contains { initial[$0] != nil && initial[$0] != .granted && statuses[$0] == .granted }
  }

  private func moduleNames(using permission: Permission) -> String {
    moduleNames(
      ids: model.registry.entries.filter { $0.descriptor.permissions.contains(permission) }.map(\.descriptor.id))
  }

  private func moduleNames(ids: [String]) -> String {
    model.registry.entries
      .filter { ids.contains($0.descriptor.id) }
      .map { model.name(of: $0.descriptor) }
      .formatted(.list(type: .and, width: .narrow))
  }

  private func refresh() {
    statuses = Dictionary(uniqueKeysWithValues: permissions.map { ($0, model.permissions.status(of: $0)) })
    hasFullDiskAccess = FullDiskAccess.isGranted
  }

  // MARK: Requests

  /// A single request. macOS shows its alert only the first time:
  /// from the second time on, the right System Settings page opens directly.
  private func ask(_ permission: Permission, openSettings: Bool) {
    Task {
      let status = await model.permissions.request(permission)
      statuses[permission] = status
      if openSettings, status != .granted, let url = PermissionBroker.settingsURL(for: permission) {
        NSWorkspace.shared.open(url)
      }
    }
  }

  /// All requests in sequence: the system alerts appear one after the other.
  private func askAll() {
    isAsking = true
    Task {
      for permission in missing {
        statuses[permission] = await model.permissions.request(permission)
        try? await Task.sleep(for: .milliseconds(350))
      }
      isAsking = false
      // Alerts already seen in the past: macOS does not show them again, so the
      // page of the first still-missing permission opens.
      if let first = missing.first, statuses[first] == .denied,
        let url = PermissionBroker.settingsURL(for: first)
      {
        NSWorkspace.shared.open(url)
      }
    }
  }

  // MARK: Row

  private struct Row {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    /// Names of the modules that use the permission, already joined into one line.
    let modules: String
  }

  private func row(_ row: Row, granted: Bool, action: @escaping () -> Void) -> some View {
    HStack(spacing: TsukumoTokens.Spacing.md) {
      Image(systemName: row.symbol)
        .font(.title3)
        .frame(width: 32, height: 32)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title).font(.headline)
        Text(row.detail).font(.callout).foregroundStyle(.secondary)
        if !row.modules.isEmpty {
          Text(verbatim: row.modules).font(.caption).foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: TsukumoTokens.Spacing.sm)
      if granted {
        Label("Granted", systemImage: "checkmark.circle.fill")
          .labelStyle(.iconOnly)
          .font(.title3)
          .foregroundStyle(.green)
      } else {
        Button("Allow…", action: action)
      }
    }
    .padding(TsukumoTokens.Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: TsukumoTokens.Radius.card, style: .continuous)
        .fill(Color.primary.opacity(0.03))
    )
    .overlay(
      RoundedRectangle(cornerRadius: TsukumoTokens.Radius.card, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
    )
  }

  private static func symbol(_ permission: Permission) -> String {
    switch permission {
    case .accessibility: "accessibility"
    case .inputMonitoring: "keyboard"
    case .screenRecording: "rectangle.dashed.badge.record"
    case .calendars: "calendar"
    case .reminders: "checklist"
    case .motion: "gyroscope"
    case .bluetooth: "dot.radiowaves.left.and.right"
    case .localNetwork: "network"
    case .automation: "gearshape.2"
    }
  }

  private static func name(_ permission: Permission) -> LocalizedStringKey {
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

  private static func reason(_ permission: Permission) -> LocalizedStringKey {
    switch permission {
    case .accessibility: "To move and tile windows, switch between them and reorder icons."
    case .inputMonitoring: "For key sounds: only which key is pressed is read, never the text."
    case .screenRecording: "For window thumbnails and the Duo effect. Images never leave your Mac."
    case .calendars: "To show your next event."
    case .reminders: "To show reminders that are due."
    case .motion, .bluetooth, .localNetwork, .automation: "macOS asks for it on first use."
    }
  }
}
