// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import Island

@Suite("Island: mediaremote-adapter backend")
struct AdapterMediaBackendTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func line(_ text: String) -> Data { Data(text.utf8) }

  @Test("NIL means nothing is playing")
  func nilLine() {
    #expect(AdapterLineParser.parse(line("NIL"), now: now) == .update(nil))
  }

  @Test("a data line becomes the track, with position at the timestamp and artwork")
  func dataLine() throws {
    let stamp = (now.timeIntervalSince1970 - 2) * 1_000_000
    let artwork = Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
    let json = """
      {"type":"data","diff":false,"payload":{"title":"Song","artist":"Band","album":"LP",\
      "isPlaying":true,"durationMicros":200000000,"elapsedTimeMicros":42500000,\
      "timestampEpochMicros":\(stamp),"bundleIdentifier":"com.spotify.client",\
      "artworkDataBase64":"\(artwork)","artworkMimeType":"image/jpeg","playbackRate":1}}
      """
    guard case .update(let playing?) = AdapterLineParser.parse(line(json), now: now) else {
      Issue.record("line not recognized")
      return
    }
    #expect(playing.title == "Song")
    #expect(playing.artist == "Band")
    #expect(playing.album == "LP")
    #expect(playing.isPlaying)
    #expect(playing.duration == 200)
    #expect(playing.position == 42.5)
    #expect(abs(playing.updatedAt.timeIntervalSince(now) + 2) < 0.001)
    #expect(playing.bundleID == "com.spotify.client")
    #expect(playing.artwork == Data([0xFF, 0xD8, 0xFF]))
  }

  @Test("null fields and an empty title don't produce a track")
  func nullFields() {
    let empty = #"{"type":"data","payload":{"title":null,"artist":null,"isPlaying":null}}"#
    #expect(AdapterLineParser.parse(line(empty), now: now) == .update(nil))
    let minimal = #"{"type":"data","payload":{"title":"Title only"}}"#
    guard case .update(let playing?) = AdapterLineParser.parse(line(minimal), now: now) else {
      Issue.record("minimal line not recognized")
      return
    }
    #expect(playing.artist.isEmpty)
    #expect(!playing.isPlaying)
    #expect(playing.duration == nil)
    #expect(playing.updatedAt == now)
  }

  @Test("broken lines or lines of another type are ignored")
  func ignored() {
    #expect(AdapterLineParser.parse(line(""), now: now) == .ignored)
    #expect(AdapterLineParser.parse(line("{not json"), now: now) == .ignored)
    #expect(AdapterLineParser.parse(line(#"{"type":"error","payload":{}}"#), now: now) == .ignored)
  }

  @Test("a timestamp in the future doesn't move progress forward")
  func futureStamp() {
    let stamp = (now.timeIntervalSince1970 + 5) * 1_000_000
    let json = #"{"payload":{"title":"T","timestampEpochMicros":"# + "\(stamp)" + "}}"
    guard case .update(let playing?) = AdapterLineParser.parse(line(json), now: now) else {
      Issue.record("line not recognized")
      return
    }
    #expect(playing.updatedAt == now)
  }

  @Test("commands use the names read from the adapter on stdin")
  @MainActor
  func commands() {
    #expect(AdapterMediaBackend.inlineCommand(.togglePlayPause) == "toggle_play_pause")
    #expect(AdapterMediaBackend.inlineCommand(.next) == "next_track")
    #expect(AdapterMediaBackend.inlineCommand(.previous) == "previous_track")
  }
}
