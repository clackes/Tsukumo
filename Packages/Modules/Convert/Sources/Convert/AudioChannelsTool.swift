// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import SwiftUI

enum ChannelLayout: String, CaseIterable, Sendable {
  case mono, stereo

  var count: Int { self == .mono ? 1 : 2 }
  var suffix: String { self == .mono ? "-mono" : "-stereo" }
}

/// Per-channel levels and output layout. Pure logic, no I/O.
struct ChannelMix: Equatable, Sendable {
  var layout: ChannelLayout
  var left: Float
  var right: Float

  /// Mono: sum of the two channels with the levels, scaled back to 1 if the sum of the levels exceeds it (no clipping).
  var monoScale: Float { 1 / max(1, left + right) }

  /// Output value for a left and a right sample (output channel 0 or 1).
  func sample(left sampleLeft: Float, right sampleRight: Float, channel: Int) -> Float {
    switch layout {
    case .mono: (left * sampleLeft + right * sampleRight) * monoScale
    case .stereo: channel == 0 ? left * sampleLeft : right * sampleRight
    }
  }

  /// Applies the mix: `input` has one or more channels (a mono duplicates its single channel), `output` has `layout.count`.
  func apply(input: AVAudioPCMBuffer, output: AVAudioPCMBuffer) {
    guard let source = input.floatChannelData, let target = output.floatChannelData else { return }
    let frames = Int(min(input.frameLength, output.frameLength))
    let available = Int(input.format.channelCount)
    let sourceLeft = source[0]
    let sourceRight = source[available > 1 ? 1 : 0]
    for channel in 0..<layout.count {
      let destination = target[channel]
      for index in 0..<frames {
        destination[index] = sample(left: sourceLeft[index], right: sourceRight[index], channel: channel)
      }
    }
  }

  /// Peaks of the two output channels, derived from the source peaks (for the preview).
  func previewPeaks(of waveform: AudioWaveform) -> (left: [Float], right: [Float]) {
    let sourceLeft = waveform.channel(0)
    let sourceRight = waveform.channel(1)
    switch layout {
    case .stereo:
      return (sourceLeft.map { min(1, $0 * left) }, sourceRight.map { min(1, $0 * right) })
    case .mono:
      let mixed = zip(sourceLeft, sourceRight).map { min(1, ($0 * left + $1 * right) * monoScale) }
      return (mixed, mixed)
    }
  }
}

extension AudioSupport {
  /// Writes `source` in the chosen layout next to the original (`-mono` or `-stereo`).
  static func convertChannels(source: URL, mix: ChannelMix) throws -> URL {
    let file = try openFile(source)
    let ext = outputExtension(for: source)
    let destination = OutputNamer.url(for: source, extension: ext, suffix: mix.layout.suffix)
    do {
      let settings = writerSettings(like: file, ext: ext, channels: mix.layout.count)
      let writer: AVAudioFile
      do {
        writer = try AVAudioFile(forWriting: destination, settings: settings)
      } catch {
        throw AudioToolError.unwritable(destination.lastPathComponent)
      }
      try process(source: file, writer: writer, range: 0..<file.length) { input, output, _ in
        mix.apply(input: input, output: output)
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return destination
  }

  /// Temporary file with the output, to listen to it before applying.
  static func renderChannelsPreview(source: URL, mix: ChannelMix) throws -> URL {
    let file = try openFile(source)
    let url = temporaryPreviewURL()
    do {
      let writer = try previewWriter(at: url, rate: file.processingFormat.sampleRate, channels: mix.layout.count)
      try process(source: file, writer: writer, range: 0..<file.length) { input, output, _ in
        mix.apply(input: input, output: output)
      }
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    return url
  }
}

/// Mono/stereo conversion with per-channel levels.
struct AudioChannelsToolView: View {
  let context: ToolContext

  @State private var waveform: AudioWaveform?
  @State private var loadFailed = false
  @State private var layout = ChannelLayout.stereo
  @State private var left = 1.0
  @State private var right = 1.0
  @State private var player = AudioPreviewPlayer()

  private var source: URL? { context.files.first }
  private var mix: ChannelMix { ChannelMix(layout: layout, left: Float(left), right: Float(right)) }

  var body: some View {
    VStack(spacing: 0) {
      content.padding(16)
      ToolFooter(context: context, canApply: waveform != nil, apply: apply)
    }
    .task(id: source, priority: .utility) { await load() }
    .onDisappear { player.stop() }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Preview of the output channels").font(.subheadline).foregroundStyle(.secondary)
      lanes.frame(height: 150)

      Picker("Channels", selection: $layout) {
        Text("Mono").tag(ChannelLayout.mono)
        Text("Stereo").tag(ChannelLayout.stereo)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .onChange(of: layout) { _, _ in player.stop() }

      levelRow("Left (L)", value: $left)
      levelRow("Right (R)", value: $right)

      HStack {
        Button {
          togglePlayback()
        } label: {
          Label(
            player.isPlaying ? "Stop" : "Listen to the output",
            systemImage: player.isPlaying ? "stop.fill" : "play.fill")
        }
        .disabled(waveform == nil || player.isPreparing)
        if player.isPreparing { ProgressView().controlSize(.small) }
        if let message = player.errorMessage {
          Text(message).font(.caption).foregroundStyle(.orange)
        }
      }
      .buttonStyle(.glass)

      if context.files.count > 1 {
        Text("Settings apply to all \(context.files.count) files").font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private var lanes: some View {
    if let waveform {
      let peaks = mix.previewPeaks(of: waveform)
      VStack(spacing: 8) {
        lane("L", peaks: peaks.left, tint: .blue)
        lane("R", peaks: peaks.right, tint: .pink)
      }
    } else if loadFailed {
      ContentUnavailableView("Can't read the file", systemImage: "waveform.badge.exclamationmark")
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func lane(_ title: String, peaks: [Float], tint: Color) -> some View {
    HStack(spacing: 8) {
      Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 14)
      WaveformCanvas(peaks: peaks, tint: tint)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }

  private func levelRow(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
    HStack {
      Text(title).frame(width: 100, alignment: .leading)
      Slider(value: value, in: 0...1)
      Text(verbatim: "\(Int((value.wrappedValue * 100).rounded()))%")
        .monospacedDigit().frame(width: 44, alignment: .trailing)
    }
  }

  private func load() async {
    guard let source else { return }
    do {
      waveform = try await AudioSupport.waveform(url: source)
    } catch is CancellationError {
      return
    } catch {
      loadFailed = true
    }
  }

  private func togglePlayback() {
    guard let source else { return }
    if player.isPlaying || player.isPreparing {
      player.stop()
      return
    }
    let current = mix
    player.playRendered(from: 0, to: nil) {
      try AudioSupport.renderChannelsPreview(source: source, mix: current)
    }
  }

  private func apply() {
    player.stop()
    let files = context.files
    let current = mix
    context.apply {
      var created: [URL] = []
      for file in files {
        created.append(try AudioSupport.convertChannels(source: file, mix: current))
      }
      if let only = created.first, created.count == 1 {
        return String(localized: "Saved \(only.lastPathComponent)")
      }
      return String(localized: "Saved \(created.count) files")
    }
  }
}
