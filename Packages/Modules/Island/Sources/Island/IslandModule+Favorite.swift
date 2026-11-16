// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ModuleKit

/// Player heart: Music favorites via AppleScript. Spotify and the other
/// apps have no public way to do this, so the heart does not appear there.
/// A single request per track change, and only with the permission already granted
/// for the artwork: the heart never makes the Automation prompt appear.
extension IslandModule {
  private var canUseFavorites: Bool {
    guard let model, let media = model.media else { return false }
    return media.bundleID == MediaSource.music.rawValue && model.artworkEnabled && !model.artworkDenied
      && musicScript != nil
  }

  func refreshFavorite() {
    if let favoriteToken { context.resources.cancel(favoriteToken) }
    favoriteToken = nil
    model?.isFavorite = nil
    guard canUseFavorites, let musicScript, let title = model?.media?.title else { return }
    let task = Task { [weak self] in
      let value = await musicScript.favorite()
      guard !Task.isCancelled else { return }
      self?.favoriteArrived(value, for: title)
    }
    favoriteToken = context.resources.addTask(task)
  }

  func toggleFavorite() {
    guard canUseFavorites, let musicScript, let model, let current = model.isFavorite,
      let title = model.media?.title
    else { return }
    if let favoriteToken { context.resources.cancel(favoriteToken) }
    // The heart changes immediately; if Music does not confirm it goes back to how it was.
    model.isFavorite = !current
    let task = Task { [weak self] in
      let value = await musicScript.setFavorite(!current)
      guard !Task.isCancelled else { return }
      self?.favoriteArrived(value ?? current, for: title)
    }
    favoriteToken = context.resources.addTask(task)
  }

  private func favoriteArrived(_ value: Bool?, for title: String) {
    if let favoriteToken { context.resources.cancel(favoriteToken) }
    favoriteToken = nil
    guard let model, model.media?.title == title else { return }
    model.isFavorite = value
  }
}
