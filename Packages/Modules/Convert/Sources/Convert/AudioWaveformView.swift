// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Observation
import SwiftUI

/// Audio preview: the player exists only while listening, stops at the end of the selection,
/// when the panel closes and when the tool goes away. No timer: the end is a `Task`.
@MainActor
@Observable
final class AudioPreviewPlayer {
  private(set) var isPlaying = false
  private(set) var isPreparing = false
  private(set) var errorMessage: String?

  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var stopTask: Task<Void, Never>?
  @ObservationIgnored private var prepareTask: Task<Void, Never>?
  @ObservationIgnored private var temporaryURL: URL?

  /// Current position (seconds from the start of the file).
  var currentTime: Double { player?.currentTime ?? 0 }

  /// Plays `url` from `start` to `end` (to the end if `nil`).
  func play(url: URL, from start: Double, to end: Double?) {
    stop()
    begin(url: url, from: start, to: end)
  }

  /// Prepares a temporary file with `render` (off the main actor) and plays it; the file is deleted on stop.
  func playRendered(from start: Double, to end: Double?, render: @escaping @Sendable () async throws -> URL) {
    stop()
    isPreparing = true
    prepareTask = Task { [weak self] in
      do {
        let url = try await render()
        guard let self, !Task.isCancelled else {
          try? FileManager.default.removeItem(at: url)
          return
        }
        self.temporaryURL = url
        self.isPreparing = false
        self.begin(url: url, from: start, to: end)
      } catch is CancellationError {
        return
      } catch {
        self?.isPreparing = false
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func stop() {
    prepareTask?.cancel()
    prepareTask = nil
    stopTask?.cancel()
    stopTask = nil
    player?.stop()
    player = nil
    isPlaying = false
    isPreparing = false
    if let url = temporaryURL {
      try? FileManager.default.removeItem(at: url)
      temporaryURL = nil
    }
  }

  private func begin(url: URL, from start: Double, to end: Double?) {
    errorMessage = nil
    do {
      let audio = try AVAudioPlayer(contentsOf: url)
      let limit = min(end ?? audio.duration, audio.duration)
      audio.currentTime = max(0, min(start, limit))
      guard audio.play() else { throw AudioToolError.unreadable(url.lastPathComponent) }
      player = audio
      isPlaying = true
      let remaining = max(0.01, limit - audio.currentTime)
      stopTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled else { return }
        self?.stop()
      }
    } catch {
      errorMessage = error.localizedDescription
      stop()
    }
  }
}

/// Peak waveform, with red handles for the interval and a playback cursor.
/// Without `handles` it is drawing only.
struct WaveformView: View {
  let peaks: [Float]
  var tint: Color = .accentColor
  var duration: Double = 0
  var handles: (start: Binding<Double>, end: Binding<Double>)?
  var playhead: Double?

  static let minimumGap = 0.05
  private let handleWidth: CGFloat = 12

  var body: some View {
    GeometryReader { proxy in
      let width = max(1, proxy.size.width)
      ZStack(alignment: .topLeading) {
        WaveformCanvas(peaks: peaks, tint: tint)
        if let handles, duration > 0 {
          let startX = position(handles.start.wrappedValue, width: width)
          let endX = position(handles.end.wrappedValue, width: width)
          Rectangle().fill(.black.opacity(0.5)).frame(width: startX).allowsHitTesting(false)
          Rectangle().fill(.black.opacity(0.5)).frame(width: max(0, width - endX))
            .offset(x: endX).allowsHitTesting(false)
          handle(at: startX, height: proxy.size.height, width: width, isStart: true, handles: handles)
          handle(at: endX, height: proxy.size.height, width: width, isStart: false, handles: handles)
        }
        if let playhead, duration > 0 {
          Rectangle().fill(.white).frame(width: 1.5)
            .offset(x: position(playhead, width: width)).allowsHitTesting(false)
        }
      }
      .coordinateSpace(name: "waveform")
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func position(_ time: Double, width: CGFloat) -> CGFloat {
    guard duration > 0 else { return 0 }
    return CGFloat(min(1, max(0, time / duration))) * width
  }

  private func handle(
    at xPosition: CGFloat, height: CGFloat, width: CGFloat, isStart: Bool,
    handles: (start: Binding<Double>, end: Binding<Double>)
  ) -> some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(.red)
      .frame(width: 6, height: height)
      .frame(width: handleWidth, height: height)
      .contentShape(Rectangle())
      .offset(x: xPosition - handleWidth / 2)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("waveform"))
          .onChanged { value in
            let time = Double(min(max(0, value.location.x), width) / width) * duration
            if isStart {
              handles.start.wrappedValue = min(time, handles.end.wrappedValue - Self.minimumGap)
            } else {
              handles.end.wrappedValue = max(time, handles.start.wrappedValue + Self.minimumGap)
            }
          }
      )
      .accessibilityLabel(isStart ? Text("Start") : Text("End"))
  }
}

/// Drawing of the peaks only: bars mirrored about the central axis.
struct WaveformCanvas: View {
  let peaks: [Float]
  var tint: Color = .accentColor

  var body: some View {
    Canvas { context, size in
      guard !peaks.isEmpty else { return }
      let step = size.width / CGFloat(peaks.count)
      let mid = size.height / 2
      var path = Path()
      for (index, peak) in peaks.enumerated() {
        let half = max(1, CGFloat(peak) * (size.height / 2) * 0.92)
        let xPosition = (CGFloat(index) + 0.5) * step
        path.move(to: CGPoint(x: xPosition, y: mid - half))
        path.addLine(to: CGPoint(x: xPosition, y: mid + half))
      }
      context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: max(1, step * 0.7), lineCap: .round))
    }
    .accessibilityHidden(true)
  }
}
