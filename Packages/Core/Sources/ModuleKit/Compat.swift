// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

/// EdDSA-signed `compat.json` channel downloaded with the appcast (DESIGN.md §4.3,
/// §9.2). It lists `module × macOS build` combinations known to be broken and what
/// to do about them, so we can react to a point release that breaks something
/// without waiting for a new build.
public enum CompatAction: String, Codable, Sendable, Equatable {
  /// The module does not start: explanatory banner, button to retry.
  case suspend
  /// The module starts but shows a warning.
  case warn
}

/// A single entry: between these macOS builds the module misbehaves.
public struct CompatRule: Codable, Sendable, Equatable {
  public let module: String
  /// Included macOS builds (string comparison, `24A335` style). `nil` = always.
  public let minBuild: String?
  public let maxBuild: String?
  public let action: CompatAction
  public let message: String

  public init(
    module: String, minBuild: String? = nil, maxBuild: String? = nil,
    action: CompatAction, message: String
  ) {
    self.module = module
    self.minBuild = minBuild
    self.maxBuild = maxBuild
    self.action = action
    self.message = message
  }

  /// `true` if the given build falls within `[minBuild, maxBuild]`.
  public func matches(build: String) -> Bool {
    if let minBuild, build.compare(minBuild, options: .numeric) == .orderedAscending { return false }
    if let maxBuild, build.compare(maxBuild, options: .numeric) == .orderedDescending { return false }
    return true
  }
}

/// A `compat.json` document with a monotonic version number: the loader
/// rejects a document older than the one already applied.
public struct CompatPolicy: Codable, Sendable, Equatable {
  public let version: Int
  public let rules: [CompatRule]

  public init(version: Int, rules: [CompatRule]) {
    self.version = version
    self.rules = rules
  }

  /// Empty: nothing suspended, no warnings. This is the app's factory state
  /// if a signed document has not arrived yet.
  public static let empty = CompatPolicy(version: 0, rules: [])
}

/// Answer to the query: what the module must do on this macOS version.
public enum CompatStatus: Sendable, Equatable {
  case active
  case warn(String)
  case suspend(String)
}

/// EdDSA (Ed25519) verification using the maintainer's public key. Until
/// the real key exists (`App/manifest.yml` pending), the verifier lives
/// in the app code: Core only exposes the API.
public struct CompatVerifier: Sendable {
  public typealias Verify = @Sendable (_ payload: Data, _ signature: Data) -> Bool
  public let verify: Verify

  public init(verify: @escaping Verify) { self.verify = verify }

  /// Ed25519 verifier on a known public key. The payload is the exact JSON
  /// of the document; the signature is a 64-byte blob.
  public static func ed25519(publicKey: Curve25519.Signing.PublicKey) -> CompatVerifier {
    CompatVerifier { payload, signature in
      publicKey.isValidSignature(signature, for: payload)
    }
  }

  /// Verifier that accepts everything: for tests only.
  public static let allowAny = CompatVerifier { _, _ in true }
  /// Verifier that rejects everything: useful as a boot default before
  /// the app has loaded its own public key.
  public static let rejectAll = CompatVerifier { _, _ in false }
}

/// The reason a `load(...)` rejected a document.
public enum CompatLoadError: Error, Equatable, Sendable {
  case badSignature
  case notNewer(current: Int, incoming: Int)
  case badJSON(String)
}

/// Loader + query. Lives only once, is `Sendable` thanks to `MainActor`
/// isolation: the app asks for the verdict for each module at boot and when
/// a new `compat.json` arrives.
@MainActor
public final class Compat {
  private var policy: CompatPolicy
  private let verifier: CompatVerifier

  public init(initial: CompatPolicy = .empty, verifier: CompatVerifier = .rejectAll) {
    self.policy = initial
    self.verifier = verifier
  }

  /// Policy active right now.
  public var current: CompatPolicy { policy }

  /// Loads a verified document. Rejects an invalid signature, an equal
  /// or lower version, malformed JSON. The previous version stays active in
  /// every error case.
  @discardableResult
  public func apply(payload: Data, signature: Data) throws(CompatLoadError) -> CompatPolicy {
    guard verifier.verify(payload, signature) else { throw .badSignature }
    let decoded: CompatPolicy
    do {
      decoded = try JSONDecoder().decode(CompatPolicy.self, from: payload)
    } catch {
      throw .badJSON(String(describing: error))
    }
    guard decoded.version > policy.version else {
      throw .notNewer(current: policy.version, incoming: decoded.version)
    }
    policy = decoded
    return decoded
  }

  /// Verdict for a module on the current macOS build. If several rules
  /// match, the strictest wins (`suspend` > `warn`).
  public func status(forModule module: String, osBuild: String) -> CompatStatus {
    var warning: String?
    for rule in policy.rules where rule.module == module && rule.matches(build: osBuild) {
      switch rule.action {
      case .suspend: return .suspend(rule.message)
      case .warn: warning = rule.message
      }
    }
    return warning.map(CompatStatus.warn) ?? .active
  }
}
