// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit
import Testing

@testable import Convert

@Suite("Picker: the drag reaches the right view")
@MainActor
struct RadialHitTests {
  @Test("on every petal and at the center the view hit is the drag one, with the wheel drawn")
  func dropViewIsOnTop() async throws {
    _ = NSApplication.shared
    let resources = ResourceBag()
    defer { resources.cancelAll() }
    let controller = RadialPanelController(resources: resources)
    let file = URL(fileURLWithPath: "/tmp/photo.png")
    controller.show(
      files: [file], formats: ConvertCatalog.formats(for: [file]), tools: ConvertCatalog.imageTools,
      advanced: false, at: CGPoint(x: 600, y: 500))
    // Gives SwiftUI time to mount the glass.
    try await Task.sleep(for: .milliseconds(500))
    let drop = try #require(controller.dropView)
    let content = try #require(drop.window?.contentView)
    #expect(drop.registeredDraggedTypes.contains(.fileURL))
    let layout = controller.model.layout
    let radius = (layout.innerRadius + layout.outerRadius) / 2
    for index in 0..<layout.petals {
      let angle = layout.centerAngle(of: index)
      // View coordinates (y up) from the centre.
      let point = CGPoint(
        x: content.bounds.midX + sin(angle) * radius, y: content.bounds.midY + cos(angle) * radius)
      let hit = content.hitTest(point)
      #expect(hit === drop, "petal \(index): hit \(String(describing: hit))")
      #expect(layout.petal(at: CGPoint(x: sin(angle) * radius, y: -cos(angle) * radius)) == index)
    }
    controller.hide()
  }
}
