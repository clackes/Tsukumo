// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A line of text with the instant at which it must be shown.
struct LyricLine: Equatable, Sendable {
  let time: TimeInterval
  let text: String
}

/// LRC format: `[mm:ss.xx] text`, also with multiple markers on the same line.
enum LyricsParser {
  static func parse(_ lrc: String) -> [LyricLine] {
    var lines: [LyricLine] = []
    for raw in lrc.split(whereSeparator: \.isNewline) {
      var rest = Substring(raw)
      var times: [TimeInterval] = []
      while rest.first == "[", let close = rest.firstIndex(of: "]") {
        // Non-time labels ([ar:…], [offset:…]) are skipped.
        if let time = seconds(rest[rest.index(after: rest.startIndex)..<close]) { times.append(time) }
        rest = rest[rest.index(after: close)...]
      }
      let text = rest.trimmingCharacters(in: .whitespaces)
      lines.append(contentsOf: times.map { LyricLine(time: $0, text: text) })
    }
    return lines.sorted { $0.time < $1.time }
  }

  private static func seconds(_ tag: Substring) -> TimeInterval? {
    let parts = tag.split(separator: ":")
    guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0, let seconds = Double(parts[1]), seconds >= 0
    else { return nil }
    return TimeInterval(minutes) * 60 + seconds
  }
}

enum LyricsTimeline {
  /// The line to show at the given position: the last one already started.
  static func line(at position: TimeInterval, in lines: [LyricLine]) -> LyricLine? {
    lines.last { $0.time <= position }
  }

  /// When the line changes: the only moment when waking up is needed.
  static func nextChange(after position: TimeInterval, in lines: [LyricLine]) -> TimeInterval? {
    lines.first { $0.time > position }?.time
  }

  /// Current position of the track, derived from the known position and the instant of the reading.
  static func position(of playing: NowPlaying, at date: Date) -> TimeInterval {
    let base = playing.position ?? 0
    return playing.isPlaying ? base + max(0, date.timeIntervalSince(playing.updatedAt)) : base
  }
}

/// Track whose lyrics to look up. The identity is title, artist and album: the duration
/// only serves to narrow the search and is not part of the key, so a track
/// update that brings it in later does not redo the request.
struct LyricsQuery: Hashable, Sendable {
  var title: String
  var artist: String
  var album: String
  var duration: Int?

  static func == (lhs: LyricsQuery, rhs: LyricsQuery) -> Bool {
    lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(title)
    hasher.combine(artist)
    hasher.combine(album)
  }
}

/// Synchronized lyrics from LRCLIB (lrclib.net), an open service with no account.
///
/// It is the module's only network call and it is **opt-in**: it starts only if the user
/// turns lyrics on, and sends the service the track's title, artist, album and duration
/// (DESIGN.md §3.6). No cookies, no disk cache.
@MainActor
final class LyricsProvider {
  static let host = "lrclib.net"
  private static let cacheLimit = 30

  private var cache: [LyricsQuery: [LyricLine]] = [:]
  private var order: [LyricsQuery] = []
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }()

  /// Exact search (`/api/get`): LRCLIB almost always answers 404 if album or duration
  /// are empty or wrong, so here they are omitted when absent.
  static func url(for query: LyricsQuery) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/api/get"
    var items = [
      URLQueryItem(name: "track_name", value: query.title),
      URLQueryItem(name: "artist_name", value: query.artist),
    ]
    if !query.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: query.album)) }
    if let duration = query.duration { items.append(URLQueryItem(name: "duration", value: String(duration))) }
    components.queryItems = items
    return components.url
  }

  /// Broad search (`/api/search`), for when the exact search finds nothing.
  static func searchURL(for query: LyricsQuery) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/api/search"
    components.queryItems = [
      URLQueryItem(name: "track_name", value: query.title),
      URLQueryItem(name: "artist_name", value: query.artist),
    ]
    return components.url
  }

  /// Maximum duration difference, in seconds, between the track and a search result.
  static let durationTolerance: TimeInterval = 3

  /// From the `/api/search` response (an array) takes the first result with timed
  /// lyrics whose duration is within the tolerance; with no known duration the first one is used.
  static func decodeSearch(_ data: Data, duration: Int?) -> [LyricLine] {
    guard let results = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
    for result in results {
      guard let synced = result["syncedLyrics"] as? String, !synced.isEmpty else { continue }
      if let duration, let candidate = (result["duration"] as? NSNumber)?.doubleValue,
        abs(candidate - Double(duration)) > durationTolerance
      {
        continue
      }
      let lines = LyricsParser.parse(synced)
      if !lines.isEmpty { return lines }
    }
    return []
  }

  /// Extracts the synchronized lines from the response; without timed lyrics there is nothing to show.
  static func decode(_ data: Data) -> [LyricLine] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let synced = root["syncedLyrics"] as? String
    else { return [] }
    return LyricsParser.parse(synced)
  }

  /// Lines of the track, empty if the lyrics are missing or the network does not respond.
  func lyrics(for query: LyricsQuery) async -> [LyricLine] {
    if let cached = cache[query] { return cached }
    guard !query.title.isEmpty, let url = Self.url(for: query) else { return [] }
    guard let (data, response) = try? await session.data(from: url),
      let status = (response as? HTTPURLResponse)?.statusCode
    else { return [] }
    // 404 = unknown lyrics: that too is remembered, to avoid requesting it on every pause.
    guard status == 200 || status == 404 else { return [] }
    var lines = status == 200 ? Self.decode(data) : []
    if status == 404 {
      // The exact search is strict about album and duration: fall back to the broad one.
      guard let found = await search(query) else { return [] }
      lines = found
    }
    cache[query] = lines
    order.append(query)
    if order.count > Self.cacheLimit { cache[order.removeFirst()] = nil }
    return lines
  }

  /// `nil` if the network does not respond (the outcome is not remembered); empty if there is no suitable lyrics.
  private func search(_ query: LyricsQuery) async -> [LyricLine]? {
    guard let url = Self.searchURL(for: query),
      let (data, response) = try? await session.data(from: url),
      let status = (response as? HTTPURLResponse)?.statusCode
    else { return nil }
    guard status == 200 else { return status == 404 ? [] : nil }
    return Self.decodeSearch(data, duration: query.duration)
  }

  func invalidate() {
    session.invalidateAndCancel()
  }
}
