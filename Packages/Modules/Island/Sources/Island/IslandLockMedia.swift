// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import SwiftUI

/// Music on the lock screen (DESIGN.md §2.1): a single glass card
/// (Liquid Glass) tinted with the artwork's color, like the iOS lock
/// screen player: large artwork, title and artist, time bar, ⏮ ⏯ ⏭,
/// volume and audio output. It exists only while the screen is locked with a track present
/// and goes above the lock screen with the same SkyLight delegation as the lock (private
/// APIs, opt-in). It sits in the band between the clock and the profile photo, so
/// the clock and the password field stay visible and clickable.
@MainActor
final class LockMediaController {
  /// Reference size for the snapshot in tests.
  static let referenceSize = CGSize(width: 1512, height: 982)
  /// Transparent margin of the window around the card: without it, the shadow
  /// would be cut by the window's edge.
  static let shadowMargin: CGFloat = 48

  // MARK: Geometry
  //
  // Free band on the macOS lock screen: above, clock and date (up to
  // about 24% of the height); below, profile photo and password field (from 80%).
  static let safeTopFraction: CGFloat = 0.25
  static let safeBottomFraction: CGFloat = 0.80
  /// Maximum height: on large screens the card does not grow beyond it.
  static let maxCardHeight: CGFloat = 540
  /// Everything below the artwork, margins included: the artwork
  /// takes the remaining space and is as wide as the card minus the margins.
  static let chromeHeight: CGFloat = 236
  static let padding: CGFloat = 18

  static func cardSize(for screen: CGSize) -> CGSize {
    let band = max(screen.height * (safeBottomFraction - safeTopFraction), 0)
    let height = min(band, maxCardHeight)
    let cover = max(height - chromeHeight, 120)
    return CGSize(width: (cover + padding * 2).rounded(), height: (cover + chromeHeight).rounded())
  }

  /// Text card to the right of the player: same height, a bit wider.
  static let lyricsGap: CGFloat = 20
  static func lyricsSize(for card: CGSize) -> CGSize {
    CGSize(width: (card.width * 1.2).rounded(), height: card.height)
  }

  /// Window content (without margins), centered under the clock: with
  /// the text the player + text block is centered, and the player goes to the left.
  static func contentFrame(in screen: CGRect, lyrics: Bool) -> CGRect {
    let card = cardSize(for: screen.size)
    let extra = lyrics ? lyricsGap + lyricsSize(for: card).width : 0
    let origin = CGPoint(
      x: screen.minX + (screen.width - card.width - extra) / 2,
      y: screen.minY + screen.height - cardCenterY(for: screen.size) - card.height / 2)
    return CGRect(origin: origin, size: CGSize(width: card.width + extra, height: card.height)).integral
  }

  /// Vertical center of the card, measured from the top, in the free band.
  static func cardCenterY(for screen: CGSize) -> CGFloat {
    screen.height * (safeTopFraction + safeBottomFraction) / 2
  }

  private let model: IslandModel
  private let actions: IslandActions
  private let resources: ResourceBag
  private var panel: NSPanel?
  /// The window enters the `ResourceBag` only while it exists: with the screen
  /// unlocked, no resources.
  private var windowToken: ResourceBag.Token?
  private let backdrop = LockBackdrop()
  private var revealToken: ResourceBag.Token?

  init(model: IslandModel, actions: IslandActions, resources: ResourceBag) {
    self.model = model
    self.actions = actions
    self.resources = resources
    model.onArtworkChange = { [weak self] in self?.updateBackdrop() }
  }

  /// Shows or hides according to the state: no work while the screen is unlocked.
  func refresh(locked: Bool) {
    guard locked, model.lockMediaEnabled, model.media != nil else {
      close()
      return
    }
    show()
    updateBackdrop()
  }

  private func show() {
    if panel != nil {
      reposition()
      return
    }
    let screen = screenFrame()
    let panel = NSPanel(
      contentRect: cardFrame(in: screen),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    // One level above the artwork background, when there is one.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.ignoresMouseEvents = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    let size = Self.cardSize(for: screen.size)
    panel.contentView = NSHostingView(
      rootView: LockMediaContentView(model: model, actions: actions, size: size, lyrics: model.showsLockLyrics)
        .frame(maxWidth: .infinity, maxHeight: .infinity))
    self.panel = panel
    panel.orderFrontRegardless()
    LockScreenSpace.attach([panel])
    windowToken = resources.add(.window) { [weak self] in self?.close() }
  }

  /// Screen configuration change: the card, if present, repositions itself.
  func relayout() {
    guard panel != nil else { return }
    // The size depends on the screen: the view is rebuilt.
    close()
    refresh(locked: true)
  }

  /// Every track update comes through here: the window is touched only
  /// if the frame really changed, without forced redraw.
  private func reposition() {
    let frame = cardFrame(in: screenFrame())
    if let panel, panel.frame != frame { panel.setFrame(frame, display: false) }
  }

  /// The card goes on the screen with the menu bar, the first in the list,
  /// not on the one with focus (`NSScreen.main`).
  private func screenFrame() -> CGRect {
    NSScreen.screens.first?.frame ?? CGRect(origin: .zero, size: Self.referenceSize)
  }

  private func cardFrame(in screen: CGRect) -> CGRect {
    Self.contentFrame(in: screen, lyrics: model.showsLockLyrics)
      .insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin)
  }

  /// Background with the artwork: exists only together with the player and only if on.
  private func updateBackdrop() {
    guard panel != nil, model.lockBackdropEnabled else {
      closeBackdrop()
      return
    }
    let isNew = backdrop.panel == nil
    backdrop.show(on: screenFrame(), level: .screenSaver)
    if isNew, let window = backdrop.panel {
      backdrop.onClick = { [weak self] in self?.revealLogin() }
      window.orderFrontRegardless()
      LockScreenSpace.attach([window])
      panel?.order(.above, relativeTo: window.windowNumber)
    }
    backdrop.update(
      artwork: model.artwork, isPlaying: model.media?.isPlaying == true,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }

  /// Click on the background: it moves aside for a few seconds and shows the macOS login.
  private func revealLogin() {
    backdrop.setRevealed(true)
    updateBackdrop()
    if let revealToken { resources.cancel(revealToken) }
    let delay = LockBackdrop.revealDuration
    revealToken = resources.addTimer(every: delay, tolerance: delay * 0.1) { [weak self] in
      guard let self else { return }
      if let revealToken { self.resources.cancel(revealToken) }
      self.revealToken = nil
      self.backdrop.setRevealed(false)
      self.updateBackdrop()
    }
  }

  private func closeBackdrop() {
    if let revealToken { resources.cancel(revealToken) }
    revealToken = nil
    backdrop.close()
  }

  func close() {
    closeBackdrop()
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel = nil
    if let windowToken {
      self.windowToken = nil
      resources.cancel(windowToken)
    }
  }
}

/// The player card. The sizes come from the controller, computed on the
/// screen: the artwork is square and as wide as the card minus the margins.
struct LockMediaCardView: View {
  let model: IslandModel
  let actions: IslandActions
  let size: CGSize
  /// The list of outputs opens inside the card: a normal menu would open
  /// a window that is not visible on the lock screen.
  @State private var outputs: [LockAudioOutput]?
  @State private var currentOutput: LockAudioOutput?
  @State private var volume: Float?
  @State private var breathe = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The artwork arrives after the title: it animates when the image changes.
  private func coverKey(_ media: NowPlaying) -> String { model.artworkID }

  private var cover: CGFloat { size.width - LockMediaController.padding * 2 }

  var body: some View {
    if let media = model.media {
      let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
      VStack(spacing: 0) {
        ZStack {
          artwork
            .id(coverKey(media))
            .transition(IslandMotion.cover(direction: 1, reduceMotion: reduceMotion))
        }
        .animation(IslandMotion.swap, value: coverKey(media))
        if let outputs {
          outputList(outputs)
        } else {
          ZStack {
            titleRow(media)
              .id(media.title + media.artist)
              .transition(IslandMotion.text(direction: 1, reduceMotion: reduceMotion))
          }
          .clipped()
          .animation(IslandMotion.swap, value: media.title + media.artist)
          .padding(.top, 14)
          progressRow(media).padding(.top, 10)
          if model.canSendCommands { controls(media).padding(.top, 6) }
          Spacer(minLength: 0)
          volumeRow.padding(.bottom, 10)
        }
        outputButton
      }
      .padding(LockMediaController.padding)
      .frame(width: size.width, height: size.height)
      .foregroundStyle(.white)
      // Real glass and a veil of the artwork's color: as on iPhone the
      // card takes the track's tint, and the white text stays readable.
      .background(LockArtworkTint.color(for: model.artwork).opacity(0.55), in: shape)
      .background(Color.black.opacity(0.12), in: shape)
      .glassEffect(.clear.interactive(), in: shape)
      .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
      .onAppear {
        breathe = media.isPlaying
        currentOutput = LockAudioOutputs.current()
        volume = LockAudioOutputs.volume()
      }
      .onChange(of: media.isPlaying) { _, playing in breathe = playing }
    }
  }

  @ViewBuilder private var artwork: some View {
    Group {
      if let image = model.artwork {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
      } else {
        ZStack {
          Color.white.opacity(0.12)
          Image(systemName: "music.note").font(.system(size: cover * 0.3)).foregroundStyle(.white.opacity(0.5))
        }
      }
    }
    .frame(width: cover, height: outputs == nil ? cover : cover * 0.42)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
    // The breathing runs only while the music plays: when paused the card stays
    // still and costs no recompositions.
    .scaleEffect(breathe ? 1.0 : 0.96)
    .animation(.spring(duration: 0.5), value: breathe)
    .animation(.smooth(duration: 0.25), value: outputs == nil)
  }

  private func titleRow(_ media: NowPlaying) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(verbatim: media.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
      Text(verbatim: media.artist).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Clickable and draggable time bar, with the times below as on iPhone.
  @ViewBuilder private func progressRow(_ media: NowPlaying) -> some View {
    if let duration = media.duration, duration > 0 {
      VStack(spacing: 2) {
        LockSeekBar(media: media, duration: duration) { actions.seek($0) }
        HStack {
          timeLabel(media, duration: duration, remaining: false)
          Spacer()
          timeLabel(media, duration: duration, remaining: true)
        }
      }
    }
  }

  @ViewBuilder private func timeLabel(_ media: NowPlaying, duration: TimeInterval, remaining: Bool) -> some View {
    Group {
      if let interval = media.progressInterval {
        HStack(spacing: 0) {
          if remaining { Text(verbatim: "−") }
          Text(timerInterval: interval, countsDown: remaining)
        }
      } else {
        let position = min(media.position ?? 0, duration)
        Text(verbatim: remaining ? "−" + Self.format(duration - position) : Self.format(position))
      }
    }
    .font(.system(size: 11, weight: .semibold).monospacedDigit())
    .foregroundStyle(.white.opacity(0.55))
  }

  static func format(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds.rounded(.down)), 0)
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  private func controls(_ media: NowPlaying) -> some View {
    HStack(spacing: 0) {
      control("backward.fill", size: 24, label: "Previous track", command: .previous)
      control(
        media.isPlaying ? "pause.fill" : "play.fill", size: 34,
        label: media.isPlaying ? "Pause" : "Play", command: .togglePlayPause)
      control("forward.fill", size: 24, label: "Next track", command: .next)
    }
    .frame(maxWidth: .infinity)
  }

  private func control(_ symbol: String, size: CGFloat, label: LocalizedStringKey, command: MediaCommand) -> some View {
    Button {
      actions.send(command)
    } label: {
      Image(systemName: symbol)
        .font(.system(size: size, weight: .regular))
        .contentTransition(.symbolEffect(.replace))
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(label))
    .help(Text(label))
  }

  /// Volume of the system output. Read on opening: no listener.
  @ViewBuilder private var volumeRow: some View {
    if let volume {
      HStack(spacing: 10) {
        Image(systemName: "speaker.fill").font(.system(size: 11))
        LockLevelBar(value: Double(volume)) { newValue in
          self.volume = Float(newValue)
          LockAudioOutputs.setVolume(Float(newValue))
        }
        Image(systemName: "speaker.wave.3.fill").font(.system(size: 11))
      }
      .foregroundStyle(.white.opacity(0.6))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text("Volume"))
    }
  }

  /// Pill with the current output: opens the list of outputs inside the card.
  private var outputButton: some View {
    Button {
      toggleOutputs()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: outputs == nil ? (currentOutput?.symbol ?? "airplayaudio") : "xmark")
        Text(verbatim: outputs == nil ? (currentOutput?.name ?? "AirPlay") : String(localized: "Close"))
          .lineLimit(1)
      }
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, 14)
      .frame(height: 30)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: Capsule())
    .frame(maxWidth: cover * 0.8)
    .accessibilityLabel(Text("Output"))
    .help(Text("Output"))
  }

  private func toggleOutputs() {
    if outputs == nil {
      outputs = LockAudioOutputs.list()
      currentOutput = LockAudioOutputs.current()
    } else {
      outputs = nil
    }
  }

  @ViewBuilder private func outputList(_ list: [LockAudioOutput]) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(list) { output in
          Button {
            LockAudioOutputs.select(output.id)
            currentOutput = output
            volume = LockAudioOutputs.volume()
            outputs = nil
          } label: {
            HStack(spacing: 10) {
              Image(systemName: output.symbol).frame(width: 20)
              Text(verbatim: output.name).font(.system(size: 14)).lineLimit(1)
              Spacer(minLength: 0)
              if currentOutput?.id == output.id {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
              }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .scrollIndicators(.never)
    .padding(.vertical, 10)
  }
}
