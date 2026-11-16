// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import DesignSystem
import ModuleKit
import SwiftUI

extension SnapAction {
  var title: LocalizedStringKey {
    switch self {
    case .leftHalf: "Left Half"
    case .rightHalf: "Right Half"
    case .topHalf: "Top Half"
    case .bottomHalf: "Bottom Half"
    case .topLeft: "Top Left"
    case .topRight: "Top Right"
    case .bottomLeft: "Bottom Left"
    case .bottomRight: "Bottom Right"
    case .maximize: "Maximize"
    case .center: "Center"
    case .restore: "Restore"
    }
  }
}

@MainActor
struct SnapSettingsView: View {
  let model: SnapModel?
  let module: SnapModule

  private static let dragHint: LocalizedStringKey =
    "Drag a window to a side for a half, to a corner for a quarter, to the top to maximize."
  private static let nativeTilingNote: LocalizedStringKey =
    "macOS edge tiling is also on and overlaps with this one: turn it off in Desktop & Dock."

  var body: some View {
    Form {
      Section {
        Toggle(
          "Snap by dragging to screen edges",
          isOn: Binding(
            get: { model?.dragEnabled ?? false },
            set: { module.setDragEnabled($0) }
          )
        )
      } footer: {
        VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.xs) {
          Text(Self.dragHint)
          if model?.nativeTilingEnabled == true {
            Text(Self.nativeTilingNote)
            Button("Open Desktop & Dock") { module.openNativeTilingSettings() }
              .buttonStyle(.link)
          }
        }
      }

      Section("Shortcuts") {
        ForEach(SnapAction.allCases, id: \.self) { action in
          VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.xs) {
            LabeledContent {
              HotkeyRecorder(
                hotkey: Binding(
                  get: { model?.hotkeys[action] },
                  set: { module.setHotkey($0, for: action) }
                ),
                onClear: { module.setHotkey(nil, for: action) }
              )
            } label: {
              Text(action.title)
            }
            if let error = model?.errors[action] {
              Text(error).font(.caption).foregroundStyle(.red)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text("Windows"))
    .disabled(model == nil)
    .onAppear { module.refreshNativeTiling() }
  }
}
