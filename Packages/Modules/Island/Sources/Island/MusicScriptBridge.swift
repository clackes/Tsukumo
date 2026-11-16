// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// What Music says about the current track: the data that notifications do not carry.
struct MusicSnapshot: Sendable, Equatable {
  var title: String
  var artist: String
  var album: String
  var duration: TimeInterval
  var position: TimeInterval
  var isPlaying: Bool
  /// Artwork in the original format (JPEG, PNG or TIFF).
  var artwork: Data?

  func nowPlaying(at date: Date) -> NowPlaying {
    NowPlaying(
      title: title,
      artist: artist,
      album: album,
      isPlaying: isPlaying,
      duration: duration > 0 ? duration : nil,
      position: position,
      updatedAt: date,
      bundleID: MediaSource.music.rawValue
    )
  }
}

enum MusicScriptResult: Sendable, Equatable {
  case snapshot(MusicSnapshot)
  /// Music is stopped or the track is not readable (radio, streams).
  case nothing
  /// The user denied Automation toward Music.
  case denied
}

/// Design backend 3: AppleScript toward Music for artwork and position.
/// It starts only if the user turned it on and only if Music is already open: it never
/// launches it. One Apple Event per track change, no polling.
final class MusicScriptBridge: Sendable {
  private static let source = """
    tell application id "com.apple.Music"
      if player state is stopped then return {}
      set theTrack to current track
      set theArt to missing value
      try
        set theArt to data of artwork 1 of theTrack
      end try
      return {name of theTrack, artist of theTrack, album of theTrack, duration of theTrack, ¬
        player position, (player state as text), theArt}
    end tell
    """

  /// `errAEEventNotPermitted`: Automation consent denied.
  private static let notPermitted = -1743

  private let queue = DispatchQueue(label: "dev.local.tsukumo.island.music-script", qos: .utility)

  @MainActor static var isMusicRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: MediaSource.music.rawValue).isEmpty
  }

  /// Runs the script off the main thread: the first time it may stay
  /// waiting for the user's consent.
  func snapshot() async -> MusicScriptResult {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: Self.run())
      }
    }
  }

  private static func run() -> MusicScriptResult {
    guard let script = NSAppleScript(source: source) else { return .nothing }
    var error: NSDictionary?
    let descriptor = script.executeAndReturnError(&error)
    if let error {
      return (error[NSAppleScript.errorNumber] as? Int) == notPermitted ? .denied : .nothing
    }
    return parse(descriptor).map { .snapshot($0) } ?? .nothing
  }

  /// "Favorite" of the current track; `nil` if Music is stopped or does not respond.
  func favorite() async -> Bool? {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: Self.runFavorite(set: nil)) }
    }
  }

  /// Sets or removes the current track from favorites. Returns the state read afterwards.
  func setFavorite(_ value: Bool) async -> Bool? {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: Self.runFavorite(set: value)) }
    }
  }

  private static func runFavorite(set value: Bool?) -> Bool? {
    let change = value.map { "set favorited of current track to \($0)\n" } ?? ""
    let source = """
      tell application id "com.apple.Music"
        if player state is stopped then return missing value
        \(change)return favorited of current track
      end tell
      """
    guard let script = NSAppleScript(source: source) else { return nil }
    var error: NSDictionary?
    let descriptor = script.executeAndReturnError(&error)
    guard error == nil, descriptor.descriptorType != typeType else { return nil }
    return descriptor.booleanValue
  }

  static func parse(_ descriptor: NSAppleEventDescriptor) -> MusicSnapshot? {
    guard descriptor.numberOfItems >= 6, let title = descriptor.atIndex(1)?.stringValue, !title.isEmpty else {
      return nil
    }
    let artwork = descriptor.atIndex(7).flatMap { $0.descriptorType == typeType ? nil : $0.data }
    return MusicSnapshot(
      title: title,
      artist: descriptor.atIndex(2)?.stringValue ?? "",
      album: descriptor.atIndex(3)?.stringValue ?? "",
      duration: descriptor.atIndex(4)?.doubleValue ?? 0,
      position: descriptor.atIndex(5)?.doubleValue ?? 0,
      isPlaying: descriptor.atIndex(6)?.stringValue == "playing",
      artwork: artwork.flatMap { $0.isEmpty ? nil : $0 }
    )
  }
}
