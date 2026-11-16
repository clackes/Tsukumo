// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Island

@Suite("Island: player and lyrics")
@MainActor
struct IslandPlayerTests {
  @Test("island and lock screen lyrics are switched on separately")
  func lyricsToggles() {
    let model = IslandModel()
    #expect(!model.needsLyrics)
    model.lockMediaEnabled = true
    model.lockLyricsEnabled = true
    #expect(model.showsLockLyrics)
    #expect(model.needsLyrics)
    #expect(!model.lyricsEnabled)
    model.lockMediaEnabled = false
    #expect(!model.showsLockLyrics)
    #expect(!model.needsLyrics)
    model.lyricsEnabled = true
    #expect(model.needsLyrics)
    #expect(!model.showsLockLyrics)
  }

  @Test("with a track the open island is taller, for the player")
  func playerHeight() {
    let model = IslandModel()
    let empty = model.extraHeight
    model.media = NowPlaying(
      title: "x", artist: "y", album: "", isPlaying: true, duration: 100, position: 0,
      updatedAt: Date(), bundleID: "com.spotify.client")
    #expect(model.extraHeight == empty + IslandGeometry.playerExtraHeight)
  }

  @Test("the equalizer stays within limits")
  func equalizer() {
    for index in 0..<5 {
      for step in 0..<50 {
        let height = BarsMath.Equalizer.height(index: index, time: Double(step) * 0.07)
        #expect(height >= 3 && height <= 14)
      }
    }
  }

  @Test("artwork colors become vivid on black")
  func vividColors() throws {
    let dull = NSColor(srgbRed: 0.2, green: 0.25, blue: 0.3, alpha: 1)
    let vivid = try #require(IslandArtworkPalette.vivid(dull).usingColorSpace(.sRGB))
    #expect(vivid.brightnessComponent >= 0.85)
  }

  /// Probe in a real window, to look at the player:
  ///
  ///     TSUKUMO_ISLAND_PROBE=/tmp/island.png swift test --filter IslandPlayerTests
  @Test("shows the open island with a track and photographs it")
  func windowProbe() async throws {
    guard let outPath = ProcessInfo.processInfo.environment["TSUKUMO_ISLAND_PROBE"],
      let screen = NSScreen.main
    else { return }
    let model = IslandModel()
    model.media = NowPlaying(
      title: "Baile De Fantome", artist: "Franky Rizardo", album: "",
      isPlaying: true, duration: 154, position: 85, updatedAt: Date(), bundleID: "com.apple.Music")
    model.canSendCommands = true
    model.isFavorite = false
    model.artwork = Self.artwork()
    let notch = CGRect(x: screen.frame.midX - 92, y: screen.frame.maxY - 32, width: 184, height: 32)
    model.notch = NotchMetrics(rect: notch, isPhysical: true)
    model.screenFrame = screen.frame
    model.presentation = .expanded
    let size = model.size(for: .expanded)
    let frame = CGRect(
      x: notch.midX - size.width / 2, y: notch.maxY - size.height - 120, width: size.width, height: size.height)
    let actions = IslandActions(tap: {}, send: { _ in }, removeFromShelf: { _ in }, airDropAll: {})
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .screenSaver
    panel.contentView = NSHostingView(rootView: IslandView(model: model, actions: actions))
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(900))
    let rect = frame.insetBy(dx: -30, dy: -30)
    let top = screen.frame.maxY - rect.maxY
    func shoot(_ path: String) throws {
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))", path]
      try capture.run()
      capture.waitUntilExit()
    }
    try shoot(outPath)
    // Track change: one snapshot mid-animation and one at the end.
    model.media = NowPlaying(
      title: "Nuvole", artist: "Lucio Battisti", album: "",
      isPlaying: true, duration: 214, position: 2, updatedAt: Date(), bundleID: "com.apple.Music")
    model.artwork = Self.artwork(flipped: true)
    try await Task.sleep(for: .milliseconds(90))
    try shoot(outPath.replacingOccurrences(of: ".png", with: "-mid.png"))
    try await Task.sleep(for: .milliseconds(900))
    try shoot(outPath.replacingOccurrences(of: ".png", with: "-end.png"))
    panel.close()
  }

  private static func artwork(flipped: Bool = false) -> NSImage {
    let size = NSSize(width: 300, height: 300)
    let image = NSImage(size: size)
    image.lockFocus()
    NSGradient(colors: [
      NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.5, alpha: 1),
      NSColor(calibratedRed: 0.9, green: 0.45, blue: 0.4, alpha: 1),
    ])?.draw(in: NSRect(origin: .zero, size: size), angle: flipped ? 135 : 0)
    image.unlockFocus()
    return image
  }
}
