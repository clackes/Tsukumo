// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import ModuleKit
import SwiftUI
import Testing

@testable import Island

@Suite("Island: geometry")
struct IslandGeometryTests {
  let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
  let left = CGRect(x: 0, y: 924, width: 645.5, height: 32)
  let right = CGRect(x: 824.5, y: 924, width: 645.5, height: 32)

  private var notch: NotchMetrics {
    IslandGeometry.notch(screenFrame: screen, safeTop: 32, leftArea: left, rightArea: right, menuBarHeight: 32)
  }

  @Test("the physical notch sits between the two auxiliary areas")
  func physicalNotch() {
    #expect(notch.isPhysical)
    #expect(notch.rect == CGRect(x: 645.5, y: 924, width: 179, height: 32))
  }

  @Test("without a notch the island is a pill centered in the menu bar")
  func pill() {
    let external = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
    let metrics = IslandGeometry.notch(
      screenFrame: external, safeTop: 0, leftArea: nil, rightArea: nil, menuBarHeight: 24
    )
    #expect(!metrics.isPhysical)
    #expect(metrics.rect.midX == external.midX)
    #expect(metrics.rect.maxY == external.maxY)
    #expect(metrics.rect.height == 24)
  }

  @Test("when collapsed the frame matches the notch")
  func collapsedIsNotch() {
    #expect(IslandGeometry.frame(for: .collapsed, notch: notch.rect, screenFrame: screen) == notch.rect)
  }

  @Test("every shape stays anchored at the top, centered and within the screen")
  func framesAreAnchored() {
    for presentation in IslandPresentation.allCases {
      let frame = IslandGeometry.frame(for: presentation, notch: notch.rect, screenFrame: screen)
      #expect(frame.maxY == screen.maxY)
      if presentation != .lock { #expect(abs(frame.midX - notch.rect.midX) <= 0.5) }  // the lock grows to the left
      #expect(screen.contains(frame))
      #expect(frame.width >= notch.rect.width)
    }
  }

  @Test("the lock extends the notch only to the left")
  func lockGrowsLeft() {
    let frame = IslandGeometry.frame(for: .lock, notch: notch.rect, screenFrame: screen)
    #expect(frame.minX == notch.rect.minX - IslandGeometry.lockEarWidth - IslandGeometry.shoulderRadius)
    #expect(frame.maxX == notch.rect.maxX + IslandGeometry.shoulderRadius)
    #expect(frame.height == notch.rect.height)
  }

  @Test("near the edge the open shape doesn't leave the screen")
  func clampsToScreen() {
    let narrow = CGRect(x: 0, y: 0, width: 300, height: 200)
    let rect = CGRect(x: 10, y: 176, width: 180, height: 24)
    let frame = IslandGeometry.frame(for: .expanded, notch: rect, screenFrame: narrow)
    #expect(frame.minX >= narrow.minX && frame.maxX <= narrow.maxX)
  }

  @Test("the spring bounces little: more when opening, less when closing, and settles at 1")
  func spring() {
    for damping in [IslandGeometry.openingDamping, IslandGeometry.closingDamping] {
      #expect(IslandGeometry.springProgress(0, damping: damping) == 0)
      #expect(IslandGeometry.springProgress(1, damping: damping) == 1)
      #expect(abs(IslandGeometry.springProgress(0.98, damping: damping) - 1) < 0.005)
    }
    func peak(_ damping: Double) -> Double {
      (1...200).map { IslandGeometry.springProgress(Double($0) / 200, damping: damping) }.max() ?? 0
    }
    let opening = peak(IslandGeometry.openingDamping)
    let closing = peak(IslandGeometry.closingDamping)
    #expect(opening > 1.06 && opening < 1.1)
    #expect(closing > 1.02 && closing < 1.05)
    // The widest bounce stays within the margin allowed by the frame.
    #expect(opening < 1.2)
  }

  @Test("the silhouette has fillets at the top and stays inside the frame even when short")
  func shape() {
    for size in [CGSize(width: 179, height: 32), CGSize(width: 400, height: 124), CGSize(width: 20, height: 6)] {
      let rect = CGRect(origin: .zero, size: size)
      let path = IslandShape(shoulder: IslandGeometry.shoulderRadius, bottomRadius: 36).path(in: rect)
      #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
      #expect(abs(path.boundingRect.width - size.width) < 0.01)
      // At the top the silhouette touches the frame's edges; below the fillets the body is narrower.
      #expect(path.contains(CGPoint(x: 0.5, y: 0.1)))
      #expect(!path.contains(CGPoint(x: 0.5, y: size.height - 0.5)))
      #expect(path.contains(CGPoint(x: size.width / 2, y: size.height / 2)))
    }
  }

  @Test("corners and halo follow the frame height")
  func radiusAndHalo() {
    // The radius is that of the open island as soon as the shape is tall enough to contain it.
    #expect(IslandGeometry.cornerRadius(height: 32) == 16)
    #expect(IslandGeometry.cornerRadius(height: 72) == IslandGeometry.expandedCornerRadius)
    #expect(IslandGeometry.cornerRadius(height: 300) == IslandGeometry.expandedCornerRadius)
    #expect(IslandGeometry.openness(height: 32, notchHeight: 32) == 0)
    #expect(IslandGeometry.openness(height: 400, notchHeight: 32) == 1)

    let frame = IslandGeometry.frame(for: .expanded, notch: notch.rect, screenFrame: screen)
    let halo = IslandGeometry.haloFrame(around: frame)
    #expect(halo.maxY == frame.maxY)
    #expect(halo.minX == frame.minX - IslandGeometry.haloMargin && halo.minY == frame.minY - IslandGeometry.haloMargin)
  }

  @Test("the morph never exceeds the largest shape and stays on pixels")
  func interpolation() {
    let from = notch.rect
    let target = IslandGeometry.frame(for: .expanded, notch: notch.rect, screenFrame: screen)
    for step in 0...10 {
      let frame = IslandGeometry.interpolate(from: from, to: target, progress: Double(step) / 10, scale: 2)
      #expect(target.insetBy(dx: -0.5, dy: -0.5).contains(frame))
      #expect(frame.maxY == screen.maxY)
      #expect((frame.minX * 2).rounded() == frame.minX * 2)
    }
    #expect(IslandGeometry.interpolate(from: from, to: target, progress: 1, scale: 2) == target)
  }

  @Test("the shape depends on openness, activity and the presence of the notch")
  func presentation() {
    #expect(IslandGeometry.presentation(isOpen: false, activity: nil, hasNotch: true) == .collapsed)
    #expect(IslandGeometry.presentation(isOpen: true, activity: nil, hasNotch: true) == .expanded)
    #expect(IslandGeometry.presentation(isOpen: false, activity: .charging(percent: 80), hasNotch: true) == .compact)
    #expect(IslandGeometry.presentation(isOpen: true, activity: nil, hasNotch: false) == .collapsed)
    #expect(IslandGeometry.presentation(isOpen: true, activity: .track(title: "x"), hasNotch: false) == .expanded)
  }
}

@Suite("Island: battery and tracks")
struct IslandSourcesTests {
  @Test("the IOKit description becomes percentage and state")
  func power() throws {
    let description: [String: Any] = [
      kIOPSTypeKey: kIOPSInternalBatteryType,
      kIOPSCurrentCapacityKey: 41,
      kIOPSMaxCapacityKey: 100,
      kIOPSIsChargingKey: true,
      kIOPSPowerSourceStateKey: kIOPSACPowerValue,
    ]
    let status = try #require(PowerStatus.parse(description))
    #expect(status == PowerStatus(percent: 41, isCharging: true, isPluggedIn: true))
    #expect(status.symbol == "battery.100percent.bolt")
    #expect(PowerStatus.parse([kIOPSTypeKey: "UPS"]) == nil)
    #expect(PowerStatus(percent: 30).symbol == "battery.25percent")
  }

  @Test("Spotify notification: duration in milliseconds, position in seconds")
  func spotify() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let info: [AnyHashable: Any] = [
      "Player State": "Playing", "Name": "Track", "Artist": "Artist", "Album": "Disk",
      "Duration": 200_000, "Playback Position": 50.0,
    ]
    let playing = try #require(MediaNotificationParser.parse(source: .spotify, userInfo: info, now: now))
    #expect(playing.title == "Track" && playing.artist == "Artist" && playing.isPlaying)
    #expect(playing.duration == 200 && playing.position == 50)
    let interval = try #require(playing.progressInterval)
    #expect(interval.lowerBound == now.addingTimeInterval(-50))
    #expect(interval.upperBound == now.addingTimeInterval(150))
  }

  @Test("Music notification: no progress when paused; no track when stopped")
  func music() throws {
    let now = Date(timeIntervalSince1970: 0)
    let paused: [AnyHashable: Any] = ["Player State": "Paused", "Name": "Track", "Total Time": 180_000]
    let playing = try #require(MediaNotificationParser.parse(source: .music, userInfo: paused, now: now))
    #expect(!playing.isPlaying && playing.duration == 180 && playing.progressInterval == nil)
    #expect(MediaNotificationParser.parse(source: .music, userInfo: ["Player State": "Stopped"], now: now) == nil)
    #expect(MediaNotificationParser.parse(source: .music, userInfo: nil, now: now) == nil)
  }
}

@Suite("Island: shelf")
struct IslandShelfTests {
  private let notch = CGRect(x: 645.5, y: 924, width: 179, height: 32)
  private let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)

  @Test("no duplicates, files only, and past the limit the oldest drop out")
  func adding() throws {
    let first = URL(fileURLWithPath: "/tmp/a.txt")
    let second = URL(fileURLWithPath: "/tmp/b.txt")
    let web = try #require(URL(string: "https://example.com/c.txt"))
    var items = Shelf.adding([first, second, first, web], to: [])
    #expect(items.map(\.url) == [first, second])
    items = Shelf.adding([URL(fileURLWithPath: "/tmp/./a.txt")], to: items)
    #expect(items.count == 2)
    items = Shelf.adding([URL(fileURLWithPath: "/tmp/c.txt")], to: items, limit: 2)
    #expect(items.map(\.url.lastPathComponent) == ["b.txt", "c.txt"])
  }

  @Test("bookmarks find the file again and discard vanished ones")
  func bookmarks() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-shelf-\(UUID().uuidString).txt")
    try Data("x".utf8).write(to: url)
    let data = Shelf.bookmarks(for: [ShelfItem(url: url)])
    #expect(Shelf.items(from: data).map(\.url.lastPathComponent) == [url.lastPathComponent])
    try FileManager.default.removeItem(at: url)
    #expect(Shelf.items(from: data).isEmpty)
    #expect(Shelf.items(from: [Data("not a bookmark".utf8)]).isEmpty)
  }

  @Test("with files the open island grows by the shelf row, always anchored at the top")
  func shelfFrame() {
    let plain = IslandGeometry.frame(for: .expanded, notch: notch, screenFrame: screen)
    let shelf = IslandGeometry.frame(
      for: .expanded, notch: notch, screenFrame: screen, extraHeight: IslandGeometry.shelfHeight)
    #expect(shelf.height == plain.height + IslandGeometry.shelfHeight)
    #expect(shelf.maxY == plain.maxY && shelf.width == plain.width)
    #expect(
      IslandGeometry.frame(for: .compact, notch: notch, screenFrame: screen, extraHeight: 100).height == notch.height
    )
  }

  @Test("the hot zone contains the notch; the AirDrop zone is at the bottom right")
  func zones() {
    #expect(IslandGeometry.hotZone(notch: notch).contains(notch))
    let size = CGSize(width: 400, height: 202)
    #expect(IslandGeometry.isAirDropZone(CGPoint(x: 350, y: 30), in: size))
    #expect(!IslandGeometry.isAirDropZone(CGPoint(x: 396, y: 30), in: size))
    #expect(!IslandGeometry.isAirDropZone(CGPoint(x: 100, y: 30), in: size))
    #expect(!IslandGeometry.isAirDropZone(CGPoint(x: 350, y: 150), in: size))
  }
}

@Suite("Island: calendar")
struct IslandCalendarTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func event(_ id: String, in minutes: Double, lasting: Double = 30) -> UpcomingEvent {
    let start = now.addingTimeInterval(minutes * 60)
    return UpcomingEvent(id: id, title: id, start: start, end: start.addingTimeInterval(lasting * 60))
  }

  @Test("recognizes Meet, Zoom and Teams links and ignores the rest")
  func joinLinks() {
    #expect(
      CalendarLogic.joinURL(in: [nil, "Room 3", "Join: https://meet.google.com/abc-defg-hij thanks"])?.absoluteString
        == "https://meet.google.com/abc-defg-hij"
    )
    #expect(CalendarLogic.joinURL(in: ["https://us02web.zoom.us/j/123456?pwd=x"])?.host == "us02web.zoom.us")
    #expect(
      CalendarLogic.joinURL(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting>"])?.host
        == "teams.microsoft.com"
    )
    #expect(CalendarLogic.joinURL(in: ["https://example.com/meet", "http://meet.google.com/abc-defg-hij"]) == nil)
    // A host that starts like a known one is not mistaken for it.
    #expect(CalendarLogic.joinURL(in: ["https://meet.google.com.evil.example/abc"]) == nil)
  }

  @Test("the next event is the first unfinished one; one that started recently still counts")
  func nextEvent() {
    let events = [event("late", in: 120), event("soon", in: 20), event("just now", in: -3), event("old", in: -40)]
    #expect(CalendarLogic.next(from: events, now: now)?.id == "just now")
    #expect(CalendarLogic.next(from: [event("old", in: -15, lasting: 60)], now: now) == nil)
    #expect(CalendarLogic.next(from: [], now: now) == nil)
  }

  @Test("recalculations fall at the announcement, at the start and at the end of the grace period")
  func refreshBoundaries() {
    let soon = event("x", in: 20)
    #expect(CalendarLogic.nextRefresh(for: soon, now: now) == soon.start.addingTimeInterval(-300))
    #expect(CalendarLogic.nextRefresh(for: soon, now: soon.start.addingTimeInterval(-60)) == soon.start)
    #expect(CalendarLogic.nextRefresh(for: soon, now: soon.start) == soon.start.addingTimeInterval(600))
    #expect(CalendarLogic.nextRefresh(for: nil, now: now) == now.addingTimeInterval(86400))
    #expect(
      CalendarLogic.nextRefresh(for: event("far", in: 3 * 24 * 60), now: now) == now.addingTimeInterval(86400))
  }

  @Test("the announcement applies only in the last five minutes before the start")
  func announce() {
    #expect(CalendarLogic.minutesUntilStart(of: event("x", in: 5), now: now) == 5)
    #expect(CalendarLogic.minutesUntilStart(of: event("x", in: 0.3), now: now) == 1)
    #expect(CalendarLogic.minutesUntilStart(of: event("x", in: 6), now: now) == nil)
    #expect(CalendarLogic.minutesUntilStart(of: event("x", in: -1), now: now) == nil)
  }
}

@Suite("Island: HUD and lock screen")
struct IslandHUDTests {
  private func data1(key: Int, down: Bool) -> Int { (key << 16) | ((down ? 0xA : 0xB) << 8) }

  @Test("media keys are recognized from data1; other events are ignored")
  func parse() {
    let up = MediaKeyPress.parse(subtype: 8, data1: data1(key: 0, down: true), modifiers: [])
    #expect(up == MediaKeyPress(key: .soundUp, isDown: true, fine: false, opensSettings: false))
    #expect(MediaKeyPress.parse(subtype: 8, data1: data1(key: 7, down: false), modifiers: [])?.isDown == false)
    #expect(MediaKeyPress.parse(subtype: 8, data1: data1(key: 3, down: true), modifiers: [])?.key == .brightnessDown)
    #expect(MediaKeyPress.parse(subtype: 8, data1: data1(key: 16, down: true), modifiers: []) == nil)
    #expect(MediaKeyPress.parse(subtype: 7, data1: data1(key: 0, down: true), modifiers: []) == nil)
    let fine = MediaKeyPress.parse(subtype: 8, data1: data1(key: 1, down: true), modifiers: [.option, .shift])
    #expect(fine?.fine == true && fine?.opensSettings == false)
  }

  @Test("⌥ alone is left to the system; the rest is consumed only for what we know how to adjust")
  func policy() throws {
    let policy = HUDPolicy()
    let volume = try #require(MediaKeyPress.parse(subtype: 8, data1: data1(key: 0, down: true), modifiers: []))
    let brightness = try #require(MediaKeyPress.parse(subtype: 8, data1: data1(key: 2, down: true), modifiers: []))
    let settings = try #require(
      MediaKeyPress.parse(subtype: 8, data1: data1(key: 0, down: true), modifiers: [.option])
    )
    #expect(!policy.handles(volume) && !policy.handles(brightness))
    policy.set(HUDPolicy.State(volume: true, brightness: false))
    #expect(policy.handles(volume) && !policy.handles(brightness) && !policy.handles(settings))
  }

  @Test("steps stay on the grid and within [0, 1]")
  func steps() {
    #expect(HUDMath.stepped(0.5, up: true, fine: false) == 0.5625)
    #expect(HUDMath.stepped(0.5, up: false, fine: true) == 0.484375)
    #expect(HUDMath.stepped(1, up: true, fine: false) == 1)
    #expect(HUDMath.stepped(0, up: false, fine: false) == 0)
    #expect(HUDMath.stepped(0.51, up: true, fine: false) == 0.5625)
    // The brightness ramp arrives exact and never goes back.
    var previous: Float = 0.5
    for step in 1...HUDMath.rampSteps {
      let value = HUDMath.ramp(from: 0.5, to: 0.5625, step: step)
      #expect(value >= previous && value <= 0.5625)
      previous = value
    }
    #expect(previous == 0.5625)
    #expect(HUDMath.symbol(for: .volume, level: 0.8, muted: true) == "speaker.slash.fill")
    #expect(HUDMath.symbol(for: .volume, level: 0.8, muted: false) == "speaker.wave.3.fill")
    #expect(HUDMath.symbol(for: .brightness, level: 0.2, muted: false) == "sun.min.fill")
  }

  @Test("the HUD has its own shape under the notch; the lock has its own, to the left of the notch")
  func presentation() {
    let hud = IslandActivity.hud(kind: .volume, level: 0.5, muted: false)
    #expect(IslandGeometry.presentation(isOpen: false, activity: hud, hasNotch: true, showsLyrics: true) == .hud)
    #expect(IslandGeometry.presentation(isOpen: false, activity: .lock(isLocked: true), hasNotch: true) == .lock)
    #expect(IslandGeometry.presentation(isOpen: true, activity: hud, hasNotch: true) == .expanded)
  }
}

@MainActor
@Suite("Island: song lyrics")
struct IslandLyricsTests {
  private let lrc = """
    [ar: Artista]
    [00:01.50] first
    [00:04.00][00:10.25] chorus
    [00:07.00]
    line without timestamp
    [01:02.03] last
    """

  @Test("the LRC format becomes ordered lines; tags and lines without a timestamp are skipped")
  func parse() {
    let lines = LyricsParser.parse(lrc)
    #expect(lines.map(\.time) == [1.5, 4, 7, 10.25, 62.03])
    #expect(lines.map(\.text) == ["first", "chorus", "", "chorus", "last"])
    #expect(LyricsParser.parse("").isEmpty)
  }

  @Test("current line and next change from the position")
  func timeline() {
    let lines = LyricsParser.parse(lrc)
    #expect(LyricsTimeline.line(at: 0, in: lines) == nil)
    #expect(LyricsTimeline.line(at: 5, in: lines)?.text == "chorus")
    #expect(LyricsTimeline.nextChange(after: 5, in: lines) == 7)
    #expect(LyricsTimeline.nextChange(after: 100, in: lines) == nil)
  }

  private func track(_ title: String, playing: Bool, at offset: Double, position: Double? = nil) -> NowPlaying {
    NowPlaying(
      title: title, artist: "", album: "", isPlaying: playing, duration: 200, position: position,
      updatedAt: Date(timeIntervalSince1970: 100 + offset), bundleID: "com.apple.Music"
    )
  }

  @Test("the position advances only while the track plays")
  func position() {
    let later = Date(timeIntervalSince1970: 112)
    #expect(LyricsTimeline.position(of: track("x", playing: true, at: 0, position: 30), at: later) == 42)
    #expect(LyricsTimeline.position(of: track("x", playing: false, at: 0, position: 30), at: later) == 30)
  }

  @Test("without a position in the notification: a new track starts from zero, the same track continues")
  func estimatedPosition() {
    let first = IslandModule.withEstimatedPosition(track("a", playing: true, at: 0), previous: nil)
    #expect(first?.position == 0)
    let paused = IslandModule.withEstimatedPosition(track("a", playing: false, at: 20), previous: first)
    #expect(paused?.position == 20)
    let resumed = IslandModule.withEstimatedPosition(track("a", playing: true, at: 50), previous: paused)
    #expect(resumed?.position == 20)
    #expect(IslandModule.withEstimatedPosition(track("b", playing: true, at: 60), previous: resumed)?.position == 0)
    let known = track("a", playing: true, at: 0, position: 9)
    #expect(IslandModule.withEstimatedPosition(known, previous: nil)?.position == 9)
  }

  @Test("the request goes only to lrclib.net over https and a response without timed lyrics is empty")
  func request() throws {
    let query = LyricsQuery(title: "Track & co", artist: "Artist", album: "Disk", duration: 200)
    let url = try #require(LyricsProvider.url(for: query))
    #expect(url.scheme == "https" && url.host == "lrclib.net" && url.path == "/api/get")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.first { $0.name == "track_name" }?.value == "Track & co")
    #expect(items.first { $0.name == "duration" }?.value == "200")
    #expect(LyricsProvider.decode(Data(#"{"syncedLyrics": "[00:01.00] hello"}"#.utf8)).count == 1)
    #expect(LyricsProvider.decode(Data(#"{"plainLyrics": "hello", "syncedLyrics": null}"#.utf8)).isEmpty)
    #expect(LyricsProvider.decode(Data("no".utf8)).isEmpty)
  }

  @Test("the lyrics line has its own shape and doesn't light the halo")
  func presentation() {
    #expect(IslandGeometry.presentation(isOpen: false, activity: nil, hasNotch: true, showsLyrics: true) == .lyrics)
    let charging = IslandActivity.charging(percent: 50)
    #expect(
      IslandGeometry.presentation(isOpen: false, activity: charging, hasNotch: true, showsLyrics: true) == .compact
    )
    #expect(IslandGeometry.presentation(isOpen: true, activity: nil, hasNotch: true, showsLyrics: true) == .expanded)
    let notch = CGRect(x: 751, y: 1074, width: 208, height: 38)
    let frame = IslandGeometry.frame(
      for: .lyrics, notch: notch, screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1112)
    )
    #expect(frame.height == notch.height + IslandGeometry.lyricsRowHeight)
    #expect(IslandGeometry.haloOpacity(height: frame.height, notchHeight: notch.height) == 0)
    #expect(IslandGeometry.haloOpacity(height: notch.height + IslandGeometry.expandedBodyHeight, notchHeight: 38) == 1)
  }
}

@Suite("Island: Music via AppleScript")
struct IslandMusicScriptTests {
  private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
    return list
  }

  @Test("the Music response becomes track, position and artwork")
  func parse() throws {
    let art = Data([0xFF, 0xD8, 0xFF])
    let descriptor = list([
      .init(string: "Track"), .init(string: "Artist"), .init(string: "Disk"), .init(double: 200),
      .init(double: 42.5), .init(string: "playing"), .init(descriptorType: typeJPEG, data: art) ?? .null(),
    ])
    let snapshot = try #require(MusicScriptBridge.parse(descriptor))
    #expect(snapshot.title == "Track" && snapshot.artist == "Artist" && snapshot.album == "Disk")
    #expect(snapshot.duration == 200 && snapshot.position == 42.5 && snapshot.isPlaying)
    #expect(snapshot.artwork == art)
    let playing = snapshot.nowPlaying(at: Date(timeIntervalSince1970: 100))
    #expect(playing.bundleID == "com.apple.Music" && playing.progressInterval != nil)
  }

  @Test("without artwork or with the player stopped nothing is made up")
  func empty() throws {
    let missing = NSAppleEventDescriptor(typeCode: 0x6D73_6E67)  // 'msng': missing value
    let descriptor = list([
      .init(string: "Track"), .init(string: ""), .init(string: ""), .init(double: 0),
      .init(double: 0), .init(string: "paused"), missing,
    ])
    let snapshot = try #require(MusicScriptBridge.parse(descriptor))
    #expect(snapshot.artwork == nil && !snapshot.isPlaying)
    #expect(snapshot.nowPlaying(at: Date()).duration == nil)
    #expect(MusicScriptBridge.parse(list([])) == nil)
  }
}

@MainActor
@Suite("Island: lifecycle and zero cost")
struct IslandModuleTests {
  private let id = IslandModule.descriptor.id

  @Test("start → stop leaves no resources or instances")
  func lifecycle() async throws {
    let registry = ModuleRegistry(events: EventBus())
    try registry.register(IslandModule.self)
    #expect(registry.module(id) == nil)

    for _ in 0..<2 {
      try await registry.enable(id)
      let resources = try #require(registry.resources(of: id))
      #expect(resources.snapshot[.timer] == nil)
      // At rest there is at most the shelf's click monitor, never the drag one.
      #expect((resources.snapshot[.monitor] ?? 0) <= 1)
      #expect(resources.snapshot[.other] == nil)
      #expect(resources.snapshot[.window] == 1)

      await registry.disable(id)
      #expect(resources.isEmpty)
      #expect(registry.liveCount == 0)
    }
  }
}
