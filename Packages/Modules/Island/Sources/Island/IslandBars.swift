// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// How the island signals playing music next to the artwork.
public enum IslandPlaybackIndicator: String, Codable, Sendable, CaseIterable {
  /// The `waveform` symbol with the bars lighting up in turn.
  case waveform
  /// Five bars in the artwork's colors, like the open island's equalizer.
  case bars
  /// The still symbol: no animation.
  case still
}

/// Bars animated by Core Animation (DESIGN.md §5.1, §5.2).
///
/// The animations are infinite `CAKeyframeAnimation`s: the render
/// server computes them while the process and SwiftUI stay idle. With `symbolEffect` or
/// `TimelineView` SwiftUI redid the island's layout and rendering on every
/// frame, artwork blur included (Docs/PERF.md, scenario 4).
struct IslandBars: NSViewRepresentable {
  enum Style: Equatable {
    case waveform
    case equalizer(colors: [NSColor])
  }

  var style: Style
  var isPlaying: Bool

  func makeNSView(context: Context) -> IslandBarsView { IslandBarsView() }

  func updateNSView(_ view: IslandBarsView, context: Context) {
    view.configure(style: style, isPlaying: isPlaying)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: IslandBarsView, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }
}

@MainActor
final class IslandBarsView: NSView {
  private var style: IslandBars.Style?
  private var isPlaying = false
  private var bars: [CALayer] = []
  private var size = CGSize.zero

  init() {
    super.init(frame: .zero)
    // View hosting the layer: the sublayers are ours and AppKit does not touch them.
    layer = CALayer()
    wantsLayer = true
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

  override var intrinsicContentSize: NSSize { size }
  override var isFlipped: Bool { true }

  func configure(style: IslandBars.Style, isPlaying: Bool) {
    if style != self.style {
      self.style = style
      rebuild()
      self.isPlaying = !isPlaying  // forces the animations to refresh
    }
    guard isPlaying != self.isPlaying else { return }
    self.isPlaying = isPlaying
    updateMotion()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    // The wave glyph must be redrawn at the new screen's density.
    if case .waveform = style {
      rebuild()
      updateMotion()
    }
  }

  // MARK: Construction

  private func rebuild() {
    bars.forEach { $0.removeFromSuperlayer() }
    bars = []
    switch style {
    case .waveform: buildWaveform()
    case .equalizer(let colors): buildEqualizer(colors: colors)
    case nil: size = .zero
    }
    invalidateIntrinsicContentSize()
  }

  private func buildEqualizer(colors: [NSColor]) {
    let geometry = BarsMath.Equalizer.self
    size = CGSize(width: geometry.width, height: geometry.maxHeight)
    for index in 0..<geometry.bars {
      let bar = CALayer()
      bar.backgroundColor = BarsMath.Equalizer.color(at: index, of: colors).cgColor
      bar.cornerRadius = geometry.barWidth / 2
      bar.bounds = CGRect(x: 0, y: 0, width: geometry.barWidth, height: geometry.minHeight)
      bar.position = CGPoint(x: geometry.centerX(of: index), y: geometry.maxHeight / 2)
      bar.actions = ["bounds": NSNull(), "position": NSNull()]
      layer?.addSublayer(bar)
      bars.append(bar)
    }
  }

  private func buildWaveform() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    guard let glyph = WaveformGlyph.render(pointSize: 12, scale: scale) else {
      size = .zero
      return
    }
    size = glyph.size
    let pixelWidth = CGFloat(glyph.image.width)
    for run in glyph.columns {
      let bar = CALayer()
      bar.contents = glyph.image
      bar.contentsScale = scale
      bar.contentsRect = CGRect(
        x: CGFloat(run.lowerBound) / pixelWidth, y: 0, width: CGFloat(run.count) / pixelWidth, height: 1)
      bar.frame = CGRect(
        x: CGFloat(run.lowerBound) / scale, y: 0, width: CGFloat(run.count) / scale, height: glyph.size.height)
      bar.actions = ["opacity": NSNull()]
      layer?.addSublayer(bar)
      bars.append(bar)
    }
  }

  // MARK: Motion

  private func updateMotion() {
    guard let layer else { return }
    let now = layer.convertTime(CACurrentMediaTime(), from: nil)
    switch style {
    case .equalizer:
      for (index, bar) in bars.enumerated() {
        bar.removeAnimation(forKey: BarsMath.animationKey)
        if isPlaying {
          bar.add(
            BarsMath.Equalizer.animation(index: index, now: Date().timeIntervalSinceReferenceDate),
            forKey: BarsMath.animationKey)
        } else {
          // When paused the bars drop to the minimum, like in the SwiftUI version.
          let rest = CABasicAnimation(keyPath: "bounds.size.height")
          rest.fromValue = bar.presentation()?.bounds.height ?? bar.bounds.height
          rest.toValue = BarsMath.Equalizer.minHeight
          rest.duration = 0.25
          rest.timingFunction = CAMediaTimingFunction(name: .easeOut)
          bar.add(rest, forKey: "rest")
        }
      }
    case .waveform:
      for (index, bar) in bars.enumerated() {
        bar.removeAnimation(forKey: BarsMath.animationKey)
        guard isPlaying else { continue }
        let animation = BarsMath.Waveform.animation(index: index, of: bars.count)
        animation.beginTime = now
        bar.add(animation, forKey: BarsMath.animationKey)
      }
    case nil:
      break
    }
  }
}

/// Bar math, kept separate from the views for tests.
enum BarsMath {
  static let animationKey = "tsukumo.bars"

  enum Equalizer {
    static let bars = 5
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 14
    static let speeds: [Double] = [5.1, 7.3, 4.2, 6.6, 5.8]
    /// Samples per period: at 48 the step is below one pixel even at 60 Hz.
    static let samples = 48

    static var width: CGFloat { CGFloat(bars) * barWidth + CGFloat(bars - 1) * spacing }

    static func centerX(of index: Int) -> CGFloat {
      CGFloat(index) * (barWidth + spacing) + barWidth / 2
    }

    /// Same formula as the old `IslandEqualizer`: one sine per bar.
    static func height(index: Int, time: TimeInterval) -> CGFloat {
      let speed = speeds[index % speeds.count]
      let phase = Double(index) * 1.7
      let wave = (sin(time * speed + phase) + 1) / 2
      return minHeight + (maxHeight - minHeight) * wave
    }

    static func period(index: Int) -> TimeInterval { 2 * .pi / speeds[index % speeds.count] }

    /// One full period of the sine, repeated forever, in phase with the clock.
    static func animation(index: Int, now: TimeInterval) -> CAKeyframeAnimation {
      let period = period(index: index)
      let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
      animation.values = (0...samples).map { step in
        height(index: index, time: period * Double(step) / Double(samples))
      }
      animation.calculationMode = .cubic
      animation.duration = period
      animation.repeatCount = .infinity
      animation.timeOffset = now.truncatingRemainder(dividingBy: period)
      animation.isRemovedOnCompletion = false
      return animation
    }

    static func color(at index: Int, of colors: [NSColor]) -> NSColor {
      guard colors.count > 1 else { return colors.first ?? .white }
      return index < bars / 2 + 1 ? colors[0] : colors[1]
    }
  }

  enum Waveform {
    /// Opacity of the unlit bars, like the inactive levels of `variableColor`.
    static let dimOpacity: Float = 0.35
    /// Time over which the lighting passes from one bar to the next.
    static let step: TimeInterval = 0.16
    static let samples = 60

    static func cycle(bars: Int) -> TimeInterval { step * Double(max(bars, 1) + 2) }

    /// Opacity of bar `index` at fraction `progress` of the cycle: the light runs from
    /// left to right, lights one bar at a time and lets it fade out slowly.
    static func opacity(index: Int, of bars: Int, at progress: Double) -> Float {
      let slots = Double(max(bars, 1) + 2)
      let center = (Double(index) + 1) / slots
      let width = 1.4 / slots
      var distance = abs(progress - center)
      distance = min(distance, 1 - distance)
      let light = max(0, 1 - distance / width)
      return dimOpacity + (1 - dimOpacity) * Float(light * light * (3 - 2 * light))
    }

    static func animation(index: Int, of bars: Int) -> CAKeyframeAnimation {
      let animation = CAKeyframeAnimation(keyPath: "opacity")
      animation.values = (0...samples).map { opacity(index: index, of: bars, at: Double($0) / Double(samples)) }
      animation.duration = cycle(bars: bars)
      animation.repeatCount = .infinity
      animation.isRemovedOnCompletion = false
      return animation
    }
  }
}

/// The `waveform` symbol drawn once and split into its bars.
struct WaveformGlyph {
  let image: CGImage
  let size: CGSize
  /// Pixel columns of each bar, from left to right.
  let columns: [Range<Int>]

  @MainActor
  static func render(pointSize: CGFloat, scale: CGFloat) -> WaveformGlyph? {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard
      let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return nil }
    let size = symbol.size
    let width = Int((size.width * scale).rounded(.up))
    let height = Int((size.height * scale).rounded(.up))
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    symbol.draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage(), let data = context.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    let inked = (0..<width).map { column in
      (0..<height).contains { row in pixels[(row * width + column) * 4 + 3] > 24 }
    }
    return WaveformGlyph(image: image, size: size, columns: runs(of: inked))
  }

  /// Groups of inked columns separated by empty columns.
  static func runs(of inked: [Bool]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var start: Int?
    for (column, isInked) in inked.enumerated() {
      if isInked, start == nil { start = column }
      if !isInked, let begin = start {
        result.append(begin..<column)
        start = nil
      }
    }
    if let begin = start { result.append(begin..<inked.count) }
    return result
  }
}
