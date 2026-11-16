// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing

@testable import ModuleKit

@MainActor
@Suite("SurfaceManager")
struct SurfaceManagerTests {
  @Test("levels are strictly ordered and Island sits above the menu bar")
  func levelOrdering() {
    let levels = SurfaceLevel.allCases.map(\.windowLevel.rawValue)
    #expect(levels == levels.sorted())
    #expect(Set(levels).count == levels.count)
    #expect(SurfaceLevel.island.windowLevel.rawValue > NSWindow.Level.mainMenu.rawValue)
    #expect(SurfaceLevel.hud.windowLevel.rawValue < NSWindow.Level.screenSaver.rawValue)
    #expect(SurfaceLevel.preview < .island && SurfaceLevel.island < .switcher && SurfaceLevel.switcher < .hud)
  }

  @Test("updateIfChanged redraws only when the content changes")
  func statusItemRedrawsOnlyOnChange() {
    var rendered: [StatusItemContent] = []
    let surface = StatusItemSurface(item: nil) { rendered.append($0) }
    let cpu = StatusItemContent(symbol: "cpu", title: "12%", accessibilityLabel: "CPU 12%")

    #expect(surface.updateIfChanged(cpu))
    #expect(!surface.updateIfChanged(cpu))
    #expect(!surface.updateIfChanged(cpu))
    #expect(surface.updateIfChanged(StatusItemContent(symbol: "cpu", title: "13%", accessibilityLabel: "CPU 13%")))

    #expect(surface.renderCount == 2)
    #expect(rendered.map(\.title) == ["12%", "13%"])
  }

  @Test("the overlay plan follows the connected screens")
  func overlayPlan() {
    let plan = OverlayPlan(existing: [1, 2], current: [2, 3])
    #expect(plan.added == [3])
    #expect(plan.removed == [1])
    #expect(plan.kept == [2])
    #expect(OverlayPlan(existing: [], current: []) == OverlayPlan(existing: [], current: []))
  }

  @Test("a status item lives in the ResourceBag and disappears with it")
  func statusItemLifecycle() {
    let bag = ResourceBag()
    let surface = SurfaceManager().makeStatusItem(
      autosaveName: "tsukumo.test", content: StatusItemContent(symbol: "ant", accessibilityLabel: "Test"), in: bag
    )
    #expect(bag.snapshot == [.statusItem: 1])
    #expect(surface.renderCount == 1)
    #expect(surface.item?.button?.image != nil)

    bag.cancelAll()
    #expect(bag.isEmpty)
  }

  @Test("an item's visibility is chosen by name, remembered while off and does not touch the ResourceBag")
  func statusItemVisibility() throws {
    let suite = "tsukumo.tests.surfaces.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = SurfaceManager(defaults: defaults)
    let content = StatusItemContent(symbol: "ant", accessibilityLabel: "Test")

    let bag = ResourceBag()
    let surface = manager.makeStatusItem(autosaveName: "tsukumo.test.a", content: content, moduleID: "prova", in: bag)
    #expect(manager.statusItems(of: "prova").map(\.title) == ["Test"])
    #expect(surface.item?.isVisible == true)

    manager.setStatusItemVisible(false, autosaveName: "tsukumo.test.a")
    #expect(surface.item?.isVisible == false)
    #expect(manager.statusItems.first?.isVisible == false)
    #expect(bag.snapshot == [.statusItem: 1])

    bag.cancelAll()
    #expect(manager.statusItems.isEmpty)
    #expect(!manager.isStatusItemVisible("tsukumo.test.a"))

    // On turn-on again the item is born already hidden; another item is untouched.
    let again = ResourceBag()
    let reborn = manager.makeStatusItem(autosaveName: "tsukumo.test.a", content: content, in: again)
    let other = manager.makeStatusItem(autosaveName: "tsukumo.test.b", content: content, in: again)
    #expect(reborn.item?.isVisible == false && other.item?.isVisible == true)
    manager.setStatusItemVisible(true, autosaveName: "tsukumo.test.a")
    #expect(reborn.item?.isVisible == true)
    again.cancelAll()
  }

  @Test("the arrow recalls the hidden icons; a non-hideable item always stays visible")
  func revealAndPinned() throws {
    let suite = "tsukumo.tests.surfaces.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = SurfaceManager(defaults: defaults)
    let content = StatusItemContent(symbol: "ant", accessibilityLabel: "Test")
    let bag = ResourceBag()
    let arrow = manager.makeStatusItem(
      autosaveName: "tsukumo.test.arrow", content: content, moduleID: "menu", canHide: false, in: bag
    )
    let icon = manager.makeStatusItem(autosaveName: "tsukumo.test.icon", content: content, moduleID: "menu", in: bag)

    manager.setStatusItemVisible(false, autosaveName: "tsukumo.test.arrow")
    manager.setStatusItemVisible(false, autosaveName: "tsukumo.test.icon")
    #expect(arrow.item?.isVisible == true && icon.item?.isVisible == false)
    #expect(manager.statusItems(of: "menu").map(\.id) == ["tsukumo.test.icon"])

    manager.setRevealsHidden(true)
    #expect(icon.item?.isVisible == true)
    #expect(manager.statusItems.first { $0.id == "tsukumo.test.icon" }?.isVisible == false)
    manager.setRevealsHidden(false)
    #expect(icon.item?.isVisible == false)

    // An item created elsewhere is handled the same way and is released with no effects.
    let external = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    defer { NSStatusBar.system.removeStatusItem(external) }
    let release = manager.adoptStatusItem(external, autosaveName: "tsukumo.test.main", title: "Tsukumo")
    #expect(manager.statusItems.contains { $0.id == "tsukumo.test.main" && $0.canHide })
    manager.setStatusItemVisible(false, autosaveName: "tsukumo.test.main")
    #expect(external.isVisible == false)
    release()
    #expect(!manager.statusItems.contains { $0.id == "tsukumo.test.main" })
    bag.cancelAll()
  }

  @Test("an overlay creates a transparent window per screen and closes them all")
  func overlayLifecycle() {
    let bag = ResourceBag()
    let overlay = SurfaceManager().makeOverlay(level: .preview, in: bag) { _ in NSView() }

    #expect(overlay.windows.count == NSScreen.screens.count)
    #expect(bag.snapshot == [.window: 1, .observer: 1])
    for window in overlay.windows.values {
      #expect(window.level == SurfaceLevel.preview.windowLevel)
      #expect(window.ignoresMouseEvents)
      #expect(!window.isOpaque)
    }

    bag.cancelAll()
    #expect(overlay.windows.isEmpty)
    #expect(bag.isEmpty)
  }
}
