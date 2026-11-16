// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Carbon.HIToolbox
import Foundation
import Testing

@testable import ModuleKit

@MainActor
@Suite("Hotkeys, SharedSampler, ModuleSettingsStore")
struct FoundationServicesTests {
  @Test("a hotkey is valid only with ⌘ or ⌃ and a non-modifier key")
  func hotkeyRules() {
    let keyA = UInt32(kVK_ANSI_A)
    #expect(Hotkey(keyCode: keyA, modifiers: UInt32(cmdKey)).isSupported)
    #expect(Hotkey(keyCode: keyA, modifiers: UInt32(controlKey | optionKey)).isSupported)
    #expect(!Hotkey(keyCode: keyA, modifiers: UInt32(optionKey)).isSupported)
    #expect(!Hotkey(keyCode: keyA, modifiers: UInt32(optionKey | shiftKey)).isSupported)
    #expect(!Hotkey(keyCode: keyA, modifiers: 0).isSupported)
    #expect(!Hotkey(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey)).isSupported)
  }

  @Test("the sampler runs only while it has subscribers")
  func samplerRunsOnlyWithSubscribers() {
    let sampler = SharedSampler()
    #expect(!sampler.isSampling)

    let bag = ResourceBag()
    sampler.addSubscription(to: bag) {}
    let second = sampler.subscribe(cadence: .visible) {}
    #expect(sampler.isSampling)
    #expect(sampler.subscriberCount == 2)

    second.cancel()
    #expect(sampler.isSampling)
    bag.cancelAll()
    #expect(!sampler.isSampling)
    #expect(sampler.subscriberCount == 0)
  }

  @Test("settings are separate per module and reset per module")
  func settingsNamespaces() throws {
    let suite = "tsukumo.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ModuleSettingsStore(defaults: defaults)

    try store.set(3, forKey: "level", moduleID: "a")
    try store.set("x", forKey: "level", moduleID: "b")
    #expect(store.value(forKey: "level", moduleID: "a", as: Int.self) == 3)
    #expect(store.value(forKey: "level", moduleID: "b", as: String.self) == "x")

    let exported = try store.export(moduleID: "a")
    store.reset(moduleID: "a")
    #expect(store.value(forKey: "level", moduleID: "a", as: Int.self) == nil)
    #expect(store.value(forKey: "level", moduleID: "b", as: String.self) == "x")

    try store.import(exported, moduleID: "a")
    #expect(store.value(forKey: "level", moduleID: "a", as: Int.self) == 3)
  }
}
