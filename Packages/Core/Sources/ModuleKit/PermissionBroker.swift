// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Foundation

public enum PermissionStatus: Sendable, Equatable {
  case granted
  case denied
  case notDetermined
  /// macOS offers no preflight for this permission (Motion, Bluetooth,
  /// Local Network, Automation): the system asks at the first real use.
  case unknown
}

/// Restarts this copy of the app after a TCC grant that requires a
/// new process to become effective (for example a CGEventTap).
@MainActor
public enum LocalAppRelauncher {
  /// Reopens the bundle we are running from, never "the app with this bundle id":
  /// with two copies installed `open -b` might launch the other one (DESIGN.md §6.1).
  /// The script waits for this process to have really exited, so two
  /// instances do not coexist.
  public static func restart(bundleURL: URL = Bundle.main.bundleURL) throws {
    guard bundleURL.pathExtension == "app", FileManager.default.fileExists(atPath: bundleURL.path) else {
      throw RelaunchError.invalidBundle
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Path and pid are positional arguments: no interpolation in the script.
    process.arguments = [
      "-c",
      "n=0; while /bin/kill -0 \"$2\" 2>/dev/null && [ $n -lt 50 ]; do /bin/sleep 0.2; n=$((n+1)); done; "
        + "exec /usr/bin/open \"$1\"",
      "tsukumo-relaunch", bundleURL.path, String(ProcessInfo.processInfo.processIdentifier),
    ]
    try process.run()
    NSApp.terminate(nil)
  }
}

public enum RelaunchError: Error {
  case invalidBundle
}

/// State of TCC permissions (DESIGN.md §4.3). Reads the state without ever making
/// a prompt appear: requests start only from `request(_:)`, that is from
/// a user action. No polling.
public struct PermissionBroker: Sendable {
  public typealias Probe = @Sendable (Permission) -> PermissionStatus

  private let probe: Probe

  public init(probe: @escaping Probe = PermissionBroker.systemStatus) {
    self.probe = probe
  }

  public func status(of permission: Permission) -> PermissionStatus {
    probe(permission)
  }

  /// Permissions that prevent launch: the verifiable ones that are not granted.
  /// `.unknown` ones do not block, because they can only be requested by using them.
  public func missing(from permissions: Set<Permission>) -> [Permission] {
    permissions
      .filter { [.denied, .notDetermined].contains(status(of: $0)) }
      .sorted { $0.rawValue < $1.rawValue }
  }

  /// System Settings → Privacy & Security page of the permission.
  public static func settingsURL(for permission: Permission) -> URL? {
    let anchor =
      switch permission {
      case .accessibility: "Privacy_Accessibility"
      case .inputMonitoring: "Privacy_ListenEvent"
      case .screenRecording: "Privacy_ScreenCapture"
      case .calendars: "Privacy_Calendars"
      case .reminders: "Privacy_Reminders"
      case .motion: "Privacy_Motion"
      case .bluetooth: "Privacy_Bluetooth"
      case .localNetwork: "Privacy_LocalNetwork"
      case .automation: "Privacy_Automation"
      }
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
  }

  /// Real system state. Does not show prompts.
  public static let systemStatus: Probe = { permission in
    switch permission {
    case .accessibility:
      AXIsProcessTrusted() ? .granted : .denied
    case .inputMonitoring:
      CGPreflightListenEventAccess() ? .granted : .denied
    case .screenRecording:
      CGPreflightScreenCaptureAccess() ? .granted : .denied
    case .calendars:
      eventKitStatus(for: .event)
    case .reminders:
      eventKitStatus(for: .reminder)
    case .motion, .bluetooth, .localNetwork, .automation:
      .unknown
    }
  }

  /// Asks the system for the permission. Must be called only from a user action.
  /// Returns the state after the request; for Accessibility, Input
  /// Monitoring and Screen Recording the grant happens in System
  /// Settings, so the state may stay `.denied` until the user returns to the app.
  @MainActor
  public func request(_ permission: Permission) async -> PermissionStatus {
    switch permission {
    case .accessibility:
      // "AXTrustedCheckOptionPrompt": the C constant is a non-Sendable global var.
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    case .inputMonitoring:
      _ = CGRequestListenEventAccess()
    case .screenRecording:
      _ = CGRequestScreenCaptureAccess()
    case .calendars:
      _ = try? await EKEventStore().requestFullAccessToEvents()
    case .reminders:
      _ = try? await EKEventStore().requestFullAccessToReminders()
    case .motion, .bluetooth, .localNetwork, .automation:
      break
    }
    return status(of: permission)
  }

  private static func eventKitStatus(for type: EKEntityType) -> PermissionStatus {
    switch EKEventStore.authorizationStatus(for: type) {
    case .fullAccess: .granted
    case .notDetermined: .notDetermined
    default: .denied
    }
  }
}
