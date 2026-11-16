// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI

/// Panel of Tsukumo's menu bar icon: modules as Control Center tiles
/// (click = on/off), then Settings and Quit.
struct StatusPopoverView: View {
  let model: AppModel
  let showsRestoreSwitcher: Bool
  let openSettings: () -> Void
  let restoreSwitcher: () -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: TsukumoTokens.Spacing.sm), count: 3)

  var body: some View {
    VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.md) {
      header
      LazyVGrid(columns: columns, spacing: TsukumoTokens.Spacing.sm) {
        ForEach(model.registry.entries, id: \.descriptor.id) { entry in
          ModuleTile(
            descriptor: entry.descriptor,
            name: model.name(of: entry.descriptor),
            state: model.registry.state(of: entry.descriptor.id)
          ) {
            let enable = model.registry.state(of: entry.descriptor.id) == .off
            Task { await model.setEnabled(enable, id: entry.descriptor.id) }
          }
        }
      }
      PopoverSection {
        ActionRow(title: Text("Settings…"), symbol: "gearshape", action: openSettings)
        if showsRestoreSwitcher {
          ActionRow(title: Text("Restore System ⌘⇥"), symbol: "command", action: restoreSwitcher)
        }
        ActionRow(title: Text("Quit Tsukumo"), symbol: "power") { NSApp.terminate(nil) }
      }
    }
  }

  private var header: some View {
    HStack(spacing: TsukumoTokens.Spacing.sm) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
      Text(verbatim: "Tsukumo").font(.headline)
      Spacer(minLength: 0)
      Text(onCountLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  private var onCountLabel: LocalizedStringKey {
    let count = model.registry.entries.filter { model.registry.state(of: $0.descriptor.id) != .off }.count
    return "\(count) di \(model.registry.entries.count) accesi"
  }
}

/// Tile of a module: colored icon when on, gray when off.
private struct ModuleTile: View {
  let descriptor: ModuleDescriptor
  let name: String
  let state: ModuleState
  let action: () -> Void
  @State private var hovering = false

  private var isOn: Bool { state != .off }

  var body: some View {
    Button(action: action) {
      VStack(spacing: TsukumoTokens.Spacing.xs) {
        ModuleIcon(symbol: descriptor.symbol, color: isOn ? descriptor.tint.color : .gray, size: 30)
          .opacity(isOn ? 1 : 0.55)
          .overlay(alignment: .topTrailing) {
            if case .suspended = state {
              Circle().fill(.orange).frame(width: 9, height: 9).offset(x: 3, y: -3)
            }
          }
        Text(verbatim: name)
          .font(.caption)
          .lineLimit(2, reservesSpace: true)
          .multilineTextAlignment(.center)
          .foregroundStyle(isOn ? .primary : .secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, TsukumoTokens.Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: TsukumoTokens.Radius.card, style: .continuous)
          .fill(.primary.opacity(isOn ? 0.1 : (hovering ? 0.07 : 0.04)))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .disabled(state == .starting)
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityValue(Text(isOn ? "Running" : "Off"))
    .help(Text(isOn ? "Spegni \(name)" : "Accendi \(name)"))
  }
}

/// Action row in the panel, with hover highlight as in menus.
private struct ActionRow: View {
  let title: Text
  let symbol: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: TsukumoTokens.Spacing.sm) {
        Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
        title
        Spacer(minLength: 0)
      }
      .padding(.horizontal, TsukumoTokens.Spacing.xs)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: TsukumoTokens.Radius.control, style: .continuous)
          .fill(hovering ? Color.primary.opacity(0.08) : .clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
