// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import ModuleKit

@Suite("IntentRouter")
struct IntentRouterTests {
  private let router = IntentRouter()
  private let known: Set<String> = ["hello", "island.media"]

  private func decide(_ string: String) throws -> IntentDecision {
    router.decide(try #require(URL(string: string)), knownModuleIDs: known)
  }

  @Test("actions without side effects run immediately")
  func readOnlyActionsExecute() throws {
    #expect(try decide("tsukumo://settings") == .execute(.openSettings))
    #expect(try decide("tsukumo://settings/") == .reject(.unknownModule))
    #expect(try decide("tsukumo://settings/island.media") == .execute(.openModuleSettings(id: "island.media")))
    #expect(try decide("TSUKUMO://SETTINGS") == .execute(.openSettings))
  }

  @Test("turning a module on or off always requires confirmation")
  func moduleToggleNeedsConfirmation() throws {
    #expect(try decide("tsukumo://module/hello/enable") == .confirm(.setModuleEnabled(id: "hello", enabled: true)))
    #expect(try decide("tsukumo://module/hello/disable") == .confirm(.setModuleEnabled(id: "hello", enabled: false)))
    #expect(IntentAction.setModuleEnabled(id: "hello", enabled: true).requiresConfirmation)
    #expect(!IntentAction.openSettings.requiresConfirmation)
  }

  @Test("pairing via URL is always rejected")
  func pairingRejected() throws {
    #expect(try decide("tsukumo://pair?svc=x&secret=y") == .reject(.pairingNotAllowed))
    #expect(try decide("tsukumo://pair") == .reject(.pairingNotAllowed))
    #expect(try decide("tsukumo://PAIR/anything") == .reject(.pairingNotAllowed))
  }

  @Test(
    "everything not in the allowlist is rejected",
    arguments: [
      ("https://example.com/settings", IntentRejection.wrongScheme),
      ("tsukumo://shell/run", .unknownAction),
      ("tsukumo://", .unknownAction),
      ("tsukumo://module/hello/delete", .unknownAction),
      ("tsukumo://module/hello", .malformed),
      ("tsukumo://module/hello/enable/now", .malformed),
      ("tsukumo://settings/hello/extra", .malformed),
      ("tsukumo://settings?page=hello", .malformed),
      ("tsukumo://settings#x", .malformed),
      ("tsukumo://user:pw@settings", .malformed),
      ("tsukumo://settings:8080", .malformed),
      ("tsukumo://module/unknown/enable", .unknownModule),
      ("tsukumo://module/Hello/enable", .unknownModule),
      ("tsukumo://module/hello%20;rm/enable", .unknownModule),
      ("tsukumo://module/..%2Fhello/enable", .unknownModule),
    ]
  )
  func rejected(url: String, reason: IntentRejection) throws {
    #expect(try decide(url) == .reject(reason))
  }

  @Test("an id that is too long is rejected even if it were known")
  func overlongModuleID() throws {
    let long = String(repeating: "a", count: 65)
    let url = try #require(URL(string: "tsukumo://settings/\(long)"))
    #expect(router.decide(url, knownModuleIDs: [long]) == .reject(.unknownModule))
  }
}
