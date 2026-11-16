// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Audio trim: waveform with two handles, automatic silence trimming and listening.
struct TrimAudioToolView: View {
  let context: ToolContext

  @State private var waveform: AudioWaveform?
  @State private var loadFailed = false
  @State private var start = 0.0
  @State private var end = 0.0
  @State private var autoTrim = false
  @State private var savedSelection: ClosedRange<Double>?
  @State private var player = AudioPreviewPlayer()

  private var source: URL? { context.files.first }
  private var duration: Double { waveform?.duration ?? 0 }

  var body: some View {
    VStack(spacing: 0) {
      content.padding(16)
      ToolFooter(context: context, canApply: canApply, apply: apply)
    }
    .task(id: source, priority: .utility) { await load() }
    .onDisappear { player.stop() }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Drag the handles to trim").foregroundStyle(.secondary)
        Spacer()
        Text("\(AudioTime.format(end - start)) selected").monospacedDigit()
      }
      .font(.subheadline)

      wave.frame(height: 130)

      HStack {
        Text("Start \(AudioTime.format(start))")
        Spacer()
        Text("End \(AudioTime.format(end))")
      }
      .font(.system(.callout, design: .monospaced))

      Toggle("Automatically trim silence at the ends", isOn: $autoTrim)
        .disabled(waveform == nil)
        .onChange(of: autoTrim) { _, isOn in applyAutoTrim(isOn) }

      HStack {
        Button {
          togglePlayback()
        } label: {
          Label(
            player.isPlaying ? "Stop" : "Listen to the selection",
            systemImage: player.isPlaying ? "stop.fill" : "play.fill")
        }
        .disabled(waveform == nil)
        if let message = player.errorMessage {
          Text(message).font(.caption).foregroundStyle(.orange)
        }
      }
      .buttonStyle(.glass)

      if context.files.count > 1, let source {
        Text("Trimming applies to the first file only: \(source.lastPathComponent)")
          .font(.caption).foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private var wave: some View {
    if let waveform {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { _ in
        WaveformView(
          peaks: waveform.combined, duration: waveform.duration,
          handles: (start: $start, end: $end),
          playhead: player.isPlaying ? player.currentTime : nil)
      }
    } else if loadFailed {
      ContentUnavailableView("Can't read the file", systemImage: "waveform.badge.exclamationmark")
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var canApply: Bool { waveform != nil && end - start >= WaveformView.minimumGap }

  private func load() async {
    guard let source else { return }
    do {
      let result = try await AudioSupport.waveform(url: source)
      waveform = result
      start = 0
      end = result.duration
    } catch is CancellationError {
      return
    } catch {
      loadFailed = true
    }
  }

  private func applyAutoTrim(_ isOn: Bool) {
    guard let source, waveform != nil else { return }
    player.stop()
    if isOn {
      savedSelection = start...end
      Task {
        let found = try? await Task.detached(priority: .utility) {
          try AudioSupport.nonSilentRange(url: source)
        }.value
        guard autoTrim, let found else { return }
        start = max(start, found.lowerBound)
        end = min(end, found.upperBound)
      }
    } else if let savedSelection {
      start = savedSelection.lowerBound
      end = savedSelection.upperBound
    }
  }

  private func togglePlayback() {
    guard let source else { return }
    if player.isPlaying {
      player.stop()
    } else {
      player.play(url: source, from: start, to: end)
    }
  }

  private func apply() {
    guard let source else { return }
    player.stop()
    let range = (start: start, end: end)
    context.apply {
      let output = try await AudioSupport.trim(source: source, start: range.start, end: range.end)
      return String(localized: "Saved \(output.lastPathComponent)")
    }
  }
}
