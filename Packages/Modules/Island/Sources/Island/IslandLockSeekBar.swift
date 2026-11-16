// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Progress bar with a drag point. Shows the real progress
/// (updated by the system while playing) and, during dragging,
/// the chosen position; on release it calls `onSeek`.
struct LockSeekBar: View {
  /// Jump for each increment/decrement action of VoiceOver.
  static let accessibilityStep: TimeInterval = 10
  static let trackHeight: CGFloat = 4
  static let activeTrackHeight: CGFloat = 6

  let media: NowPlaying
  let duration: TimeInterval
  let onSeek: (TimeInterval) -> Void
  @State private var dragFraction: Double?

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      ZStack(alignment: .leading) {
        if let dragFraction {
          bar(fraction: dragFraction, width: width, active: true)
        } else if let interval = media.progressInterval {
          // While playing the progress is animated by Core Animation, without timers of ours
          // and without SwiftUI redraws: same capsule and same thickness as the
          // other states (pause and dragging).
          LiveProgressBar(interval: interval)
            .frame(height: Self.trackHeight)
            .clipShape(Capsule())
        } else {
          bar(fraction: Self.fraction(position: media.position ?? 0, duration: duration), width: width, active: false)
        }
      }
      .frame(height: proxy.size.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in dragFraction = min(max(value.location.x / width, 0), 1) }
          .onEnded { value in
            let fraction = min(max(value.location.x / width, 0), 1)
            dragFraction = nil
            onSeek(fraction * duration)
          }
      )
    }
    .frame(height: 18)
    .accessibilityElement()
    .accessibilityLabel(Text("Track position"))
    .accessibilityValue(Text(verbatim: Self.accessibilityValue(media: media, duration: duration, now: Date())))
    .accessibilityAdjustableAction { direction in
      let current = Self.position(of: media, at: Date(), duration: duration)
      switch direction {
      case .increment: onSeek(Self.seekTarget(from: current, by: Self.accessibilityStep, duration: duration))
      case .decrement: onSeek(Self.seekTarget(from: current, by: -Self.accessibilityStep, duration: duration))
      @unknown default: break
      }
    }
  }

  private func bar(fraction: Double, width: CGFloat, active: Bool) -> some View {
    let height = active ? Self.activeTrackHeight : Self.trackHeight
    return ZStack(alignment: .leading) {
      Capsule().fill(.white.opacity(0.25)).frame(height: height)
      Capsule().fill(.white).frame(width: width * fraction, height: height)
    }
  }

  static func fraction(position: TimeInterval, duration: TimeInterval) -> Double {
    guard duration > 0 else { return 0 }
    return min(max(position / duration, 0), 1)
  }

  /// Position at time `now`: if playing it advances from the instant of the last update.
  static func position(of media: NowPlaying, at now: Date, duration: TimeInterval) -> TimeInterval {
    var position = media.position ?? 0
    if media.isPlaying { position += max(now.timeIntervalSince(media.updatedAt), 0) }
    return min(max(position, 0), duration)
  }

  static func seekTarget(from position: TimeInterval, by delta: TimeInterval, duration: TimeInterval) -> TimeInterval {
    min(max(position + delta, 0), duration)
  }

  /// Text for VoiceOver, for example "1:05 of 3:30".
  static func accessibilityValue(media: NowPlaying, duration: TimeInterval, now: Date) -> String {
    let elapsed = LockMediaCardView.format(position(of: media, at: now, duration: duration))
    return "\(elapsed) of \(LockMediaCardView.format(duration))"
  }
}
