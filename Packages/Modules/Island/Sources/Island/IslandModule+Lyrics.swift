// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ModuleKit

// MARK: - Song lyrics

extension IslandModule {
  /// Music notifications do not carry the position: it is estimated from the known one
  /// (a new track starts from zero, a paused one stays still).
  static func withEstimatedPosition(_ playing: NowPlaying?, previous: NowPlaying?) -> NowPlaying? {
    guard var playing, playing.position == nil else { return playing }
    if let previous, previous.title == playing.title, previous.bundleID == playing.bundleID {
      playing.position = LyricsTimeline.position(of: previous, at: playing.updatedAt)
    } else {
      playing.position = 0
    }
    return playing
  }

  /// Lyrics in the island. With the lock screen checkbox it is one of the only
  /// two points from which a network request can start.
  func setLyricsEnabled(_ value: Bool) {
    guard let model, model.lyricsEnabled != value else { return }
    model.lyricsEnabled = value
    try? context.settings.set(value, forKey: "lyricsEnabled", moduleID: Self.descriptor.id)
    lyricsNeedChanged()
  }

  /// To call when a checkbox that `needsLyrics` depends on changes.
  func lyricsNeedChanged() {
    if model?.needsLyrics != true {
      lyricsProvider?.invalidate()
      lyricsProvider = nil
    }
    updateLyrics()
  }

  /// Looks up the lyrics when the track changes and realigns the line on every state change.
  func updateLyrics() {
    guard let model else { return }
    guard model.needsLyrics, let media = model.media else {
      clearLyrics()
      update()
      return
    }
    let query = LyricsQuery(
      title: media.title, artist: media.artist, album: media.album, duration: media.duration.map { Int($0.rounded()) }
    )
    guard query != lyricsQuery else {
      tickLyrics()
      return
    }
    clearLyrics()
    lyricsQuery = query
    update()
    let provider = lyricsProvider ?? LyricsProvider()
    lyricsProvider = provider
    let task = Task { [weak self] in
      let lines = await provider.lyrics(for: query)
      guard !Task.isCancelled else { return }
      self?.lyricsArrived(lines, for: query)
    }
    lyricsFetchToken = context.resources.addTask(task)
  }

  private func lyricsArrived(_ lines: [LyricLine], for query: LyricsQuery) {
    if let lyricsFetchToken { context.resources.cancel(lyricsFetchToken) }
    lyricsFetchToken = nil
    guard query == lyricsQuery else { return }
    lyrics = lines
    model?.lyricLines = lines.map(\.text)
    tickLyrics()
  }

  private func clearLyrics() {
    for token in [lyricsFetchToken, lyricsTickToken].compactMap(\.self) { context.resources.cancel(token) }
    lyricsFetchToken = nil
    lyricsTickToken = nil
    lyrics = []
    lyricsQuery = nil
    model?.lyricLine = nil
    model?.lyricLines = []
    model?.lyricIndex = nil
  }

  /// Shows the current line and sleeps until the next: one wakeup per line, only while playing.
  private func tickLyrics() {
    if let lyricsTickToken { context.resources.cancel(lyricsTickToken) }
    lyricsTickToken = nil
    guard let model, let media = model.media, !lyrics.isEmpty else {
      model?.lyricLine = nil
      update()
      return
    }
    let position = LyricsTimeline.position(of: media, at: Date())
    let text = LyricsTimeline.line(at: position, in: lyrics)?.text ?? ""
    model.lyricLine = text.isEmpty ? nil : text
    model.lyricIndex = lyrics.lastIndex { $0.time <= position }
    update()
    guard media.isPlaying, let next = LyricsTimeline.nextChange(after: position, in: lyrics) else { return }
    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(next - position, 0.05)), tolerance: .milliseconds(40))
      guard !Task.isCancelled else { return }
      self?.tickLyrics()
    }
    lyricsTickToken = context.resources.addTask(task)
  }
}
