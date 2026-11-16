// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ModuleKit

/// Playing track, as the island sees it.
struct NowPlaying: Equatable, Sendable {
  var title: String
  var artist: String
  var album: String
  var isPlaying: Bool
  var duration: TimeInterval?
  /// Position at time `updatedAt`; progress is computed from here, without timers.
  var position: TimeInterval?
  var updatedAt: Date
  var bundleID: String
  /// Encoded artwork (JPEG or PNG), when the backend provides it.
  var artwork: Data?

  /// Interval for the progress bar, only if the track is playing and the position is known.
  var progressInterval: ClosedRange<Date>? {
    guard isPlaying, let duration, let position, duration > 0, position < duration else { return nil }
    let start = updatedAt.addingTimeInterval(-position)
    return start...start.addingTimeInterval(duration)
  }
}

enum MediaCommand: UInt32, Sendable {
  case togglePlayPause = 2
  case next = 4
  case previous = 5
}

/// Apps that announce the track with distributed notifications.
enum MediaSource: String, Sendable, CaseIterable {
  case music = "com.apple.Music"
  case spotify = "com.spotify.client"

  var notificationName: Notification.Name {
    switch self {
    case .music: Notification.Name("com.apple.Music.playerInfo")
    case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
    }
  }
}

/// Source of the "Now Playing" (DESIGN.md §2.1). The implementations register
/// every resource in the `ResourceBag` they receive.
@MainActor
protocol MediaBackend: AnyObject {
  func start(in resources: ResourceBag, onChange: @escaping @MainActor @Sendable (NowPlaying?) -> Void)
  @discardableResult func send(_ command: MediaCommand) -> Bool
  /// Moves playback to `seconds` from the start of the track.
  @discardableResult func seek(to seconds: TimeInterval) -> Bool
  var canSendCommands: Bool { get }
}

enum MediaNotificationParser {
  /// `nil` when the player is stopped or the notification does not describe a track.
  static func parse(source: MediaSource, userInfo: [AnyHashable: Any]?, now: Date) -> NowPlaying? {
    guard let userInfo, let state = userInfo["Player State"] as? String, state != "Stopped" else { return nil }
    guard let title = userInfo["Name"] as? String, !title.isEmpty else { return nil }
    let milliseconds = number(userInfo[source == .music ? "Total Time" : "Duration"])
    return NowPlaying(
      title: title,
      artist: userInfo["Artist"] as? String ?? "",
      album: userInfo["Album"] as? String ?? "",
      isPlaying: state == "Playing",
      duration: milliseconds.flatMap { $0 > 0 ? $0 / 1000 : nil },
      position: number(userInfo["Playback Position"]),
      updatedAt: now,
      bundleID: source.rawValue
    )
  }

  private static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }
}

/// Design backend 2: distributed notifications from Music and Spotify. No
/// permission and no child process; the state arrives at the first track change.
@MainActor
final class NotificationMediaBackend: MediaBackend {
  func start(in resources: ResourceBag, onChange: @escaping @MainActor @Sendable (NowPlaying?) -> Void) {
    let center = DistributedNotificationCenter.default()
    for source in MediaSource.allCases {
      nonisolated(unsafe) let observer = center.addObserver(
        forName: source.notificationName, object: nil, queue: .main
      ) { notification in
        let parsed = MediaNotificationParser.parse(source: source, userInfo: notification.userInfo, now: Date())
        MainActor.assumeIsolated { onChange(parsed) }
      }
      resources.add(.observer) { center.removeObserver(observer) }
    }
  }

  var canSendCommands: Bool { MediaRemoteBridge.isAvailable }

  @discardableResult
  func send(_ command: MediaCommand) -> Bool {
    MediaRemoteBridge.send(command)
  }

  @discardableResult
  func seek(to seconds: TimeInterval) -> Bool {
    MediaRemoteBridge.setElapsedTime(seconds)
  }
}

/// Sending media commands through MediaRemote (private framework).
/// Only `MRMediaRemoteSendCommand` is used; the symbol is resolved at the first command.
enum MediaRemoteBridge {
  private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
  private static let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

  private static func resolve() -> SendCommand? {
    guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
      return nil
    }
    return unsafeBitCast(symbol, to: SendCommand.self)
  }

  static var isAvailable: Bool { resolve() != nil }

  static func send(_ command: MediaCommand) -> Bool {
    resolve()?(command.rawValue, nil) ?? false
  }

  private typealias SetElapsed = @convention(c) (Double) -> Void

  /// `MRMediaRemoteSetElapsedTime`: moves the track of the system Now Playing.
  static func setElapsedTime(_ seconds: TimeInterval) -> Bool {
    guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "MRMediaRemoteSetElapsedTime") else {
      return false
    }
    unsafeBitCast(symbol, to: SetElapsed.self)(max(seconds, 0))
    return true
  }
}
