// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Testing

@testable import MenuBar

@Suite("MenuBar: icon reordering")
struct MenuBarOrderTests {
  let frames = [
    CGRect(x: 1000, y: 0, width: 30, height: 24),
    CGRect(x: 1030, y: 0, width: 40, height: 24),
    CGRect(x: 1070, y: 0, width: 30, height: 24),
  ]

  @Test("moving left drops on the left edge of the target icon")
  func moveLeft() {
    #expect(MenuBarMovePlanner.dropPoint(from: 2, to: 0, frames: frames) == CGPoint(x: 1002, y: 12))
  }

  @Test("moving right drops on the right edge of the target icon")
  func moveRight() {
    #expect(MenuBarMovePlanner.dropPoint(from: 0, to: 1, frames: frames) == CGPoint(x: 1068, y: 12))
  }

  @Test("out-of-list or equal positions produce no moves")
  func invalid() {
    #expect(MenuBarMovePlanner.dropPoint(from: 1, to: 1, frames: frames) == nil)
    #expect(MenuBarMovePlanner.dropPoint(from: 0, to: -1, frames: frames) == nil)
    #expect(MenuBarMovePlanner.dropPoint(from: 2, to: 3, frames: frames) == nil)
  }
}

@Suite("MenuBar: icon list")
struct MenuBarItemCatalogTests {
  private let agent = MenuBarOwner(
    pid: 1, bundleID: "com.apple.MenuBarAgent", name: "MenuBarAgent", executable: nil)
  private let claude = MenuBarOwner(
    pid: 2, bundleID: "com.anthropic.claudefordesktop", name: "Claude", executable: nil)
  private let papercut = MenuBarOwner(
    pid: 3, bundleID: nil, name: "usercontextservice", executable: "file:///Applications/PaperCut/usercontextservice")
  private let monitor = MenuBarOwner(pid: 4, bundleID: "dev.local.tsukumo", name: "Tsukumo", executable: nil)

  private func item(_ owner: MenuBarOwner, at left: CGFloat, label: String? = nil) -> RawMenuBarItem {
    RawMenuBarItem(owner: owner, index: 0, label: label, frame: CGRect(x: left, y: 0, width: 24, height: 24))
  }

  private func system(_ identifier: String, at left: CGFloat, description: String? = nil) -> RawMenuBarItem {
    var raw = item(agent, at: left)
    raw.systemIdentifier = "com.apple.menuextra.\(identifier)"
    raw.systemDescription = description
    return raw
  }

  @Test("system icons are recognized by identifier and the clock is dropped")
  func systemNames() {
    let raw = [
      system("clock", at: 1600), system("wifi", at: 1400), system("bluetooth", at: 1300),
      item(monitor, at: 1200, label: "CPU 13%"), system("now-playing", at: 1100),
    ]
    let result = MenuBarItemCatalog.compose(raw, hiddenKeys: [])
    #expect(result.visible.map(\.title) == ["Now Playing", "Tsukumo: CPU 13%", "Bluetooth", "Wi‑Fi"])
    #expect(result.visible.compactMap(\.symbol).contains("b.circle.fill"))
    #expect(result.hidden.isEmpty)
  }

  @Test("an unknown system icon uses the macOS description")
  func unknownSystem() {
    let result = MenuBarItemCatalog.compose(
      [system("something-new", at: 1400, description: "News")], hiddenKeys: [])
    #expect(result.visible.map(\.title) == ["News"])
    let bare = MenuBarItemCatalog.compose([item(agent, at: 1400)], hiddenKeys: [])
    #expect(bare.visible.map(\.title) == ["System item"])
  }

  @Test("hidden apps' icons go in a separate list, even without a bundle")
  func hidden() {
    let raw = [item(claude, at: 1200), item(papercut, at: 1180), item(monitor, at: 1300), system("clock", at: 1600)]
    let hiddenKeys: Set<String> = [
      "com.anthropic.claudefordesktop", "file:///Applications/PaperCut/usercontextservice",
    ]
    let result = MenuBarItemCatalog.compose(raw, hiddenKeys: hiddenKeys)
    #expect(result.visible.map(\.title) == ["Tsukumo"])
    #expect(result.hidden.map(\.title) == ["PaperCut", "Claude"])
  }
}

@Suite("MenuBar: names and expected order")
struct MenuBarItemNamingTests {
  @Test("processes without a bundle take the app folder's name")
  func folderName() {
    let owner = MenuBarOwner(
      pid: 1, bundleID: nil, name: "usercontextservice",
      executable: "file:///Applications/PaperCut%20Print%20Deploy%20Client/v2026-09-21-0528/usercontextservice")
    #expect(MenuBarItemCatalog.displayName(of: owner) == "PaperCut Print Deploy Client")
    let plain = MenuBarOwner(pid: 2, bundleID: "a.b", name: "App", executable: "file:///Applications/App.app/x")
    #expect(MenuBarItemCatalog.displayName(of: plain) == "App")
  }

  @Test("changing values are removed from the name")
  func trimmedLabel() {
    let owner = MenuBarOwner(pid: 1, bundleID: "dev.local.tsukumo", name: "Tsukumo", executable: nil)
    let raw = RawMenuBarItem(
      owner: owner, index: 0, label: "Monitor, CPU 15%, memoria 11,8 GB", frame: CGRect(x: 0, y: 0, width: 9, height: 9)
    )
    let result = MenuBarItemCatalog.compose([raw], hiddenKeys: [])
    #expect(result.visible.map(\.title) == ["Tsukumo: Monitor"])
  }

  @Test("expected order after a move")
  func expected() {
    #expect(MenuBarItemCatalog.expectedOrder(["a", "b", "c", "d"], from: 2, to: 1) == ["a", "c", "b", "d"])
    #expect(MenuBarItemCatalog.expectedOrder(["a", "b", "c"], from: 0, to: 1) == ["b", "a", "c"])
  }

  @Test("the bar band is measured from the icon's screen, even below the main one")
  func menuBarOnLowerScreen() {
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let lower = CGRect(x: 0, y: 900, width: 1920, height: 1080)
    let screens = [primary, lower]
    let owner = MenuBarOwner(pid: 2, bundleID: "com.example.app", name: "App", executable: nil)
    func at(_ top: CGFloat) -> RawMenuBarItem {
      RawMenuBarItem(owner: owner, index: 0, label: nil, frame: CGRect(x: 1000, y: top, width: 24, height: 24))
    }
    // Bar on the bottom monitor: y = 900, it used to be discarded.
    #expect(MenuBarItemCatalog.compose([at(900)], hiddenKeys: [], screens: screens).visible.count == 1)
    // At the bottom of the main screen it is not a menu bar icon.
    #expect(MenuBarItemCatalog.compose([at(860)], hiddenKeys: [], screens: screens).visible.isEmpty)
    // Bar auto-hidden, above the edge: it stays.
    #expect(MenuBarItemCatalog.compose([at(-24)], hiddenKeys: [], screens: screens).visible.count == 1)
  }
}
