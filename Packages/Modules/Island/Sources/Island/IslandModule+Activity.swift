// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ModuleKit

/// Island activities: the temporary ones (charging, new track, event, HUD,
/// unlock) and the rest state (lock, music playing).
extension IslandModule {
  /// Shows an activity for a few seconds; a single one-shot task, in the `ResourceBag`.
  /// Null `duration`: the activity stays until another replaces it (screen locked).
  func show(_ activity: IslandActivity, for duration: Duration? = IslandModule.activityDuration) {
    guard let model else { return }
    if let activityToken { context.resources.cancel(activityToken) }
    activityToken = nil
    model.activity = activity
    update()
    guard let duration else { return }
    let task = Task { [weak self] in
      try? await Task.sleep(for: duration, tolerance: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.clearActivity()
    }
    activityToken = context.resources.addTask(task)
  }

  func clearActivity() {
    if let activityToken { context.resources.cancel(activityToken) }
    activityToken = nil
    model?.activity = restingActivity
    update()
  }

  /// What the island shows when there is no temporary activity: the lock while
  /// the screen is locked, otherwise the music **while it plays** (artwork and waves),
  /// unless the lyrics scroll in its place.
  var restingActivity: IslandActivity? {
    guard let model else { return nil }
    if isScreenLocked, model.lockEnabled { return .lock(isLocked: true) }
    if let media = model.media, media.isPlaying, !model.showsLyrics { return .track(title: media.title) }
    return nil
  }

  /// Realigns the rest state (music started, stopped, lyrics appeared).
  /// Does not touch a temporary activity in progress nor the lock.
  func alignRestingActivity() {
    guard let model, activityToken == nil else { return }
    switch model.activity {
    case nil, .track:
      let resting = restingActivity
      if model.activity != resting { model.activity = resting }
    default:
      return
    }
  }
}
