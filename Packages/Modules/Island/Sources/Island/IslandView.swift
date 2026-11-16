// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import Observation
import SwiftUI

/// Observable state of the island. It exists only between `start()` and `stop()`.
@MainActor
@Observable
public final class IslandModel {
  var presentation: IslandPresentation = .collapsed
  var activity: IslandActivity?
  var media: NowPlaying?
  var power = PowerStatus()
  var notch = NotchMetrics(rect: .zero, isPhysical: false)
  var screenFrame: CGRect = .zero
  var canSendCommands = false
  var shelf: [ShelfItem] = []
  /// A dragged file is over the island or in the hot zone.
  var isDragging = false
  var dragOverAirDrop = false
  var nextEvent: UpcomingEvent?
  /// Track among Music's favorites; `nil` if unknown (other apps, no permission).
  var isFavorite: Bool?
  /// Artwork of the current track, when the backend provides it.
  var artwork: NSImage? {
    didSet { if artwork !== oldValue { onArtworkChange?() } }
  }
  /// Notifies the lock screen background, which is not a SwiftUI view.
  @ObservationIgnored var onArtworkChange: (() -> Void)?
  /// Identity of the shown artwork: the track it belongs to. Cover views animate only when it changes,
  /// not when a sharper copy of the same artwork arrives.
  var artworkID = ""
  var artworkDenied = false
  var calendarAccess: CalendarAccess = .notDetermined

  public internal(set) var activation: IslandActivation = .hover
  public internal(set) var lyricsEnabled = false
  /// Line of text to show now, if the track has synchronized lyrics.
  var lyricLine: String?
  /// All the synchronized lyrics and the current line, for the lock screen.
  var lyricLines: [String] = []
  var lyricIndex: Int?

  var showsLyrics: Bool { lyricsEnabled && lyricLine != nil && media?.isPlaying == true }
  public internal(set) var showCharging = true
  public internal(set) var showTrackChanges = true
  public internal(set) var shelfEnabled = true
  public internal(set) var calendarEnabled = false
  public internal(set) var artworkEnabled = false
  public internal(set) var haloEnabled = false
  /// Wave, colored bars or still symbol next to the artwork while playing.
  public internal(set) var playbackIndicator: IslandPlaybackIndicator = .waveform
  public internal(set) var lockEnabled = true
  public internal(set) var lockScreenEnabled = false
  /// Music and lyrics on the lock screen (private SkyLight: opt-in).
  public internal(set) var lockMediaEnabled = false
  /// Synchronized lyrics in a card to the right of the lock screen player.
  public internal(set) var lockLyricsEnabled = false
  /// Full-screen blurred artwork behind the player, like a screensaver.
  public internal(set) var lockBackdropEnabled = false
  /// Independent of the lyrics in the island: the lock screen player is enough.
  var showsLockLyrics: Bool { lockMediaEnabled && lockLyricsEnabled }
  /// The lyrics are needed by the island, the lock screen or both: only
  /// then can a request to LRCLIB start (DESIGN.md §3.6).
  var needsLyrics: Bool { lyricsEnabled || showsLockLyrics }
  public internal(set) var hudEnabled = false
  /// Permissions the HUD needs, reread when the Settings page is visible.
  public internal(set) var hudAccessibility = false
  public internal(set) var hudInputMonitoring = false
  /// macOS did not create the keys tap: permission missing or not yet effective.
  public internal(set) var hudTapFailed = false

  var showsShelf: Bool { shelfEnabled && (isDragging || !shelf.isEmpty) }

  /// Height of the optional parts of the open island: player, next event and files.
  var extraHeight: CGFloat {
    (media == nil ? 0 : IslandGeometry.playerExtraHeight)
      + (nextEvent == nil ? 0 : IslandGeometry.eventRowHeight) + (showsShelf ? IslandGeometry.shelfHeight : 0)
  }

  func size(for presentation: IslandPresentation) -> CGSize {
    IslandGeometry.frame(
      for: presentation, notch: notch.rect, screenFrame: screenFrame, extraHeight: extraHeight
    ).size
  }
}

/// How the island opens.
public enum IslandActivation: String, Codable, Sendable, CaseIterable {
  case hover, click
}

/// Actions the view hands back to the module.
struct IslandActions {
  var tap: @MainActor () -> Void
  var send: @MainActor (MediaCommand) -> Void
  var removeFromShelf: @MainActor (UUID) -> Void
  var airDropAll: @MainActor () -> Void
  /// Seek to a position in the track (time bar).
  var seek: @MainActor (TimeInterval) -> Void = { _ in }
  /// Player heart: adds or removes the track from Music's favorites.
  var toggleFavorite: @MainActor () -> Void = {}
}

/// Panel content: always fills the frame, which matches the shape.
struct IslandView: View {
  let model: IslandModel
  let actions: IslandActions

  var body: some View {
    GeometryReader { proxy in
      // Same rounding in every state and at every morph frame.
      let shape = IslandShape(
        shoulder: IslandGeometry.shoulderRadius,
        bottomRadius: IslandGeometry.cornerRadius(height: proxy.size.height)
      )
      ZStack(alignment: .top) {
        shape.fill(.black)
        content
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
      .clipShape(shape)
      .contentShape(Rectangle())
      .onTapGesture { actions.tap() }
    }
    .animation(Self.contentAnimation, value: model.presentation)
    .animation(Self.contentAnimation, value: model.extraHeight)
    .animation(.easeOut(duration: 0.25), value: model.lyricLine)
    .animation(.easeOut(duration: 0.18), value: model.activity)
    .environment(\.colorScheme, .dark)
  }

  /// Same response as the frame's spring: content and shape arrive together.
  private static let contentAnimation = Animation.spring(response: 0.4, dampingFraction: 0.82)

  /// Usable content width: the frame minus the two top fillets.
  private func bodyWidth(for presentation: IslandPresentation) -> CGFloat {
    max(model.size(for: presentation).width - IslandGeometry.shoulderRadius * 2, 0)
  }

  @ViewBuilder private var content: some View {
    switch model.presentation {
    case .collapsed:
      EmptyView()
    case .compact:
      if let activity = model.activity {
        IslandCompactView(
          activity: activity, notchWidth: model.notch.rect.width, artwork: model.artwork,
          indicator: model.playbackIndicator
        )
        .frame(width: bodyWidth(for: .compact), height: model.notch.rect.height)
        .fixedSize()
        .transition(.blurReplace)
      }
    case .lock:
      if case .lock(let isLocked) = model.activity {
        // The lock sits on the left side, attached to the notch.
        IslandLockGlyph(isLocked: isLocked)
          .frame(width: IslandGeometry.lockEarWidth, height: model.notch.rect.height)
          .frame(width: bodyWidth(for: .lock), alignment: .leading)
          .fixedSize()
          .transition(.opacity.combined(with: .scale(0.6, anchor: .trailing)))
      }
    case .lyrics:
      VStack(spacing: 0) {
        Color.clear.frame(height: model.notch.rect.height)
        Text(verbatim: model.lyricLine ?? "")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.horizontal, TsukumoTokens.Spacing.md)
          .frame(maxWidth: .infinity)
          .frame(height: IslandGeometry.lyricsRowHeight - 4, alignment: .top)
          // Each row replaces the previous one coming into focus.
          .id(model.lyricLine)
          .transition(.blurReplace)
      }
      .frame(width: bodyWidth(for: .lyrics))
      .fixedSize()
      .transition(.opacity)
    case .hud:
      if case .hud(let kind, let level, let muted) = model.activity {
        IslandHUDRow(kind: kind, level: level, muted: muted, notchHeight: model.notch.rect.height)
          .frame(width: bodyWidth(for: .hud))
          .fixedSize()
          .transition(.opacity)
      }
    case .expanded:
      IslandExpandedView(model: model, actions: actions)
        .frame(width: bodyWidth(for: .expanded), height: model.size(for: .expanded).height)
        .fixedSize()
        // The content enters coming into focus and growing from the notch.
        .transition(.blurReplace.combined(with: .scale(0.9, anchor: .top)))
    }
  }
}

/// Volume or brightness: symbol and bar just below the notch.
private struct IslandHUDRow: View {
  let kind: HUDKind
  let level: Float
  let muted: Bool
  let notchHeight: CGFloat

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: notchHeight)
      HStack(spacing: TsukumoTokens.Spacing.sm) {
        Image(systemName: HUDMath.symbol(for: kind, level: level, muted: muted))
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 22)
          .contentTransition(.symbolEffect(.replace))
        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.22))
            Capsule().fill(.white)
              .frame(width: max(proxy.size.width * CGFloat(muted ? 0 : level), 0))
          }
        }
        .frame(height: 6)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, TsukumoTokens.Spacing.lg)
      .frame(height: IslandGeometry.lyricsRowHeight - 4, alignment: .top)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(kind == .volume ? "Volume" : "Brightness"))
    .accessibilityValue(Text(verbatim: "\(Int((muted ? 0 : level) * 100))%"))
  }
}

/// Island silhouette: two concave fillets toward the screen's top edge
/// and two round corners at the bottom. The fillets sit inside the frame, at the sides of the body.
struct IslandShape: Shape {
  var shoulder: CGFloat
  var bottomRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let shoulder = max(min(shoulder, rect.width / 4, rect.height / 2), 0)
    let left = rect.minX + shoulder
    let right = rect.maxX - shoulder
    let radius = max(min(bottomRadius, (right - left) / 2, rect.height - shoulder), 0)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder), control: CGPoint(x: left, y: rect.minY))
    path.addArc(
      tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left + radius, y: rect.maxY),
      radius: radius
    )
    path.addArc(
      tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY - radius),
      radius: radius
    )
    path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
    path.closeSubpath()
    return path
  }
}

/// Short activity on both sides of the notch.
private struct IslandCompactView: View {
  let activity: IslandActivity
  let notchWidth: CGFloat
  let artwork: NSImage?
  let indicator: IslandPlaybackIndicator

  var body: some View {
    HStack(spacing: 0) {
      leading.frame(width: IslandGeometry.earWidth)
      Color.clear.frame(width: notchWidth)
      trailing.frame(width: IslandGeometry.earWidth)
    }
    .font(.system(size: 12, weight: .semibold))
    .foregroundStyle(.white)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var leading: some View {
    switch activity {
    case .charging:
      Image(systemName: "bolt.fill").foregroundStyle(.green)
        .accessibilityLabel(Text("Power connected"))
    case .track:
      if let artwork {
        Image(nsImage: artwork).resizable().scaledToFill()
          .frame(width: 20, height: 20)
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      } else {
        Image(systemName: "music.note")
      }
    case .event:
      Image(systemName: "calendar").foregroundStyle(.red)
    case .lock, .hud:
      EmptyView()
    }
  }

  @ViewBuilder private var trailing: some View {
    switch activity {
    case .charging(let percent):
      if let percent {
        Text(verbatim: "\(percent)%").monospacedDigit().foregroundStyle(.green)
      } else {
        Image(systemName: "powerplug.fill").foregroundStyle(.green)
      }
    case .track(let title):
      // Animated on purpose while the music plays (exception to DESIGN.md §5.1), but
      // by Core Animation: SwiftUI does not redraw the island on every frame.
      Group {
        switch indicator {
        case .waveform: IslandBars(style: .waveform, isPlaying: true)
        case .bars: IslandBars(style: .equalizer(colors: IslandArtworkPalette.colors(for: artwork)), isPlaying: true)
        case .still: Image(systemName: "waveform")
        }
      }
      .accessibilityElement()
      .accessibilityLabel(Text(verbatim: title))
    case .event(let title, let minutes):
      Text(verbatim: "\(minutes) min").monospacedDigit()
        .accessibilityLabel(Text(verbatim: "\(title), \(minutes) min"))
    case .lock, .hud:
      EmptyView()
    }
  }
}

/// Open panel: battery in the notch band, track and controls below.
private struct IslandExpandedView: View {
  let model: IslandModel
  let actions: IslandActions

  var body: some View {
    VStack(spacing: 0) {
      if let media = model.media {
        // With a track the notch band stays free and below it is the player.
        Color.clear.frame(height: model.notch.rect.height)
        IslandPlayerView(model: model, actions: actions, media: media)
          .padding(.horizontal, TsukumoTokens.Spacing.xl)
          .padding(.top, 4)
          .frame(
            height: IslandGeometry.expandedBodyHeight + IslandGeometry.playerExtraHeight, alignment: .top)
      } else {
        idleHeader
        Text("Nothing playing")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(height: IslandGeometry.expandedBodyHeight)
      }

      if let event = model.nextEvent {
        IslandEventRow(event: event)
          .transition(.opacity)
      }
      if model.showsShelf {
        IslandShelfView(model: model, actions: actions)
          .transition(.opacity)
      }
    }
    .foregroundStyle(.white)
  }

  /// Without a track: in the notch band, symbol on the left and battery on the right.
  private var idleHeader: some View {
    HStack(spacing: 0) {
      Image(systemName: "music.note")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      Color.clear.frame(width: model.notch.rect.width)
      battery.frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.system(size: 11, weight: .medium))
    .padding(.horizontal, TsukumoTokens.Spacing.lg)
    .frame(height: model.notch.rect.height)
  }

  private var battery: some View {
    HStack(spacing: 4) {
      if let percent = model.power.percent {
        Text(verbatim: "\(percent)%").monospacedDigit()
      }
      Image(systemName: model.power.symbol)
        .foregroundStyle(model.power.isPluggedIn ? AnyShapeStyle(.green) : AnyShapeStyle(.white))
    }
    .accessibilityElement(children: .combine)
  }
}

/// Next event with the time and, if there is a meeting link, the button to join.
private struct IslandEventRow: View {
  let event: UpcomingEvent

  var body: some View {
    HStack(spacing: TsukumoTokens.Spacing.sm) {
      Image(systemName: "calendar").foregroundStyle(.red)
      Text(verbatim: event.title).lineLimit(1)
      Text(event.start, format: timeFormat).foregroundStyle(.secondary).monospacedDigit()
      Spacer(minLength: TsukumoTokens.Spacing.sm)
      if let url = event.joinURL {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Text("Join")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.green))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .font(.system(size: 12))
    .foregroundStyle(.white)
    .padding(.horizontal, TsukumoTokens.Spacing.lg)
    .frame(height: IslandGeometry.eventRowHeight)
  }

  private var timeFormat: Date.FormatStyle {
    Calendar.current.isDateInToday(event.start)
      ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
  }
}

/// App icons are looked up once per bundle ID: `body` runs on every
/// track update and `urlForApplication` + `icon(forFile:)` touch the disk.
@MainActor
enum PlayerIconCache {
  private static var icons: [String: NSImage?] = [:]

  static func icon(for bundleID: String) -> NSImage? {
    if let cached = icons[bundleID] { return cached }
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      .map { NSWorkspace.shared.icon(forFile: $0.path) }
    icons[bundleID] = icon
    return icon
  }
}
