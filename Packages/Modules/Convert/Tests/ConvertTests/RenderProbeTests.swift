// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import Testing

@testable import Convert

/// Photographs the wheel and panels in real windows: enabled only with
/// `TSUKUMO_RENDER_PROBE=<path.png> swift test --filter RenderProbe`.
@Suite("Visual probe")
@MainActor
struct RenderProbe {
  @Test("photographs the wheel") func shoot() async throws {
    guard ProcessInfo.processInfo.environment["TSUKUMO_RENDER_PROBE"] != nil else { return }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let model = RadialModel()
    model.formats = [.jpeg, .heic, .avif, .tiff, .bmp, .gif, .pdf]
    model.tools = ConvertCatalog.imageTools
    model.highlighted = 2
    model.sizeText = "922 KB"
    let side = RadialPanelController.side
    let panel = NSPanel(
      contentRect: CGRect(x: 200, y: 200, width: side, height: side),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.contentView = NSHostingView(rootView: RadialPicker(model: model))
    panel.orderFrontRegardless()
    try await Task.sleep(for: .seconds(1.5))
    let out = ProcessInfo.processInfo.environment["TSUKUMO_RENDER_PROBE"] ?? "/tmp/probe.png"
    try Self.capture(panel, to: out)
    model.mode = .tools
    try await Task.sleep(for: .seconds(1))
    try Self.capture(panel, to: out.replacingOccurrences(of: ".png", with: "-tools.png"))
    panel.orderOut(nil)

    // A tool's panel on a synthetic image.
    let image = FileManager.default.temporaryDirectory.appendingPathComponent("probe-image.png")
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    if let rep {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      NSGradient(starting: .systemOrange, ending: .systemBlue)?.draw(
        in: NSRect(x: 0, y: 0, width: 800, height: 600), angle: 30)
      NSGraphicsContext.restoreGraphicsState()
      try rep.representation(using: .png, properties: [:])?.write(to: image)
    }
    for tool in [ConvertTool.edit, .annotate, .compress] {
      let context = ToolContext(tool: tool, files: [image])
      let size = ToolContentFactory.size(for: tool)
      let toolPanel = NSPanel(
        contentRect: CGRect(x: 200, y: 100, width: size.width, height: size.height),
        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
      toolPanel.isOpaque = false
      toolPanel.backgroundColor = .clear
      toolPanel.contentView = NSHostingView(rootView: ToolHostView(context: context))
      toolPanel.orderFrontRegardless()
      try await Task.sleep(for: .seconds(2))
      try Self.capture(toolPanel, to: out.replacingOccurrences(of: ".png", with: "-\(tool.rawValue).png"))
      toolPanel.orderOut(nil)
    }
  }

  private static func capture(_ window: NSWindow, to path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
    try process.run()
    process.waitUntilExit()
  }
}
