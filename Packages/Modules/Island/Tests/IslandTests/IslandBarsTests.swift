// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Island

@MainActor
@Suite("Bars animated by Core Animation")
struct IslandBarsTests {
  @Test("columns with ink become bars")
  func runs() {
    let inked: [Bool] = [false, true, true, false, false, true, false, true, true, true]
    #expect(WaveformGlyph.runs(of: inked) == [1..<3, 5..<6, 7..<10])
    #expect(WaveformGlyph.runs(of: []) == [])
  }

  @Test("the waveform symbol splits into several bars")
  func glyph() throws {
    let glyph = try #require(WaveformGlyph.render(pointSize: 12, scale: 2))
    #expect(glyph.columns.count >= 3)
    #expect(glyph.size.width > 8 && glyph.size.height > 6)
  }

  @Test("in the wave one bar lights up at a time, from left to right")
  func waveformOpacity() {
    let bars = 6
    var peaks: [Double] = []
    for index in 0..<bars {
      let samples = (0..<600).map { Double($0) / 600 }
      let values = samples.map { BarsMath.Waveform.opacity(index: index, of: bars, at: $0) }
      #expect(values.allSatisfy { $0 >= BarsMath.Waveform.dimOpacity - 0.0001 && $0 <= 1.0001 })
      #expect(values.max() ?? 0 > 0.99)
      peaks.append(samples[values.firstIndex(of: values.max() ?? 0) ?? 0])
    }
    #expect(peaks == peaks.sorted())
  }

  @Test("the equalizer reproduces the sine of the SwiftUI version and is in phase with the clock")
  func equalizerKeyframes() throws {
    for index in 0..<BarsMath.Equalizer.bars {
      let now = 1_000.0 + Double(index)
      let animation = BarsMath.Equalizer.animation(index: index, now: now)
      let values = try #require(animation.values as? [CGFloat])
      #expect(values.allSatisfy { $0 >= 3 && $0 <= 14 })
      // The period closes on itself: no jumps at the loop.
      #expect(abs((values.first ?? 0) - (values.last ?? 0)) < 0.001)
      // At the start time the height is the one from the original formula at `now`.
      let progress = animation.timeOffset / animation.duration
      let expected = BarsMath.Equalizer.height(index: index, time: now)
      let sampled = BarsMath.Equalizer.height(index: index, time: progress * animation.duration)
      #expect(abs(sampled - expected) < 0.01)
    }
  }

  /// CA animations are visible in-process: the presentation layer changes over time.
  @Test("in a real window the bars move while playing and stop when paused", arguments: [true, false])
  func liveMotion(waveform: Bool) async throws {
    let view = IslandBarsView()
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    defer { window.close() }
    let style: IslandBars.Style = waveform ? .waveform : .equalizer(colors: [.systemPink, .systemTeal])
    view.configure(style: style, isPlaying: true)
    let bars = try #require(view.layer?.sublayers)
    #expect(bars.count >= 3)
    #expect(bars.allSatisfy { $0.animation(forKey: BarsMath.animationKey) != nil })

    func snapshot() -> [CGFloat] {
      bars.map { bar in
        let presented = bar.presentation() ?? bar
        return waveform ? CGFloat(presented.opacity) : presented.bounds.height
      }
    }
    let first = snapshot()
    try await Task.sleep(for: .milliseconds(250))
    let second = snapshot()
    #expect(first != second)

    view.configure(style: style, isPlaying: false)
    #expect(bars.allSatisfy { $0.animation(forKey: BarsMath.animationKey) == nil })
  }

  /// The real island mounts the bars with a sensible size and animates them.
  @Test(
    "the compact and open island host animated bars",
    arguments: [
      (IslandPresentation.compact, IslandPlaybackIndicator.waveform),
      (.compact, .bars), (.expanded, .waveform),
    ])
  func hostedInIsland(presentation: IslandPresentation, indicator: IslandPlaybackIndicator) async throws {
    let panel = Self.islandPanel(presentation: presentation, indicator: indicator)
    defer { panel.close() }
    try await Task.sleep(for: .milliseconds(600))
    let content = try #require(panel.contentView)
    let bars = Self.subviews(of: content).compactMap { $0 as? IslandBarsView }
    #expect(bars.count == 1)
    let view = try #require(bars.first)
    #expect(view.frame.width >= 10 && view.frame.height >= 8)
    let layers = view.layer?.sublayers ?? []
    #expect(layers.count >= 3)
    #expect(layers.allSatisfy { $0.animation(forKey: BarsMath.animationKey) != nil })
    if presentation == .expanded {
      let progress = Self.subviews(of: content).compactMap { $0 as? LiveProgressView }
      #expect(progress.count == 1)
      #expect(progress.first?.fill.animation(forKey: LiveProgressView.animationKey) != nil)
    }
  }

  @Test("with the indicator set to still, the compact island has no animated bars")
  func stillIndicator() async throws {
    let panel = Self.islandPanel(presentation: .compact, indicator: .still)
    defer { panel.close() }
    try await Task.sleep(for: .milliseconds(400))
    let content = try #require(panel.contentView)
    #expect(Self.subviews(of: content).allSatisfy { !($0 is IslandBarsView) })
  }

  private static func subviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(subviews(of:))
  }

  private static func islandPanel(presentation: IslandPresentation, indicator: IslandPlaybackIndicator) -> NSPanel {
    let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
    let model = IslandModel()
    model.media = NowPlaying(
      title: "Baile De Fantome", artist: "Franky Rizardo", album: "",
      isPlaying: true, duration: 154, position: 85, updatedAt: Date(), bundleID: "com.apple.Music")
    model.canSendCommands = true
    model.artwork = artwork()
    model.playbackIndicator = indicator
    let notch = CGRect(x: screen.midX - 92, y: screen.maxY - 32, width: 184, height: 32)
    model.notch = NotchMetrics(rect: notch, isPhysical: true)
    model.screenFrame = screen
    model.activity = .track(title: "Baile De Fantome")
    model.presentation = presentation
    let size = model.size(for: presentation)
    let frame = CGRect(
      x: notch.midX - size.width / 2, y: notch.maxY - size.height - 160, width: size.width, height: size.height)
    let actions = IslandActions(tap: {}, send: { _ in }, removeFromShelf: { _ in }, airDropAll: {})
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.contentView = NSHostingView(rootView: IslandView(model: model, actions: actions))
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
    return panel
  }

  /// Visual comparison for the user: previous wave (SwiftUI), new wave and bars.
  ///
  ///     TSUKUMO_ISLAND_COMPARE=60 swift test --filter compareProbe
  @Test("visual comparison between the previous wave and the new one")
  func compareProbe() async throws {
    guard let seconds = ProcessInfo.processInfo.environment["TSUKUMO_ISLAND_COMPARE"].flatMap(Double.init) else {
      return
    }
    let row = HStack(spacing: 28) {
      VStack(spacing: 8) {
        Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
          .symbolEffect(.variableColor.iterative)
        Text(verbatim: "first").font(.caption2)
      }
      VStack(spacing: 8) {
        IslandBars(style: .waveform, isPlaying: true).fixedSize()
        Text(verbatim: "new wave").font(.caption2)
      }
      VStack(spacing: 8) {
        IslandBars(style: .equalizer(colors: [.systemPink, .systemTeal]), isPlaying: true).fixedSize()
        Text(verbatim: "colored bars").font(.caption2)
      }
    }
    .foregroundStyle(.white.opacity(0.7))
    .padding(24)
    .background(.black, in: RoundedRectangle(cornerRadius: 18))
    let panel = NSPanel(
      contentRect: CGRect(x: 200, y: 400, width: 320, height: 110), styleMask: [.titled, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.title = "Tsukumo: wave comparison"
    panel.level = .floating
    panel.contentView = NSHostingView(rootView: row)
    panel.orderFrontRegardless()
    try await Task.sleep(for: .seconds(seconds))
    panel.close()
  }

  /// Measurement bench: keeps the island in a real window for `TSUKUMO_ISLAND_COST`
  /// seconds while `top` measures the test process (Docs/PERF.md).
  ///
  ///     TSUKUMO_ISLAND_COST=60 TSUKUMO_ISLAND_PRESENTATION=expanded swift test --filter costBench
  @Test("island measurement bench with music")
  func costBench() async throws {
    guard let seconds = ProcessInfo.processInfo.environment["TSUKUMO_ISLAND_COST"].flatMap(Double.init),
      let screen = NSScreen.main
    else { return }
    let expanded = ProcessInfo.processInfo.environment["TSUKUMO_ISLAND_PRESENTATION"] == "expanded"
    let model = IslandModel()
    model.media = NowPlaying(
      title: "Baile De Fantome", artist: "Franky Rizardo", album: "",
      isPlaying: true, duration: 154, position: 85, updatedAt: Date(), bundleID: "com.apple.Music")
    model.canSendCommands = true
    model.artworkEnabled = true
    model.artwork = Self.artwork()
    if let raw = ProcessInfo.processInfo.environment["TSUKUMO_ISLAND_INDICATOR"],
      let indicator = IslandPlaybackIndicator(rawValue: raw)
    {
      model.playbackIndicator = indicator
    }
    let notch = CGRect(x: screen.frame.midX - 92, y: screen.frame.maxY - 32, width: 184, height: 32)
    model.notch = NotchMetrics(rect: notch, isPhysical: true)
    model.screenFrame = screen.frame
    model.activity = .track(title: "Baile De Fantome")
    model.presentation = expanded ? .expanded : .compact
    let size = model.size(for: model.presentation)
    let frame = CGRect(
      x: notch.midX - size.width / 2, y: notch.maxY - size.height - 160, width: size.width, height: size.height)
    let actions = IslandActions(tap: {}, send: { _ in }, removeFromShelf: { _ in }, airDropAll: {})
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .screenSaver
    panel.contentView = NSHostingView(rootView: IslandView(model: model, actions: actions))
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
    try await Task.sleep(for: .seconds(seconds))
    panel.close()
  }

  private static func artwork() -> NSImage {
    let size = NSSize(width: 300, height: 300)
    let image = NSImage(size: size)
    image.lockFocus()
    NSGradient(colors: [
      NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.5, alpha: 1),
      NSColor(calibratedRed: 0.9, green: 0.45, blue: 0.4, alpha: 1),
    ])?.draw(in: NSRect(origin: .zero, size: size), angle: 0)
    image.unlockFocus()
    return image
  }
}

@MainActor
@Suite("Track progress animated by Core Animation")
struct LiveProgressTests {
  @Test("the fraction elapsed stays between 0 and 1")
  func fraction() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let interval = start...start.addingTimeInterval(100)
    #expect(LiveProgressView.fraction(of: interval, at: start.addingTimeInterval(25)) == 0.25)
    #expect(LiveProgressView.fraction(of: interval, at: start.addingTimeInterval(-5)) == 0)
    #expect(LiveProgressView.fraction(of: interval, at: start.addingTimeInterval(500)) == 1)
  }

  @Test("in a real window the bar starts at the current position and grows")
  func liveGrowth() async throws {
    let view = LiveProgressView()
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 200, height: 4), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    defer { window.close() }
    // A 4 s track at the midpoint: the bar starts at about 100 pt and grows.
    view.interval = Date().addingTimeInterval(-2)...Date().addingTimeInterval(2)
    view.layoutSubtreeIfNeeded()
    #expect(view.fill.animation(forKey: LiveProgressView.animationKey) != nil)
    try await Task.sleep(for: .milliseconds(50))
    let first = view.fill.presentation()?.bounds.width ?? 0
    #expect(abs(first - 100) < 10)
    try await Task.sleep(for: .milliseconds(500))
    let second = view.fill.presentation()?.bounds.width ?? 0
    #expect(second > first + 15)
  }
}
