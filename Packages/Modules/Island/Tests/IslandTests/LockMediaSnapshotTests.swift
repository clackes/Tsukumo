// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Island

@Suite("Island: lock screen snapshot")
@MainActor
struct LockMediaSnapshotTests {
  @Test("renders the panel with test data into a PNG")
  func snapshot() throws {
    guard let outPath = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOT_OUT"] else {
      return  // On-demand snapshot: without the env var the test is a no-op.
    }

    let model = IslandModel()
    model.media = NowPlaying(
      title: "Nuvole", artist: "Lucio Battisti", album: "Anima latina",
      isPlaying: true, duration: 214, position: 73,
      updatedAt: Date(), bundleID: "com.apple.Music"
    )
    model.canSendCommands = true
    model.artwork = Self.makeArtwork()
    model.lyricLines = Self.lines
    model.lyricIndex = 2

    let size = LockMediaController.referenceSize
    let card = LockMediaController.cardSize(for: size)
    let actions = IslandActions(tap: {}, send: { _ in }, removeFromShelf: { _ in }, airDropAll: {})
    let scene = ZStack(alignment: .top) {
      LinearGradient(colors: [.indigo, .brown], startPoint: .top, endPoint: .bottom)
      // Simulation of the macOS lock screen: clock at the top, profile photo
      // and password field at the bottom.
      VStack(spacing: 0) {
        Text("22:47")
          .font(.system(size: 110, weight: .light))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.top, size.height * 0.06)
        Spacer()
        Circle()
          .fill(Color.white.opacity(0.4))
          .frame(width: 64, height: 64)
          .padding(.bottom, 10)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.white.opacity(0.18))
          .frame(width: 220, height: 32)
          .padding(.bottom, size.height * 0.06)
      }
      .frame(width: size.width, height: size.height)
      // Player and text as a single centered block.
      LockMediaContentView(model: model, actions: actions, size: card, lyrics: true)
        .offset(y: LockMediaController.cardCenterY(for: size) - card.height / 2)
    }
    .frame(width: size.width, height: size.height)

    let renderer = ImageRenderer(content: scene)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: outPath))
  }

  /// Probe in real windows: glass (Liquid Glass) is only seen composited by the
  /// system over a real background, not in an `ImageRenderer`.
  ///
  ///     TSUKUMO_LOCK_PROBE=/tmp/lock.png swift test --filter LockMediaSnapshot
  @Test("shows artwork and player in real windows and photographs them")
  func windowProbe() async throws {
    guard let outPath = ProcessInfo.processInfo.environment["TSUKUMO_LOCK_PROBE"],
      let screen = NSScreen.main
    else { return }
    let model = IslandModel()
    model.media = NowPlaying(
      title: "Nuvole", artist: "Lucio Battisti", album: "Anima latina",
      isPlaying: true, duration: 214, position: 73,
      updatedAt: Date(), bundleID: "com.apple.Music"
    )
    model.canSendCommands = true
    model.artwork = Self.makeArtwork()
    model.lyricLines = Self.lines
    model.lyricIndex = 3
    let actions = IslandActions(tap: {}, send: { _ in }, removeFromShelf: { _ in }, airDropAll: {})

    func panel(_ frame: CGRect, _ view: NSView) -> NSPanel {
      let panel = NSPanel(
        contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
      panel.ignoresMouseEvents = true
      panel.contentView = view
      panel.setFrame(frame, display: true)
      panel.orderFrontRegardless()
      return panel
    }
    let frame = screen.frame
    let card = LockMediaController.cardSize(for: frame.size)
    let cardFrame = LockMediaController.contentFrame(in: frame, lyrics: true)
      .insetBy(dx: -LockMediaController.shadowMargin, dy: -LockMediaController.shadowMargin)
    // Background with the blurred artwork, behind the player.
    let backdrop = LockBackdrop()
    backdrop.show(on: frame, level: .screenSaver)
    backdrop.panel?.orderFrontRegardless()
    backdrop.update(artwork: model.artwork, isPlaying: true, reduceMotion: false)
    defer { backdrop.close() }
    let pill = panel(
      cardFrame,
      NSHostingView(
        rootView: LockMediaContentView(model: model, actions: actions, size: card, lyrics: true)
          .frame(maxWidth: .infinity, maxHeight: .infinity)))
    try await Task.sleep(for: .milliseconds(900))
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", outPath]
    try capture.run()
    capture.waitUntilExit()
    pill.close()
  }

  private static let lines = [
    "I wake up thinking of you",
    "light comes in through the windows",
    "the clouds never stop",
    "and I walk slowly along the road that leads to the sea",
    "looking for your voice",
    "",
    "inside the morning noise",
  ]

  @Test("without lyrics the player is centered, with lyrics the block is centered")
  func contentFrame() {
    let screen = CGRect(origin: .zero, size: LockMediaController.referenceSize)
    let card = LockMediaController.cardSize(for: screen.size)
    let plain = LockMediaController.contentFrame(in: screen, lyrics: false)
    let withLyrics = LockMediaController.contentFrame(in: screen, lyrics: true)
    #expect(abs(plain.midX - screen.midX) <= 1)
    #expect(abs(withLyrics.midX - screen.midX) <= 1)
    #expect(withLyrics.minX < plain.minX)
    #expect(
      withLyrics.width == plain.width + LockMediaController.lyricsGap + LockMediaController.lyricsSize(for: card).width)
    #expect(withLyrics.maxX < screen.maxX)
  }

  @Test("the blurred background is small, 16-bit, and covers only with artwork")
  func backdropImage() throws {
    let blurred = try #require(LockBackdrop.blurred(Self.makeArtwork()))
    #expect(CGFloat(max(blurred.width, blurred.height)) <= LockBackdrop.blurredSide + 1)
    #expect(blurred.bitsPerComponent == 16)
    #expect(LockBackdrop.covers(hasArtwork: true, revealed: false))
    #expect(!LockBackdrop.covers(hasArtwork: false, revealed: false))
    #expect(!LockBackdrop.covers(hasArtwork: true, revealed: true))
    // Centered and slightly enlarged: it always covers the screen, without sideways drift.
    #expect(LockBackdrop.zoomRange.lowerBound >= 1)
    #expect(LockBackdrop.zoomRange.upperBound <= 1.1)
    #expect(LockBackdrop.blurFraction < 0.05)
    // Square and centered, slightly taller than the screen: only a little is lost above and below.
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    let cover = LockBackdrop.coverFrame(in: screen)
    #expect(cover.width == cover.height)
    #expect(cover.height > screen.height && cover.width < screen.width)
    #expect(cover.midX == screen.midX && cover.midY == screen.midY)
    let fill = try #require(LockBackdrop.blurred(Self.makeArtwork(), fraction: LockBackdrop.fillBlurFraction))
    #expect(fill.bitsPerComponent == 16)
  }

  @Test("the current line is centered by summing the heights above")
  func lyricsOffset() {
    let heights: [Int: CGFloat] = [0: 30, 1: 60, 2: 30]
    #expect(LockLyricsView.centerOffset(of: 0, heights: heights) == 15)
    #expect(LockLyricsView.centerOffset(of: 2, heights: heights) == 137)
  }

  private static func makeArtwork() -> NSImage {
    let size = NSSize(width: 600, height: 600)
    let image = NSImage(size: size)
    image.lockFocus()
    let gradient = NSGradient(colors: [
      NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.45, alpha: 1),
      NSColor(calibratedRed: 0.35, green: 0.15, blue: 0.55, alpha: 1),
      NSColor(calibratedRed: 0.10, green: 0.25, blue: 0.55, alpha: 1),
    ])
    gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 135)
    NSColor.white.withAlphaComponent(0.85).setFill()
    let note = NSAttributedString(
      string: "♪",
      attributes: [
        .font: NSFont.systemFont(ofSize: 220, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9),
      ]
    )
    let noteSize = note.size()
    note.draw(at: NSPoint(x: (size.width - noteSize.width) / 2, y: (size.height - noteSize.height) / 2))
    image.unlockFocus()
    return image
  }

  /// Probe: draws the lock screen background into a PNG, offscreen.
  ///
  ///     TSUKUMO_BACKDROP_PROBE=/tmp/background.png TSUKUMO_BACKDROP_COVER=copertina.jpg swift test --filter backdropProbe
  @Test("probe: the lock screen background into a PNG")
  func backdropProbe() throws {
    let env = ProcessInfo.processInfo.environment
    guard let out = env["TSUKUMO_BACKDROP_PROBE"] else { return }
    let artwork = env["TSUKUMO_BACKDROP_COVER"].flatMap { NSImage(contentsOfFile: $0) } ?? Self.makeArtwork()
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    let backdrop = LockBackdrop()
    backdrop.show(on: screen, level: .normal)
    backdrop.update(artwork: artwork, isPlaying: false, reduceMotion: true)
    let layer = try #require(backdrop.panel?.contentView?.layer)
    layer.removeAllAnimations()
    layer.sublayers?.forEach { $0.removeAllAnimations() }
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(screen.width), pixelsHigh: Int(screen.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
    layer.render(in: context)
    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    // Also the raw blurred image, before the layer's enlargement.
    if let blurred = LockBackdrop.blurred(artwork, fadingEdges: true) {
      try NSBitmapImageRep(cgImage: blurred).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-grezza.png")))
    }
    backdrop.close()
  }
}
