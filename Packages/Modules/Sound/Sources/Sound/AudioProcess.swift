// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreAudio
import Foundation

/// A process that is emitting system audio **right now**, as the
/// popover's per-app mixer sees it. For now it is a read-only view: per-app
/// volume and output control will be built on top (DESIGN.md §2.4.1, spike 27).
struct AudioProcess: Identifiable, Sendable, Equatable {
  /// The process's `AudioObjectID` in Core Audio, stable between two reads.
  let id: AudioObjectID
  /// The Unix PID; we use it to trace back to bundle id, name and icon via `NSRunningApplication`.
  let pid: pid_t
  let bundleID: String?
  let name: String
}

/// App icon for `AudioProcess`, read from `NSRunningApplication`. It is an
/// AppKit object, so it does not go into the `Sendable` struct: the view
/// resolves it on demand.
@MainActor
enum AudioProcessIcon {
  static func image(for process: AudioProcess) -> NSImage? {
    NSRunningApplication(processIdentifier: process.pid)?.icon
  }
}

/// Reads from Core Audio's process objects the list of processes that have
/// at least one active output stream (DESIGN.md §2.4.1). No TCC permission:
/// reading name, PID and bundle id does not require `kTCCServiceAudioCapture`;
/// that will only be needed for the real taps (spike 27).
enum CoreAudioProcessList {
  /// The current list, sorted by name.
  @MainActor
  /// `keeping`: apps with their own volume or output, shown even when paused
  /// because their tap remains and must be able to be brought back to 100%.
  static func current(keeping: Set<AudioObjectID> = []) -> [AudioProcess] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let ids: [AudioObjectID] = CoreAudioProperty.array(
      of: system, CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList))
    let ownPID = getpid()
    return ids.compactMap { makeProcess($0, ownPID: ownPID, keep: keeping.contains($0)) }.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  @MainActor
  private static func makeProcess(_ id: AudioObjectID, ownPID: pid_t, keep: Bool) -> AudioProcess? {
    guard
      let running = CoreAudioProperty.read(
        id, CoreAudioProperty.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0)),
      running == 1 || keep,
      let pid = CoreAudioProperty.read(
        id, CoreAudioProperty.address(kAudioProcessPropertyPID), initial: pid_t(-1)),
      pid > 0,
      // The IOProc of our aggregate devices makes Tsukumo appear as an "app
      // playing audio": it is a mixer artifact, it must not be shown.
      pid != ownPID
    else { return nil }
    let runningApp = NSRunningApplication(processIdentifier: pid)
    // Browsers and Electron play from a service process inside their
    // bundle ("Google Chrome Helper"): the mixer shows the app that contains it.
    if let owner = runningApp?.bundleURL.flatMap(owningApp(of:)), let bundle = Bundle(url: owner) {
      let name =
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? owner.deletingPathExtension().lastPathComponent
      return AudioProcess(id: id, pid: pid, bundleID: bundle.bundleIdentifier, name: name)
    }
    let bundleID =
      CoreAudioProperty.string(of: id, CoreAudioProperty.address(kAudioProcessPropertyBundleID))
      ?? runningApp?.bundleIdentifier
    let name = runningApp?.localizedName ?? bundleID ?? "PID \(pid)"
    return AudioProcess(id: id, pid: pid, bundleID: bundleID, name: name)
  }

  /// The outermost app that contains `url`, if `url` is a nested bundle
  /// (`…/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app`).
  nonisolated static func owningApp(of url: URL) -> URL? {
    let components = url.standardizedFileURL.pathComponents
    guard let outer = components.firstIndex(where: { $0.hasSuffix(".app") }),
      components[(outer + 1)...].contains(where: { $0.hasSuffix(".app") })
    else { return nil }
    return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...outer])), isDirectory: true)
  }
}
