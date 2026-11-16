// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import Island

@Suite("Island: lyrics requests and time bar")
@MainActor
struct IslandLyricsRequestTests {
  private func track(_ title: String, playing: Bool, position: Double?) -> NowPlaying {
    NowPlaying(
      title: title, artist: "", album: "", isPlaying: playing, duration: 200, position: position,
      updatedAt: Date(timeIntervalSince1970: 100), bundleID: "com.apple.Music"
    )
  }

  @Test("the time bar exposes position and 10-second jumps for accessibility")
  func seekBarAccessibility() {
    let media = track("x", playing: true, position: 30)
    let now = Date(timeIntervalSince1970: 112)
    #expect(LockSeekBar.position(of: media, at: now, duration: 200) == 42)
    #expect(LockSeekBar.accessibilityValue(media: media, duration: 200, now: now) == "0:42 of 3:20")
    #expect(LockSeekBar.seekTarget(from: 195, by: LockSeekBar.accessibilityStep, duration: 200) == 200)
    #expect(LockSeekBar.seekTarget(from: 4, by: -LockSeekBar.accessibilityStep, duration: 200) == 0)
    #expect(LockSeekBar.fraction(position: 50, duration: 200) == 0.25)
    #expect(LockSeekBar.fraction(position: 50, duration: 0) == 0)
  }

  @Test("the exact search omits an empty album and a missing duration")
  func requestOmitsEmptyFields() throws {
    let query = LyricsQuery(title: "Track", artist: "Artist", album: "", duration: nil)
    let url = try #require(LyricsProvider.url(for: query))
    let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
    #expect(names == ["track_name", "artist_name"])
  }

  @Test("the broad search goes to lrclib.net and picks the first result with timed lyrics and a close duration")
  func searchFallback() throws {
    let query = LyricsQuery(title: "Track", artist: "Artist", album: "", duration: 200)
    let url = try #require(LyricsProvider.searchURL(for: query))
    #expect(url.scheme == "https" && url.host == "lrclib.net" && url.path == "/api/search")
    let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
    #expect(names == ["track_name", "artist_name"])

    let json = #"""
      [
        {"duration": 150, "syncedLyrics": "[00:01.00] far"},
        {"duration": 201.4, "syncedLyrics": null},
        {"duration": 202.5, "syncedLyrics": "[00:02.00] right"},
        {"duration": 200, "syncedLyrics": "[00:03.00] after"}
      ]
      """#
    let lines = LyricsProvider.decodeSearch(Data(json.utf8), duration: 200)
    #expect(lines.map(\.text) == ["right"])
    // Without a known duration the first one with timed lyrics is used.
    #expect(LyricsProvider.decodeSearch(Data(json.utf8), duration: nil).map(\.text) == ["far"])
    #expect(LyricsProvider.decodeSearch(Data("[]".utf8), duration: 200).isEmpty)
    #expect(LyricsProvider.decodeSearch(Data("no".utf8), duration: nil).isEmpty)
  }

  @Test("the search key doesn't depend on the duration")
  func queryKeyIgnoresDuration() {
    let withoutDuration = LyricsQuery(title: "A", artist: "B", album: "C", duration: nil)
    let withDuration = LyricsQuery(title: "A", artist: "B", album: "C", duration: 200)
    #expect(withoutDuration == withDuration)
    #expect(Set([withoutDuration, withDuration]).count == 1)
    #expect(withDuration != LyricsQuery(title: "A", artist: "B", album: "D", duration: 200))
  }
}
