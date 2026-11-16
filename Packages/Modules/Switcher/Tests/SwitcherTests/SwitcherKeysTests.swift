// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Testing

@testable import Switcher

@Suite("Switcher: keys")
struct SwitcherKeysTests {
  typealias Key = SwitcherKeys.Key

  @Test("⌥⇥ opens on the next window, Tab cycles, releasing ⌥ confirms")
  func optionTabFlow() {
    var keys = SwitcherKeys(trigger: .optionTab)
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: .maskAlternate) == (.open(step: 1), true))
    #expect(keys.isOpen)
    #expect(keys.handle(type: .keyUp, keyCode: Key.tab, flags: .maskAlternate) == (nil, true))
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: .maskAlternate) == (.move(1), true))
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: [.maskAlternate, .maskShift]) == (.move(-1), true))
    #expect(keys.handle(type: .flagsChanged, keyCode: 58, flags: []) == (.confirm, false))
    #expect(!keys.isOpen)
  }

  @Test("⌥⇧⇥ opens on the last window; Esc cancels and consumes")
  func backwardsAndEscape() {
    var keys = SwitcherKeys(trigger: .optionTab)
    #expect(
      keys.handle(type: .keyDown, keyCode: Key.tab, flags: [.maskAlternate, .maskShift]).action == .open(step: -1))
    #expect(keys.handle(type: .keyDown, keyCode: Key.escape, flags: .maskAlternate) == (.cancel, true))
    #expect(!keys.isOpen)
    // After cancellation, releasing ⌥ confirms nothing.
    #expect(keys.handle(type: .flagsChanged, keyCode: 58, flags: []) == (nil, false))
  }

  @Test("missed modifier release: the first key closes and passes through, the keyboard doesn't stay stuck")
  func lostModifierRelease() {
    var keys = SwitcherKeys(trigger: .optionTab)
    _ = keys.handle(type: .keyDown, keyCode: Key.tab, flags: .maskAlternate)
    #expect(keys.isOpen)
    // The release flagsChanged never arrived (tap disabled, password field).
    #expect(keys.handle(type: .keyDown, keyCode: 0, flags: []) == (.cancel, false))
    #expect(!keys.isOpen)
    #expect(keys.handle(type: .keyUp, keyCode: 0, flags: []) == (nil, false))
    #expect(keys.handle(type: .keyDown, keyCode: 1, flags: []) == (nil, false))
  }

  @Test("without the modifier, with ⌃ or with the wrong modifier, Tab passes through")
  func ignoredCombinations() {
    var keys = SwitcherKeys(trigger: .optionTab)
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: []) == (nil, false))
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: [.maskAlternate, .maskControl]) == (nil, false))
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: .maskCommand) == (nil, false))
    #expect(keys.handle(type: .keyDown, keyCode: 0, flags: .maskAlternate) == (nil, false))
    #expect(!keys.isOpen)
  }

  @Test("with ⌘⇥ chosen, ⌘⇥ opens and ⌥⇥ doesn't")
  func commandTrigger() {
    var keys = SwitcherKeys(trigger: .commandTab)
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: .maskAlternate).action == nil)
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: .maskCommand).action == .open(step: 1))
  }

  @Test("arrows and Return with the switcher open; other keys consumed without action")
  func arrowsAndReturn() {
    var keys = SwitcherKeys(trigger: .optionTab)
    _ = keys.handle(type: .keyDown, keyCode: Key.tab, flags: .maskAlternate)
    #expect(keys.handle(type: .keyDown, keyCode: Key.right, flags: .maskAlternate) == (.move(1), true))
    #expect(keys.handle(type: .keyDown, keyCode: Key.up, flags: .maskAlternate) == (.move(-1), true))
    #expect(keys.handle(type: .keyDown, keyCode: 0, flags: .maskAlternate) == (nil, true))
    #expect(keys.handle(type: .keyDown, keyCode: Key.returnKey, flags: .maskAlternate) == (.confirm, true))
    #expect(!keys.isOpen)
  }

  @Test("Tab release passes through if the press passed, and is consumed if it was ours")
  func tabKeyUpFollowsKeyDown() {
    var keys = SwitcherKeys(trigger: .optionTab)
    // ⌥⌃⇥ does not open: press and release go to the app.
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: [.maskAlternate, .maskControl]) == (nil, false))
    #expect(keys.handle(type: .keyUp, keyCode: Key.tab, flags: [.maskAlternate, .maskControl]) == (nil, false))
    // ⌥⇥ opens; ⌥ released before Tab: the Tab release stays ours.
    #expect(keys.handle(type: .keyDown, keyCode: Key.tab, flags: .maskAlternate) == (.open(step: 1), true))
    #expect(keys.handle(type: .flagsChanged, keyCode: 58, flags: []) == (.confirm, false))
    #expect(keys.handle(type: .keyUp, keyCode: Key.tab, flags: []) == (nil, true))
    // The following release, with no consumed press, passes.
    #expect(keys.handle(type: .keyUp, keyCode: Key.tab, flags: .maskAlternate) == (nil, false))
  }
}
