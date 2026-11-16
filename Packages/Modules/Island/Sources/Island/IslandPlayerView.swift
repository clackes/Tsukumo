// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreAudio
import DesignSystem
import SwiftUI

/// Open island player, for any app that plays: artwork, title and
/// artist with a small equalizer in the artwork's colors, time
/// bar between elapsed and duration, then favorite, ⏮ ⏯ ⏭ and audio output.
struct IslandPlayerView: View {
  let model: IslandModel
  let actions: IslandActions
  let media: NowPlaying
  /// Current output, read on opening and after each choice: no listener.
  @State private var output: LockAudioOutput?
  /// Last click on ⏮: for a short time the track change enters from the left.
  @State private var lastPrevious: Date?
  /// The rows enter in sequence on opening.
  @State private var shown = false
  @State private var heartBursts = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let artworkSize: CGFloat = 54

  private var direction: CGFloat { IslandMotion.direction(lastPrevious: lastPrevious, now: Date()) }
  private var trackKey: String { media.title + "\u{1F}" + media.artist }
  /// The artwork arrives after the title: it animates when the image changes.
  private var coverKey: String {
    model.artworkID
  }

  var body: some View {
    VStack(spacing: 0) {
      header.modifier(IslandStagger(index: 0, shown: shown, reduceMotion: reduceMotion))
      timeRow.padding(.top, 12).modifier(IslandStagger(index: 1, shown: shown, reduceMotion: reduceMotion))
      if model.canSendCommands {
        controls.padding(.top, 8).modifier(IslandStagger(index: 2, shown: shown, reduceMotion: reduceMotion))
      }
    }
    .foregroundStyle(.white)
    .onAppear {
      output = LockAudioOutputs.current()
      shown = true
    }
    .onChange(of: model.isFavorite) { old, new in
      if old == false, new == true { heartBursts += 1 }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      ZStack {
        glow
        artwork
          .id(coverKey)
          .transition(IslandMotion.cover(direction: direction, reduceMotion: reduceMotion))
      }
      .frame(width: Self.artworkSize, height: Self.artworkSize)
      // When paused the artwork shrinks back a little, as on the lock screen.
      .scaleEffect(media.isPlaying ? 1 : 0.86)
      .animation(IslandMotion.pulse, value: media.isPlaying)
      .animation(IslandMotion.swap, value: coverKey)
      ZStack(alignment: .leading) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: media.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
          Text(verbatim: media.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(trackKey)
        .transition(IslandMotion.text(direction: direction, reduceMotion: reduceMotion))
      }
      .clipped()
      .animation(IslandMotion.swap, value: trackKey)
      // Bars animated by Core Animation: SwiftUI does not redraw the island on every frame.
      IslandBars(style: .equalizer(colors: IslandArtworkPalette.colors(for: model.artwork)), isPlaying: media.isPlaying)
        .accessibilityHidden(true)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
    }
    .frame(height: Self.artworkSize)
  }

  /// Blurred glow of the artwork behind it: brighter while playing.
  @ViewBuilder private var glow: some View {
    if let image = model.artwork {
      Image(nsImage: image).resizable().scaledToFill()
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .blur(radius: 12)
        .opacity(media.isPlaying ? 0.55 : 0.15)
        .id(coverKey)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder private var artwork: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    Group {
      if let image = model.artwork {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
      } else if let icon = PlayerIconCache.icon(for: media.bundleID) {
        // Without artwork: the icon of the app that is playing.
        Image(nsImage: icon).resizable().padding(4)
      } else {
        ZStack {
          Color.white.opacity(0.12)
          Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.5))
        }
      }
    }
    .frame(width: Self.artworkSize, height: Self.artworkSize)
    .clipShape(shape)
    .accessibilityHidden(true)
  }

  @ViewBuilder private var timeRow: some View {
    if let duration = media.duration, duration > 0 {
      HStack(spacing: 10) {
        elapsed(duration: duration).frame(width: 36, alignment: .leading)
        LockSeekBar(media: media, duration: duration) { actions.seek($0) }
        Text(verbatim: LockMediaCardView.format(duration)).frame(width: 36, alignment: .trailing)
      }
      .font(.system(size: 11, weight: .semibold).monospacedDigit())
      .foregroundStyle(.white.opacity(0.55))
    }
  }

  @ViewBuilder private func elapsed(duration: TimeInterval) -> some View {
    if let interval = media.progressInterval {
      Text(timerInterval: interval, countsDown: false)
    } else {
      Text(verbatim: LockMediaCardView.format(min(media.position ?? 0, duration)))
    }
  }

  private var controls: some View {
    HStack(spacing: 0) {
      favoriteButton
      IslandControlButton(symbol: "backward.fill", size: 19, label: "Previous track", effect: .nudgeLeft) {
        lastPrevious = Date()
        actions.send(.previous)
      }
      IslandControlButton(
        symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 28,
        label: media.isPlaying ? "Pause" : "Play"
      ) { actions.send(.togglePlayPause) }
      IslandControlButton(symbol: "forward.fill", size: 19, label: "Next track", effect: .nudgeRight) {
        lastPrevious = nil
        actions.send(.next)
      }
      IslandControlButton(symbol: output?.symbol ?? "airplayaudio", size: 17, label: "Output") {
        IslandOutputMenu.show()
        output = LockAudioOutputs.current()
      }
    }
  }

  /// Only with Music and the permission already granted: elsewhere the space stays, so
  /// the controls stay centered.
  @ViewBuilder private var favoriteButton: some View {
    if let favorite = model.isFavorite {
      IslandControlButton(
        symbol: favorite ? "heart.fill" : "heart", size: 19,
        label: favorite ? "Remove from Favorites" : "Add to Favorites"
      ) {
        actions.toggleFavorite()
      }
      .foregroundStyle(favorite ? AnyShapeStyle(.pink) : AnyShapeStyle(.white.opacity(0.55)))
      .animation(IslandMotion.pulse, value: favorite)
      .overlay { IslandHeartBurst(trigger: heartBursts) }
      .transition(.scale(scale: 0.4).combined(with: .opacity))
    } else {
      Color.clear.frame(maxWidth: .infinity, minHeight: 36)
    }
  }
}

/// Two vivid colors taken from the artwork (left and right half), for
/// the equalizer. Computed once per image.
@MainActor
enum IslandArtworkPalette {
  private static var cache: (key: ObjectIdentifier, colors: [NSColor])?

  static func colors(for image: NSImage?) -> [NSColor] {
    guard let image else { return [NSColor.white.withAlphaComponent(0.8)] }
    let key = ObjectIdentifier(image)
    if let cache, cache.key == key { return cache.colors }
    let colors = halves(of: image).map(vivid)
    let result = colors.isEmpty ? [NSColor.white.withAlphaComponent(0.8)] : colors
    cache = (key, result)
    return result
  }

  static func halves(of image: NSImage) -> [NSColor] {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    context.interpolationQuality = .medium
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 2, height: 1))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
    return (0..<2).map { pixel in
      let base = pixel * 4
      return NSColor(
        srgbRed: CGFloat(data[base]) / 255, green: CGFloat(data[base + 1]) / 255,
        blue: CGFloat(data[base + 2]) / 255, alpha: 1)
    }
  }

  /// On the island's black an average color is dull: brightness and saturation are raised.
  static func vivid(_ color: NSColor) -> NSColor {
    guard let rgb = color.usingColorSpace(.sRGB) else { return color }
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
    return NSColor(
      hue: hue, saturation: min(max(saturation, 0.45) * 1.15, 1), brightness: max(brightness, 0.85), alpha: 1)
  }
}

/// List of audio outputs as a system menu under the pointer.
@MainActor
enum IslandOutputMenu {
  static func show() {
    let menu = NSMenu()
    let current = LockAudioOutputs.current()
    for output in LockAudioOutputs.list() {
      let item = NSMenuItem(title: output.name, action: #selector(OutputMenuTarget.pick(_:)), keyEquivalent: "")
      item.target = OutputMenuTarget.shared
      item.representedObject = NSNumber(value: output.id)
      item.state = output.id == current?.id ? .on : .off
      item.image = NSImage(systemSymbolName: output.symbol, accessibilityDescription: nil)
      menu.addItem(item)
    }
    // Synchronous: returns when the menu closes.
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }
}

@MainActor
private final class OutputMenuTarget: NSObject {
  static let shared = OutputMenuTarget()

  @objc func pick(_ sender: NSMenuItem) {
    guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
    LockAudioOutputs.select(AudioObjectID(id))
  }
}
