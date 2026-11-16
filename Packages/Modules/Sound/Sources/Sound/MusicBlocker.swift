// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit
import OSLog

/// Music apps to choose from to open instead of Music.
struct MusicApp: Identifiable, Equatable, Sendable {
  let bundleID: String
  let name: String
  var id: String { bundleID }

  /// Apple Music is excluded: it is exactly the one that gets blocked.
  static let known: [MusicApp] = [
    MusicApp(bundleID: "com.spotify.client", name: "Spotify"),
    MusicApp(bundleID: "com.tidal.desktop", name: "Tidal"),
    MusicApp(bundleID: "com.deezer.Deezer", name: "Deezer"),
  ]
}

/// What to do when an app launches.
enum MusicBlockAction: Equatable, Sendable {
  case ignore
  /// Quit Music and, if present, open the alternative app.
  case block(openInstead: String?)
}

/// The blocking decision, pure and without effects.
enum MusicBlockPolicy {
  static let musicBundleID = "com.apple.Music"

  static func decide(
    launched bundleID: String?,
    prefs: SoundPrefs,
    isInstalled: (String) -> Bool
  ) -> MusicBlockAction {
    guard prefs.blockMusic, bundleID == musicBundleID else { return .ignore }
    guard let alternative = prefs.alternativeBundleID, alternative != musicBundleID, isInstalled(alternative) else {
      return .block(openInstead: nil)
    }
    return .block(openInstead: alternative)
  }
}

/// Observer of app launches. It exists only with blocking on: when off
/// no observer is registered (DESIGN.md §4.2).
@MainActor
final class MusicBlocker {
  /// After this time, if Music has not quit, force it.
  static let gracePeriod: Duration = .seconds(1)

  private let resources: ResourceBag
  private var prefs: SoundPrefs
  private var observer: ResourceBag.Token?
  private let log = Logger(subsystem: "dev.local.tsukumo", category: "sound")

  init(resources: ResourceBag, prefs: SoundPrefs) {
    self.resources = resources
    self.prefs = prefs
    updateObserver()
  }

  func update(prefs: SoundPrefs) {
    self.prefs = prefs
    updateObserver()
  }

  private func updateObserver() {
    if prefs.blockMusic, observer == nil {
      let center = NSWorkspace.shared.notificationCenter
      nonisolated(unsafe) let token = center.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleID = app?.bundleIdentifier
        MainActor.assumeIsolated { self?.launched(bundleID: bundleID) }
      }
      observer = resources.add(.observer) { center.removeObserver(token) }
    } else if !prefs.blockMusic, let current = observer {
      resources.cancel(current)
      observer = nil
    }
  }

  private func launched(bundleID: String?) {
    let action = MusicBlockPolicy.decide(launched: bundleID, prefs: prefs) {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
    }
    guard case .block(let alternative) = action else { return }
    log.notice("Musica bloccata")
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: MusicBlockPolicy.musicBundleID) {
      terminate(app)
    }
    if let alternative, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: alternative) {
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
  }

  /// `terminate()` and, if needed, `forceTerminate()` after one second with a one-shot
  /// Task that the bag cancels in any case.
  private func terminate(_ app: NSRunningApplication) {
    app.terminate()
    let box = TokenBox()
    let task = Task { [weak resources] in
      try? await Task.sleep(for: Self.gracePeriod)
      guard !Task.isCancelled else { return }
      if !app.isTerminated { app.forceTerminate() }
      if let token = box.token { resources?.cancel(token) }
    }
    box.token = resources.addTask(task)
  }
}

/// The Task's own token, known only after the Task is born.
@MainActor
private final class TokenBox {
  var token: ResourceBag.Token?
}
