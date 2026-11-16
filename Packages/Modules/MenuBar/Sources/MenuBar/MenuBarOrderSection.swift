// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI

/// App icons, kept aside: looking them up in LaunchServices on every redraw
/// of a row was part of the stall felt at every move.
@MainActor
enum MenuBarIconCache {
  private static var icons: [String: NSImage] = [:]

  static func icon(forBundleID bundleID: String) -> NSImage? {
    if let cached = icons[bundleID] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    icons[bundleID] = icon
    return icon
  }
}

/// The "Icon order" and "Hidden icons" sections. They are a separate view
/// because at every move only the order state changes: this way SwiftUI
/// recomputes these rows and not the whole page.
struct MenuBarOrderSection: View {
  let order: MenuBarOrderModel?

  var body: some View {
    Section {
      if let order, !order.hasAccessibility {
        Text("To move icons, Tsukumo needs Accessibility access.")
          .foregroundStyle(.secondary)
        Button("Open Accessibility") {
          if let url = PermissionBroker.settingsURL(for: .accessibility) { NSWorkspace.shared.open(url) }
        }
      } else if let order {
        if order.items.isEmpty {
          Text("No icons found in the menu bar.").foregroundStyle(.secondary)
        }
        ForEach(Array(order.items.enumerated()), id: \.element.id) { index, item in
          row(item, index: index, order: order)
        }
        if let message = order.message {
          Text(message).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Icon Order")
    } footer: {
      Text("Left to right, as they are in the bar now. The clock always stays last.")
    }
    if let order, !order.hiddenItems.isEmpty {
      Section {
        ForEach(order.hiddenItems) { item in
          HStack(spacing: TsukumoTokens.Spacing.sm) {
            MenuBarItemIcon(item: item)
            Text(verbatim: item.title).lineLimit(1).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "eye.slash").foregroundStyle(.tertiary)
          }
        }
      } header: {
        Text("Hidden Icons")
      } footer: {
        Text("To move them, first reveal them with the arrow in the bar.")
      }
    }
  }

  private func row(_ item: MenuBarItemSlot, index: Int, order: MenuBarOrderModel) -> some View {
    HStack(spacing: TsukumoTokens.Spacing.sm) {
      MenuBarItemIcon(item: item)
      Text(verbatim: item.title).lineLimit(1)
      Spacer()
      Button {
        Task { await order.move(item.id, by: -1) }
      } label: {
        Image(systemName: "chevron.left")
      }
      .disabled(index == 0 || order.isMoving)
      .help(Text("Move Left"))
      .accessibilityLabel(Text("Move Left"))
      Button {
        Task { await order.move(item.id, by: 1) }
      } label: {
        Image(systemName: "chevron.right")
      }
      .disabled(index == order.items.count - 1 || order.isMoving)
      .help(Text("Move Right"))
      .accessibilityLabel(Text("Move Right"))
    }
    .buttonStyle(.borderless)
  }
}

/// Icon of a row: the app's, or a symbol for system icons.
struct MenuBarItemIcon: View {
  let item: MenuBarItemSlot

  var body: some View {
    if let bundleID = item.bundleID, let icon = MenuBarIconCache.icon(forBundleID: bundleID) {
      Image(nsImage: icon).resizable().frame(width: 20, height: 20)
    } else {
      Image(systemName: item.symbol ?? "app.dashed").frame(width: 20, height: 20)
    }
  }
}
