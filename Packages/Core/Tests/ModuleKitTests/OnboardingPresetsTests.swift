// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import ModuleKit

@MainActor
@Suite("Onboarding: presets and state")
struct OnboardingPresetsTests {
  @Test("there are three listed presets, and Essenziale contains Island, Snap, Monitor")
  func presets() {
    #expect(OnboardingPresets.all.count == 3)
    #expect(OnboardingPresets.essenziale.moduleIDs == ["island", "snap", "monitor"])
    #expect(OnboardingPresets.personalizza.moduleIDs.isEmpty)
  }

  @Test("the factory state shows the onboarding; after markCompleted it does not")
  func shouldShow() {
    var state = OnboardingState()
    #expect(state.shouldShow)
    state.markCompleted(presetID: "essenziale")
    #expect(!state.shouldShow)
    #expect(state.chosenPresetID == "essenziale")
  }

  @Test("JSON round-trip preserves the fields")
  func roundTrip() throws {
    var state = OnboardingState()
    state.markCompleted(presetID: "powerUser")
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(OnboardingState.self, from: data)
    #expect(decoded == state)
  }

  @Test("the store reads and writes from an injected UserDefaults")
  func storeRoundTrip() throws {
    let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
    let store = OnboardingStore(defaults: defaults)
    #expect(store.load() == OnboardingState())
    var state = OnboardingState()
    state.markCompleted(presetID: "essenziale")
    store.save(state)
    #expect(store.load() == state)
  }
}
