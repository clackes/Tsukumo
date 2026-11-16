// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Actions reachable from the URL scheme and App Intents. It is a closed
/// list: anything not here is rejected (DESIGN.md §4.3.1).
public enum IntentAction: Sendable, Equatable {
  /// `tsukumo://settings`
  case openSettings
  /// `tsukumo://settings/<module id>`
  case openModuleSettings(id: String)
  /// `tsukumo://module/<module id>/enable` or `/disable`
  case setModuleEnabled(id: String, enabled: Bool)

  /// Actions that change system state have no "no confirmation"
  /// variant: they always go through a sheet of the frontmost app.
  public var requiresConfirmation: Bool {
    switch self {
    case .openSettings, .openModuleSettings: false
    case .setModuleEnabled: true
    }
  }
}

public enum IntentRejection: String, Sendable, Equatable {
  case wrongScheme
  /// Pairing never goes through a URL on the Mac.
  case pairingNotAllowed
  case unknownAction
  case unknownModule
  /// Query, fragment, credentials, port or extra components.
  case malformed
}

public enum IntentDecision: Sendable, Equatable {
  case execute(IntentAction)
  case confirm(IntentAction)
  case reject(IntentRejection)
}

/// Translates a `tsukumo://` URL into a decision. The scheme is not authenticated:
/// any web page or app can invoke it, so parameters are validated
/// with strict types and never reach a shell or AppleScript.
public struct IntentRouter: Sendable {
  public static let scheme = "tsukumo"
  static let maxModuleIDLength = 64

  public init() {}

  public func decide(_ url: URL, knownModuleIDs: Set<String>) -> IntentDecision {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == Self.scheme
    else { return .reject(.wrongScheme) }

    let host = components.host?.lowercased() ?? ""
    guard host != "pair" else { return .reject(.pairingNotAllowed) }
    guard Self.hasOnlyHostAndPath(components) else { return .reject(.malformed) }

    // Path still encoded: a "%2F" must not become a separator.
    let path = components.percentEncodedPath
      .split(separator: "/", omittingEmptySubsequences: false)
      .dropFirst()
      .map(String.init)
    return route(host: host, path: path, knownModuleIDs: knownModuleIDs)
  }

  private static func hasOnlyHostAndPath(_ components: URLComponents) -> Bool {
    components.query == nil && components.fragment == nil && components.user == nil
      && components.password == nil && components.port == nil
  }

  private func route(host: String, path: [String], knownModuleIDs: Set<String>) -> IntentDecision {
    switch (host, path.count) {
    case ("settings", 0):
      return .execute(.openSettings)
    case ("settings", 1):
      guard let id = moduleID(path[0], knownModuleIDs) else { return .reject(.unknownModule) }
      return .execute(.openModuleSettings(id: id))
    case ("module", 2):
      guard let id = moduleID(path[0], knownModuleIDs) else { return .reject(.unknownModule) }
      switch path[1] {
      case "enable": return .confirm(.setModuleEnabled(id: id, enabled: true))
      case "disable": return .confirm(.setModuleEnabled(id: id, enabled: false))
      default: return .reject(.unknownAction)
      }
    case ("settings", _), ("module", _):
      return .reject(.malformed)
    default:
      return .reject(.unknownAction)
    }
  }

  private func moduleID(_ raw: String, _ known: Set<String>) -> String? {
    guard !raw.isEmpty, raw.count <= Self.maxModuleIDLength,
      raw.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D }),
      known.contains(raw)
    else { return nil }
    return raw
  }
}
