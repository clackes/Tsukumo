// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit

/// Artwork of the playing track: which image to show, and when the cover view animates.
extension IslandModule {
  func updateArtwork(for playing: NowPlaying?) {
    guard let model else { return }
    guard let playing else {
      artworkKey = nil
      setArtwork(nil, track: "")
      return
    }
    let track = Self.trackKey(playing.title, playing.album)
    // Backend 1 carries the artwork of every app: no Apple Event to Music.
    if let data = playing.artwork {
      let key = track + "\u{1F}\(data.count)"
      if key != artworkKey {
        artworkKey = key
        // A sharper copy of the same track's artwork replaces the image without a new transition.
        setArtwork(NSImage(data: data), track: track)
      }
      return
    }
    if track != model.artworkID, "none:" + track != model.artworkID, artworkKey != track {
      artworkKey = track
      // The previous artwork stays until the new one arrives, so a track change animates once.
      scheduleArtworkClear(for: track)
    }
    guard playing.bundleID == MediaSource.music.rawValue else { return }
    // Even with an unchanged track the position is needed: the Music notification does not carry it.
    if model.artworkEnabled, !model.artworkDenied { fetchMusicSnapshot(adoptTrack: false) }
  }

  /// Shows `image` for `track`. The cover view animates only when the track it belongs to changes.
  func setArtwork(_ image: NSImage?, track: String) {
    guard let model else { return }
    if let artworkClearToken { context.resources.cancel(artworkClearToken) }
    artworkClearToken = nil
    model.artwork = image
    model.artworkID = image == nil ? "none:" + track : track
  }

  /// If no artwork arrives for `track` shortly, shows the placeholder.
  func scheduleArtworkClear(for track: String) {
    if let artworkClearToken { context.resources.cancel(artworkClearToken) }
    let task = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1500), tolerance: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.setArtwork(nil, track: track)
    }
    artworkClearToken = context.resources.addTask(task)
  }
}
