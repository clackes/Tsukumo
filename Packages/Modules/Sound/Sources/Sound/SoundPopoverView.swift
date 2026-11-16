// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import DesignSystem
import SwiftUI

/// Content of the menu bar item's popover.
struct SoundPopoverView: View {
  @Bindable var model: SoundModel

  var body: some View {
    VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.md) {
      PopoverHeader(Text("Sound"), symbol: "speaker.wave.2", tint: .pink)
      PopoverSection {
        volumeControl
      }
      PopoverSection(Text("Output")) {
        if model.devices.isEmpty {
          Text("No audio output.").foregroundStyle(.secondary)
        } else {
          ForEach(model.devices) { device in
            DeviceRow(device: device, isDefault: device.id == model.defaultID) { model.select(device) }
              .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
      }
      if !model.runningAudioProcesses.isEmpty || model.mixerBlocked {
        mixerSection.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
      }
    }
    // Outputs and apps that appear or disappear while the panel is open.
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.devices.map(\.id))
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.runningAudioProcesses.map(\.id))
    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.defaultID)
  }

  @ViewBuilder private var mixerSection: some View {
    PopoverSection(Text("Apps playing audio")) {
      ForEach(model.runningAudioProcesses) { process in
        ProcessRow(
          process: process,
          volume: model.processVolume(for: process),
          canWrite: model.mixerAvailable,
          outputs: model.devices,
          currentOutputUID: model.processOutputUID(for: process),
          onChange: { model.setProcessVolume($0, for: process) },
          onOutput: { model.setProcessOutput($0, for: process) }
        )
        .transition(.opacity.combined(with: .move(edge: .leading)))
      }
      if model.mixerBlocked {
        Label(
          "Requires the System Audio Recording permission in System Settings > Privacy & Security.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
  }

  @ViewBuilder private var volumeControl: some View {
    if let volume = model.volume {
      HStack(spacing: TsukumoTokens.Spacing.sm) {
        Button {
          model.toggleMute()
        } label: {
          // The speaker waves follow the level; mute comes in with a morph.
          Image(systemName: model.isMuted == true ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: volume)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: model.isMuted)
            .frame(width: 22)
        }
        .buttonStyle(.plain)
        .disabled(model.isMuted == nil)
        .accessibilityLabel(Text("Mute"))
        Slider(value: Binding(get: { volume }, set: { model.setVolume($0) }), in: 0...1)
          .accessibilityLabel(Text("Volume"))
        Text(verbatim: "\(VolumeScale.percent(volume))%")
          .monospacedDigit()
          .contentTransition(.numericText())
          .animation(.snappy(duration: 0.2), value: VolumeScale.percent(volume))
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
    } else if model.defaultID != nil {
      Text("This output has no adjustable volume").font(.callout).foregroundStyle(.secondary)
    }
  }
}

private struct ProcessRow: View {
  let process: AudioProcess
  let volume: Double
  let canWrite: Bool
  let outputs: [AudioOutputDevice]
  let currentOutputUID: String?
  let onChange: (Double) -> Void
  let onOutput: (AudioOutputDevice?) -> Void

  var body: some View {
    HStack(spacing: TsukumoTokens.Spacing.sm) {
      icon.frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: process.name).lineLimit(1)
        if canWrite {
          Slider(value: Binding(get: { volume }, set: { onChange($0) }), in: 0...1)
            .controlSize(.mini)
            .accessibilityLabel(Text("Volume for \(process.name)"))
        }
      }
      Spacer(minLength: 0)
      if canWrite {
        Text(verbatim: "\(VolumeScale.percent(volume))%")
          .monospacedDigit()
          .contentTransition(.numericText())
          .animation(.snappy(duration: 0.2), value: VolumeScale.percent(volume))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(width: 32, alignment: .trailing)
        outputMenu
      } else {
        Image(systemName: "speaker.wave.2").foregroundStyle(.tertiary).imageScale(.small)
      }
    }
    .padding(.horizontal, TsukumoTokens.Spacing.sm)
    .padding(.vertical, TsukumoTokens.Spacing.xs)
  }

  @ViewBuilder private var outputMenu: some View {
    Menu {
      Button {
        onOutput(nil)
      } label: {
        Label("System Output", systemImage: currentOutputUID == nil ? "checkmark" : "")
      }
      if !outputs.isEmpty { Divider() }
      ForEach(outputs) { device in
        Button {
          onOutput(device)
        } label: {
          Label(device.name, systemImage: currentOutputUID == device.uid ? "checkmark" : device.kind.symbol)
        }
      }
    } label: {
      Image(systemName: currentOutputUID == nil ? "arrow.right" : "arrow.right.circle.fill")
        .font(.caption)
        .foregroundStyle(currentOutputUID == nil ? Color.secondary : Color.accentColor)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(Text("Output for \(process.name)"))
  }

  @ViewBuilder private var icon: some View {
    if let nsImage = AudioProcessIcon.image(for: process) {
      Image(nsImage: nsImage).resizable().scaledToFit()
    } else {
      Image(systemName: "waveform").foregroundStyle(.secondary)
    }
  }
}

private struct DeviceRow: View {
  let device: AudioOutputDevice
  let isDefault: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: TsukumoTokens.Spacing.sm) {
        Image(systemName: device.kind.symbol).frame(width: 22).foregroundStyle(.secondary)
        Text(verbatim: device.name).lineLimit(1)
        Spacer(minLength: 0)
        if isDefault {
          Image(systemName: "checkmark").foregroundStyle(.tint)
            .transition(.scale(scale: 0.2).combined(with: .opacity))
        }
      }
      .padding(.horizontal, TsukumoTokens.Spacing.sm)
      .padding(.vertical, TsukumoTokens.Spacing.xs)
      .modifier(HoverHighlight())
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isDefault ? .isSelected : [])
  }
}
