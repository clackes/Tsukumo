// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Track progress while playing: a capsule that grows until the end.
///
/// Takes the place of `ProgressView(timerInterval:)`, which SwiftUI updates on
/// every frame, redoing the layout of the whole panel (open island and
/// lock screen, Docs/PERF.md). Here there is a single linear `CABasicAnimation`
/// up to the end of the track, computed by the render server.
struct LiveProgressBar: NSViewRepresentable {
  let interval: ClosedRange<Date>
  var trackOpacity: CGFloat = 0.25

  func makeNSView(context: Context) -> LiveProgressView { LiveProgressView() }

  func updateNSView(_ view: LiveProgressView, context: Context) {
    view.trackOpacity = trackOpacity
    view.interval = interval
  }
}

@MainActor
final class LiveProgressView: NSView {
  static let animationKey = "tsukumo.progress"

  var interval: ClosedRange<Date>? {
    didSet { if interval != oldValue { restart() } }
  }
  var trackOpacity: CGFloat = 0.25 {
    didSet { track.backgroundColor = NSColor.white.withAlphaComponent(trackOpacity).cgColor }
  }

  let track = CALayer()
  let fill = CALayer()
  private var laidOutSize = CGSize.zero

  init() {
    super.init(frame: .zero)
    layer = CALayer()
    wantsLayer = true
    track.backgroundColor = NSColor.white.withAlphaComponent(trackOpacity).cgColor
    track.masksToBounds = true
    fill.backgroundColor = NSColor.white.cgColor
    fill.anchorPoint = CGPoint(x: 0, y: 0.5)
    track.addSublayer(fill)
    layer?.addSublayer(track)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

  override func layout() {
    super.layout()
    guard bounds.size != laidOutSize else { return }
    laidOutSize = bounds.size
    restart()
  }

  /// Fraction elapsed at instant `now`, between 0 and 1.
  nonisolated static func fraction(of interval: ClosedRange<Date>, at now: Date) -> Double {
    let total = interval.upperBound.timeIntervalSince(interval.lowerBound)
    guard total > 0 else { return 1 }
    return min(max(now.timeIntervalSince(interval.lowerBound) / total, 0), 1)
  }

  private func restart() {
    let size = bounds.size
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    track.frame = CGRect(origin: .zero, size: size)
    track.cornerRadius = size.height / 2
    fill.cornerRadius = size.height / 2
    fill.removeAnimation(forKey: Self.animationKey)
    guard let interval, size.width > 0 else {
      fill.bounds = CGRect(x: 0, y: 0, width: 0, height: size.height)
      return
    }
    let now = Date()
    let start = size.width * Self.fraction(of: interval, at: now)
    fill.position = CGPoint(x: 0, y: size.height / 2)
    fill.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    let remaining = interval.upperBound.timeIntervalSince(now)
    guard remaining > 0 else { return }
    let grow = CABasicAnimation(keyPath: "bounds.size.width")
    grow.fromValue = start
    grow.toValue = size.width
    grow.duration = remaining
    grow.timingFunction = CAMediaTimingFunction(name: .linear)
    grow.isRemovedOnCompletion = false
    fill.add(grow, forKey: Self.animationKey)
  }
}
