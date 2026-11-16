// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI

/// Onboarding window (DESIGN.md §6.1): first the preset choice, then
/// a single page with all permissions of all modules. `AppDelegate` opens it
/// on first launch if `OnboardingStore.load().shouldShow`; from
/// Settings it can be reopened directly on the permissions page.
@MainActor
final class OnboardingWindowController {
  enum Step {
    case presets, permissions
  }

  /// Outcome: the chosen preset (`nil` for "Customize" or when only the permissions
  /// are reviewed) and whether a relaunch is needed for the newly granted permissions to apply.
  struct Outcome {
    var preset: ModulePreset?
    var needsRestart: Bool
  }

  private var window: NSWindow?
  private let model: AppModel
  private let onComplete: @MainActor (Outcome) -> Void

  init(model: AppModel, onComplete: @escaping @MainActor (Outcome) -> Void) {
    self.model = model
    self.onComplete = onComplete
  }

  func show(startingAt step: Step = .presets) {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate()
      return
    }
    let view = OnboardingView(model: model, step: step) { [weak self] outcome in
      self?.close()
      self?.onComplete(outcome)
    }
    let hosting = NSHostingController(rootView: view)
    hosting.sizingOptions = [.preferredContentSize]
    let window = NSWindow(contentViewController: hosting)
    window.title = String(localized: "Benvenuto in Tsukumo")
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.center()
    self.window = window
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  func close() {
    window?.close()
    window = nil
  }
}

/// The two onboarding pages, one at a time.
private struct OnboardingView: View {
  let model: AppModel
  @State var step: OnboardingWindowController.Step
  let onComplete: (OnboardingWindowController.Outcome) -> Void
  @State private var preset: ModulePreset?

  var body: some View {
    switch step {
    case .presets:
      PresetsView { chosen in
        preset = chosen
        step = .permissions
      }
    case .permissions:
      OnboardingPermissionsView(model: model) { needsRestart in
        onComplete(.init(preset: preset, needsRestart: needsRestart))
      }
    }
  }
}

/// Main view: title + three preset cards. No notch animation
/// for now (it will come when the app icon is ready): the DESIGN mentions it
/// as desirable but not blocking.
private struct PresetsView: View {
  let onChoose: (ModulePreset?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.lg) {
      header
      presets
      footer
    }
    .padding(TsukumoTokens.Spacing.xl)
    .frame(width: 620)
  }

  @ViewBuilder private var header: some View {
    VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.sm) {
      Text("Tsukumo").font(.largeTitle).bold()
      Text("One app instead of ten. Turn on only what you need.")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text(
        "No account, no tracking. In the next step you grant permissions, just once."
      )
      .font(.callout)
      .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder private var presets: some View {
    VStack(spacing: TsukumoTokens.Spacing.md) {
      ForEach(OnboardingPresets.all) { preset in
        PresetCard(preset: preset) {
          onChoose(preset.id == OnboardingPresets.personalizza.id ? nil : preset)
        }
      }
    }
  }

  @ViewBuilder private var footer: some View {
    HStack {
      Spacer()
      Button("Skip for Now") { onChoose(nil) }
        .buttonStyle(.link)
    }
  }
}

private struct PresetCard: View {
  let preset: ModulePreset
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: TsukumoTokens.Spacing.md) {
        Image(systemName: preset.symbol)
          .font(.title2)
          .frame(width: 44, height: 44)
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: preset.title).font(.headline)
          Text(verbatim: preset.detail)
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
      }
      .padding(TsukumoTokens.Spacing.md)
      .background(
        RoundedRectangle(cornerRadius: TsukumoTokens.Radius.card, style: .continuous)
          .fill(hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
      )
      .overlay(
        RoundedRectangle(cornerRadius: TsukumoTokens.Radius.card, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
