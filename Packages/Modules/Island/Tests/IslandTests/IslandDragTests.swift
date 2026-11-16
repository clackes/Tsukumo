// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import ModuleKit
import Testing

@testable import Island

@MainActor
@Suite("Dragging files onto the island")
struct IslandDragTests {
  @Test("the half-point of rounding is not a shape change")
  func roundedFrames() {
    let target = CGRect(x: 645, y: 846.5, width: 420, height: 265.5)
    let window = CGRect(x: 645, y: 846, width: 420, height: 266)
    #expect(IslandGeometry.isSameFrame(target, window))
    #expect(!IslandGeometry.isShrinking(from: window, to: target))
    let collapsed = CGRect(x: 689, y: 1074, width: 332, height: 38)
    #expect(!IslandGeometry.isSameFrame(collapsed, window))
    #expect(IslandGeometry.isShrinking(from: window, to: collapsed))
  }

  /// The bug: on every update 266 → 265.5 started a "shrink" that
  /// made the panel transparent to clicks and made the dragged file get lost.
  @Test("repeating the same presentation doesn't make the panel click-through")
  func repeatedApplyKeepsMouse() async throws {
    let model = IslandModel()
    let resources = ResourceBag()
    let actions = IslandActions(tap: {}, send: { _ in }, removeFromShelf: { _ in }, airDropAll: {})
    let controller = IslandPanelController(model: model, actions: actions, resources: resources)
    defer { controller.close() }
    let panel = try #require(NSApp.windows.compactMap { $0 as? NSPanel }.last)
    controller.apply(.expanded)
    // End of the morph: now the window frame is the one rounded by AppKit.
    try await Task.sleep(for: .milliseconds(900))
    #expect(!panel.ignoresMouseEvents)
    for _ in 0..<5 {
      controller.apply(.expanded)
      #expect(!panel.ignoresMouseEvents)
    }
  }

  @Test("during a drag even a real shrink leaves the destination panel in place")
  func shrinkWhileDragging() throws {
    let model = IslandModel()
    model.isDragging = true
    let resources = ResourceBag()
    let actions = IslandActions(tap: {}, send: { _ in }, removeFromShelf: { _ in }, airDropAll: {})
    let controller = IslandPanelController(model: model, actions: actions, resources: resources)
    defer { controller.close() }
    let panel = try #require(NSApp.windows.compactMap { $0 as? NSPanel }.last)
    controller.apply(.expanded)
    controller.apply(.compact)
    #expect(!panel.ignoresMouseEvents)
  }

  @Test("outside the lock screen the island stays in the normal Space")
  func lockSpaceOnlyWhenLocked() {
    let model = IslandModel()
    model.lockScreenEnabled = true
    let resources = ResourceBag()
    let actions = IslandActions(tap: {}, send: { _ in }, removeFromShelf: { _ in }, airDropAll: {})
    let controller = IslandPanelController(model: model, actions: actions, resources: resources)
    defer { controller.close() }
    #expect(!controller.attachesToLockScreen)
  }
}
