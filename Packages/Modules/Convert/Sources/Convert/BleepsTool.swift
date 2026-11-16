// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import SwiftUI

/// An interval to censor, in seconds.
struct BleepRange: Equatable, Identifiable, Sendable {
  let id: UUID
  var start: Double
  var end: Double
}

/// The censor intervals of a file: sorted, never overlapping, within the duration and at least
/// `minimumDuration` long. Pure logic, no I/O.
struct BleepRanges: Equatable, Sendable {
  static let minimumDuration = 0.05

  let duration: Double
  private(set) var items: [BleepRange] = []

  init(duration: Double) { self.duration = max(0, duration) }

  var count: Int { items.count }

  /// Adds an interval (the ends can be given in any order) and merges it with those it touches.
  /// Returns the identifier of the resulting interval, or `nil` if it is too short.
  @discardableResult
  mutating func add(from first: Double, to second: Double) -> UUID? {
    var low = max(0, min(first, second))
    var high = min(duration, max(first, second))
    guard high - low >= Self.minimumDuration else { return nil }
    var kept: [BleepRange] = []
    var inherited: UUID?
    for item in items {
      if item.end >= low && item.start <= high {
        low = min(low, item.start)
        high = max(high, item.end)
        inherited = inherited ?? item.id
      } else {
        kept.append(item)
      }
    }
    let merged = BleepRange(id: inherited ?? UUID(), start: low, end: high)
    kept.append(merged)
    items = kept.sorted { $0.start < $1.start }
    return merged.id
  }

  /// Moves an edge without leaving the duration, without crossing its neighbours and respecting the minimum duration.
  mutating func setEdge(of id: UUID, isStart: Bool, to time: Double) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let item = items[index]
    if isStart {
      let floor = index > 0 ? items[index - 1].end : 0
      items[index].start = min(max(time, floor), item.end - Self.minimumDuration)
    } else {
      let ceiling = index + 1 < items.count ? items[index + 1].start : duration
      items[index].end = max(min(time, ceiling), item.start + Self.minimumDuration)
    }
  }

  mutating func remove(id: UUID) {
    items.removeAll { $0.id == id }
  }

  func range(at time: Double) -> BleepRange? {
    items.first { $0.start <= time && time <= $0.end }
  }

  /// Intervals for rendering.
  var intervals: [ClosedRange<Double>] { items.map { $0.start...$0.end } }
}

/// Replaces the audio in the intervals with a 1 kHz sine tone (amplitude 0.5), with 5 ms fades.
enum BleepRenderer {
  static let frequency = 1000.0
  static let amplitude: Float = 0.5
  static let fadeSeconds = 0.005

  /// Tone value at absolute frame `frame` (the phase follows the frame, so there are no jumps between blocks).
  static func tone(atFrame frame: Int64, rate: Double) -> Float {
    amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / rate))
  }

  /// Weight of the bleep (0...1) at frame `frame` of an interval `first..<last`: rises and falls over `fade` frames.
  static func gain(atFrame frame: Int64, first: Int64, last: Int64, fade: Int64) -> Float {
    guard frame >= first, frame < last else { return 0 }
    let ramp = Float(max(1, fade))
    return min(1, Float(frame - first) / ramp, Float(last - frame) / ramp)
  }

  /// Applies the bleeps to the block, which starts at absolute frame `startFrame`. The block is modified in place.
  static func apply(to buffer: AVAudioPCMBuffer, startFrame: Int64, ranges: [ClosedRange<Double>]) {
    guard let data = buffer.floatChannelData else { return }
    let rate = buffer.format.sampleRate
    let frames = Int64(buffer.frameLength)
    let fade = Int64((fadeSeconds * rate).rounded())
    for range in ranges {
      let first = Int64((range.lowerBound * rate).rounded())
      let last = Int64((range.upperBound * rate).rounded())
      let low = max(first, startFrame)
      let high = min(last, startFrame + frames)
      guard low < high else { continue }
      for frame in low..<high {
        let index = Int(frame - startFrame)
        let weight = gain(atFrame: frame, first: first, last: last, fade: fade)
        let beep = tone(atFrame: frame, rate: rate) * weight
        for channel in 0..<Int(buffer.format.channelCount) {
          data[channel][index] = data[channel][index] * (1 - weight) + beep
        }
      }
    }
  }
}

extension AudioSupport {
  /// Writes the audio with the bleeps next to the original (`-bleeped` suffix).
  static func applyBleeps(source: URL, ranges: [ClosedRange<Double>]) throws -> URL {
    let file = try openFile(source)
    let ext = outputExtension(for: source)
    let destination = OutputNamer.url(for: source, extension: ext, suffix: "-bleeped")
    do {
      let settings = writerSettings(like: file, ext: ext, channels: Int(file.processingFormat.channelCount))
      let writer: AVAudioFile
      do {
        writer = try AVAudioFile(forWriting: destination, settings: settings)
      } catch {
        throw AudioToolError.unwritable(destination.lastPathComponent)
      }
      try renderBleeps(file: file, writer: writer, ranges: ranges)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return destination
  }

  /// Temporary file with the bleeps, to listen to them before applying.
  static func renderBleepsPreview(source: URL, ranges: [ClosedRange<Double>]) throws -> URL {
    let file = try openFile(source)
    let url = temporaryPreviewURL()
    do {
      let format = file.processingFormat
      let writer = try previewWriter(at: url, rate: format.sampleRate, channels: Int(format.channelCount))
      try renderBleeps(file: file, writer: writer, ranges: ranges)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    return url
  }

  private static func renderBleeps(file: AVAudioFile, writer: AVAudioFile, ranges: [ClosedRange<Double>]) throws {
    try process(source: file, writer: writer, range: 0..<file.length) { input, output, start in
      copyChannels(input, to: output)
      BleepRenderer.apply(to: output, startFrame: start, ranges: ranges)
    }
  }
}

/// Bleep censoring: bleep lane, audio lane, preview and apply.
struct BleepsToolView: View {
  let context: ToolContext

  enum PreviewMode: Hashable { case original, bleeped }

  @State private var waveform: AudioWaveform?
  @State private var loadFailed = false
  @State private var ranges = BleepRanges(duration: 0)
  @State private var selection: UUID?
  @State private var mode = PreviewMode.bleeped
  @State private var player = AudioPreviewPlayer()

  private var source: URL? { context.files.first }

  var body: some View {
    VStack(spacing: 0) {
      content.padding(16)
      ToolFooter(context: context, canApply: !ranges.items.isEmpty, apply: apply)
    }
    .task(id: source, priority: .utility) { await load() }
    .onChange(of: ranges) { _, _ in player.stop() }
    .onDisappear { player.stop() }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Drag on the Bleep lane to censor a range").foregroundStyle(.secondary)
        Spacer()
        Text("Bleeps: \(ranges.count)").monospacedDigit()
      }
      .font(.subheadline)

      lanes

      HStack {
        Picker("Preview", selection: $mode) {
          Text("Original").tag(PreviewMode.original)
          Text("With bleeps").tag(PreviewMode.bleeped)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 200)
        Button {
          togglePlayback()
        } label: {
          Label(player.isPlaying ? "Stop" : "Listen", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
        }
        .disabled(waveform == nil || player.isPreparing)
        if player.isPreparing { ProgressView().controlSize(.small) }
        Spacer()
        Button(role: .destructive) {
          deleteSelection()
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .disabled(selection == nil)
      }
      .buttonStyle(.glass)
      if let message = player.errorMessage {
        Text(message).font(.caption).foregroundStyle(.orange)
      }
      if context.files.count > 1, let source {
        Text("Bleeps apply to the first file only: \(source.lastPathComponent)")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private var lanes: some View {
    if let waveform {
      VStack(spacing: 8) {
        laneRow("Bleep") {
          BleepLaneView(ranges: $ranges, selection: $selection).frame(height: 40)
        }
        laneRow("Audio") {
          TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { _ in
            WaveformView(
              peaks: waveform.combined, duration: waveform.duration,
              playhead: player.isPlaying ? player.currentTime : nil
            )
            .overlay { BleepOverlay(ranges: ranges) }
          }
          .frame(height: 120)
        }
      }
    } else if loadFailed {
      ContentUnavailableView("Can't read the file", systemImage: "waveform.badge.exclamationmark")
        .frame(height: 170)
    } else {
      ProgressView().frame(maxWidth: .infinity).frame(height: 170)
    }
  }

  private func laneRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 8) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
      content()
    }
  }

  private func load() async {
    guard let source else { return }
    do {
      let result = try await AudioSupport.waveform(url: source)
      waveform = result
      ranges = BleepRanges(duration: result.duration)
      selection = nil
    } catch is CancellationError {
      return
    } catch {
      loadFailed = true
    }
  }

  private func deleteSelection() {
    guard let selection else { return }
    ranges.remove(id: selection)
    self.selection = nil
  }

  private func togglePlayback() {
    guard let source else { return }
    if player.isPlaying || player.isPreparing {
      player.stop()
      return
    }
    let begin = max(0, (ranges.items.first { $0.id == selection }?.start ?? 0) - 1)
    switch mode {
    case .original:
      player.play(url: source, from: begin, to: nil)
    case .bleeped:
      let intervals = ranges.intervals
      player.playRendered(from: begin, to: nil) {
        try AudioSupport.renderBleepsPreview(source: source, ranges: intervals)
      }
    }
  }

  private func apply() {
    guard let source else { return }
    player.stop()
    let intervals = ranges.intervals
    context.apply {
      let output = try AudioSupport.applyBleeps(source: source, ranges: intervals)
      return String(localized: "Saved \(output.lastPathComponent)")
    }
  }
}

/// Intervals drawn over the waveform, to see what will be replaced.
private struct BleepOverlay: View {
  let ranges: BleepRanges

  var body: some View {
    GeometryReader { proxy in
      ForEach(ranges.items) { item in
        let scale = ranges.duration > 0 ? proxy.size.width / CGFloat(ranges.duration) : 0
        Rectangle().fill(.orange.opacity(0.28))
          .frame(width: max(1, CGFloat(item.end - item.start) * scale))
          .offset(x: CGFloat(item.start) * scale)
      }
    }
    .allowsHitTesting(false)
  }
}

/// Bleep lane: drag on empty space to create one, on the edges to adjust it, a click selects it.
private struct BleepLaneView: View {
  @Binding var ranges: BleepRanges
  @Binding var selection: UUID?

  private enum DragMode {
    case create(origin: Double)
    case edge(id: UUID, isStart: Bool)
    case select(id: UUID)
  }

  @State private var dragMode: DragMode?
  @State private var pending: ClosedRange<Double>?
  @FocusState private var focused: Bool

  private let edgeTolerance: CGFloat = 7

  var body: some View {
    GeometryReader { proxy in
      let width = max(1, proxy.size.width)
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5))
        ForEach(ranges.items) { item in
          block(item.start, item.end, width: width, isSelected: item.id == selection, isPending: false)
        }
        if let pending {
          block(pending.lowerBound, pending.upperBound, width: width, isSelected: false, isPending: true)
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in dragChanged(value, width: width) }
          .onEnded { value in dragEnded(value, width: width) }
      )
      .focusable()
      .focused($focused)
      .focusEffectDisabled()
      .onKeyPress(keys: [.delete, .deleteForward]) { _ in
        guard let selection else { return .ignored }
        ranges.remove(id: selection)
        self.selection = nil
        return .handled
      }
    }
  }

  private func block(_ start: Double, _ end: Double, width: CGFloat, isSelected: Bool, isPending: Bool) -> some View {
    let scale = ranges.duration > 0 ? width / CGFloat(ranges.duration) : 0
    return RoundedRectangle(cornerRadius: 5, style: .continuous)
      .fill(.orange.opacity(isPending ? 0.35 : 0.65))
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(isSelected ? Color.white : Color.orange, lineWidth: isSelected ? 2 : 1)
      }
      .frame(width: max(2, CGFloat(end - start) * scale))
      .offset(x: CGFloat(start) * scale)
      .padding(.vertical, 4)
      .allowsHitTesting(false)
  }

  private func time(at xPosition: CGFloat, width: CGFloat) -> Double {
    Double(min(max(0, xPosition), width) / width) * ranges.duration
  }

  private func startMode(at xPosition: CGFloat, width: CGFloat) -> DragMode {
    let scale = ranges.duration > 0 ? width / CGFloat(ranges.duration) : 0
    for item in ranges.items {
      let startX = CGFloat(item.start) * scale
      let endX = CGFloat(item.end) * scale
      if abs(xPosition - startX) <= edgeTolerance { return .edge(id: item.id, isStart: true) }
      if abs(xPosition - endX) <= edgeTolerance { return .edge(id: item.id, isStart: false) }
      if xPosition > startX && xPosition < endX { return .select(id: item.id) }
    }
    return .create(origin: time(at: xPosition, width: width))
  }

  private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
    focused = true
    let mode = dragMode ?? startMode(at: value.startLocation.x, width: width)
    dragMode = mode
    let now = time(at: value.location.x, width: width)
    switch mode {
    case .create(let origin):
      pending = min(origin, now)...max(origin, now)
    case .edge(let id, let isStart):
      selection = id
      ranges.setEdge(of: id, isStart: isStart, to: now)
    case .select(let id):
      selection = id
    }
  }

  private func dragEnded(_ value: DragGesture.Value, width: CGFloat) {
    defer {
      dragMode = nil
      pending = nil
    }
    if case .create = dragMode, let pending {
      selection = ranges.add(from: pending.lowerBound, to: pending.upperBound)
    }
  }
}
