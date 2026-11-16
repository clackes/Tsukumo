// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import Testing

@testable import ModuleKit

@MainActor
@Suite("Compat: rules and loading")
struct CompatTests {
  @Test("numeric build comparison: 24C101 > 24B99")
  func buildOrdering() {
    let rule = CompatRule(
      module: "island", minBuild: "24B50", maxBuild: "24C100",
      action: .warn, message: "x")
    #expect(!rule.matches(build: "24B49"))
    #expect(rule.matches(build: "24B50"))
    #expect(rule.matches(build: "24C100"))
    #expect(!rule.matches(build: "24C101"))
    let open = CompatRule(module: "island", minBuild: nil, maxBuild: "24C100", action: .warn, message: "x")
    #expect(open.matches(build: "15A1"))
    #expect(!open.matches(build: "24D1"))
  }

  @Test("suspend beats warn on equal build")
  func severityPrecedence() {
    let compat = Compat(
      initial: CompatPolicy(
        version: 1,
        rules: [
          CompatRule(module: "island", action: .warn, message: "piano piano"),
          CompatRule(module: "island", action: .suspend, message: "rotto"),
        ]),
      verifier: .allowAny)
    #expect(compat.status(forModule: "island", osBuild: "27A1") == .suspend("rotto"))
  }

  @Test("no rules = active")
  func noRules() {
    let compat = Compat()
    #expect(compat.status(forModule: "island", osBuild: "27A1") == .active)
  }

  @Test("apply rejects an equal or lower version")
  func rejectOlder() throws {
    let compat = Compat(
      initial: CompatPolicy(version: 5, rules: []), verifier: .allowAny)
    let payload = try JSONEncoder().encode(CompatPolicy(version: 4, rules: []))
    #expect {
      try compat.apply(payload: payload, signature: Data())
    } throws: { error in
      if case .notNewer(let current, let incoming) = error as? CompatLoadError {
        return current == 5 && incoming == 4
      }
      return false
    }
  }

  @Test("apply rejects an invalid signature")
  func rejectBadSignature() {
    let compat = Compat(verifier: .rejectAll)
    #expect(throws: CompatLoadError.badSignature) {
      try compat.apply(payload: Data("{}".utf8), signature: Data())
    }
  }

  @Test("apply Ed25519 accepts the genuine signature, rejects the wrong one")
  func ed25519Roundtrip() throws {
    let key = Curve25519.Signing.PrivateKey()
    let compat = Compat(verifier: .ed25519(publicKey: key.publicKey))
    let policy = CompatPolicy(
      version: 1,
      rules: [CompatRule(module: "island", action: .warn, message: "ok")])
    let payload = try JSONEncoder().encode(policy)
    let signature = try key.signature(for: payload)
    let applied = try compat.apply(payload: payload, signature: signature)
    #expect(applied == policy)
    #expect(compat.status(forModule: "island", osBuild: "27A1") == .warn("ok"))

    let other = Curve25519.Signing.PrivateKey()
    let wrongSig = try other.signature(for: payload)
    let compat2 = Compat(verifier: .ed25519(publicKey: key.publicKey))
    #expect(throws: CompatLoadError.badSignature) {
      try compat2.apply(payload: payload, signature: wrongSig)
    }
  }
}
