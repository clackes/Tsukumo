// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Testing

@testable import MenuBar

@Suite("MenuBar")
struct MenuBarPreferencesTests {
  @Test("entries with a bundle are identified by bundle id")
  func bundleIdentifier() {
    let key: [String: Any] = ["bundle": ["_0": "com.example.app"]]
    #expect(MenuBarPreferences.identifier(of: key) == "com.example.app")
  }

  @Test("processes without a bundle are identified by the executable URL")
  func adhocBinaryIdentifier() {
    let url = "file:///Applications/Some%20Tool/v1/agent"
    let key: [String: Any] = ["adhocBinary": ["_0": ["relative": url]]]
    #expect(MenuBarPreferences.identifier(of: key) == url)
  }

  @Test("executables of the same app, even of different versions, form a family")
  func adhocFamily() {
    let old = "file:///Applications/Some%20Tool/v1/agent"
    let new = "file:///Applications/Some%20Tool/v2/agent"
    let launcher = "file:///Applications/Some%20Tool/launcher"
    #expect(MenuBarPreferences.family(of: old) == "/Applications/Some Tool")
    #expect(MenuBarPreferences.family(of: new) == MenuBarPreferences.family(of: old))
    #expect(MenuBarPreferences.family(of: launcher) == MenuBarPreferences.family(of: old))
    #expect(MenuBarPreferences.family(of: "file:///Applications/Other/agent") != MenuBarPreferences.family(of: old))
    #expect(MenuBarPreferences.family(of: "file:///usr/local/bin/tool") == "/usr/local/bin")
    #expect(MenuBarPreferences.family(of: "com.example.app") == nil)
  }

  @Test("the toggle acts on all entries of the same family, without duplicating them")
  func applyToFamily() {
    let old = "file:///Applications/Some%20Tool/v1/agent"
    let new = "file:///Applications/Some%20Tool/v2/agent"
    var array: [Any] = [
      ["adhocBinary": ["_0": ["relative": old]]], ["isAllowed": true],
      ["bundle": ["_0": "com.example.app"]], ["isAllowed": true],
    ]
    #expect(MenuBarPreferences.apply(false, to: [new], in: &array))
    #expect(array.count == 4)
    #expect((array[1] as? [String: Any])?["isAllowed"] as? Bool == false)
    #expect((array[3] as? [String: Any])?["isAllowed"] as? Bool == true)
  }

  @Test("an app never registered gets a new entry of the right type")
  func applyAddsMissingEntries() {
    var array: [Any] = []
    #expect(MenuBarPreferences.apply(false, to: ["com.example.app", "file:///opt/tool/agent"], in: &array))
    #expect(array.count == 4)
    #expect(MenuBarPreferences.identifier(of: array[0]) == "com.example.app")
    #expect(MenuBarPreferences.identifier(of: array[2]) == "file:///opt/tool/agent")
    #expect(!MenuBarPreferences.apply(false, to: ["com.apple.finder"], in: &array))
  }

  @Test("unknown or malformed entries are ignored")
  func unknownKeys() {
    #expect(MenuBarPreferences.identifier(of: ["altro": ["_0": "x"]]) == nil)
    #expect(MenuBarPreferences.identifier(of: ["bundle": ["_0": "a"], "adhocBinary": [:]]) == nil)
    #expect(MenuBarPreferences.identifier(of: "stringa") == nil)
  }

  @Test("Control Center values: 2 and 18 show, 8 and 24 hide")
  func systemItemValues() {
    #expect(MenuBarSystemItems.isShown(value: 2))
    #expect(MenuBarSystemItems.isShown(value: 18))
    #expect(!MenuBarSystemItems.isShown(value: 8))
    #expect(!MenuBarSystemItems.isShown(value: 24))
  }

  @Test("hiding and showing again preserves the Control Center bit")
  func systemItemValuePreservesOtherBits() {
    #expect(MenuBarSystemItems.value(shown: false, current: 18) == 24)
    #expect(MenuBarSystemItems.value(shown: true, current: 24) == 18)
    #expect(MenuBarSystemItems.value(shown: false, current: 2) == 8)
    #expect(MenuBarSystemItems.value(shown: true, current: 8) == 2)
    #expect(MenuBarSystemItems.value(shown: true, current: nil) == 2)
    #expect(MenuBarSystemItems.value(shown: false, current: nil) == 8)
  }
}
