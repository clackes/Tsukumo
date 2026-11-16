// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit
import OSLog
import Observation
import QuickLookThumbnailing
import SwiftUI

/// State of the radial picker.
@MainActor
@Observable
final class RadialModel {
  enum Status: Equatable {
    case choosing
    case working
    case done(String)
    case failed(String)
  }

  /// Which set of petals is visible.
  enum Mode: Equatable {
    case formats, tools
  }

  var files: [URL] = []
  var formats: [OutputFormat] = []
  var tools: [ConvertTool] = []
  var mode: Mode = .formats
  var highlighted: Int?
  var thumbnail: NSImage?
  var sizeText = ""
  var status: Status = .choosing
  /// Progress of the job in progress, if known (0…1).
  var progress: Double?
  /// "Cancel" button shown during conversion.
  var onCancel: (() -> Void)?

  var items: [RadialItem] {
    switch mode {
    case .formats: formats.map(RadialItem.format)
    case .tools: tools.map(RadialItem.tool)
    }
  }

  /// There is another set reachable with ⇧ (from formats) or by releasing ⇧ (from tools).
  var canSwitch: Bool { !formats.isEmpty && !tools.isEmpty }

  var layout: RadialLayout { RadialLayout(petals: items.count) }
}

/// Drag destination: follows the pointer over the petals and receives the drop.
final class RadialDropView: NSView {
  private let log = Logger(subsystem: "dev.local.tsukumo", category: "convert")
  var onHover: ((CGPoint?) -> Void)?
  var onDrop: ((CGPoint) -> Bool)?
  var onModifiers: ((NSEvent.ModifierFlags) -> Void)?
  /// During conversion the view lets clicks through to the "Cancel" button.
  var passesClicksThrough = false

  override func hitTest(_ point: NSPoint) -> NSView? {
    passesClicksThrough ? nil : super.hitTest(point)
  }

  /// An almost invisible disc: in a transparent window the system lets the pointer
  /// and drag pass through empty pixels, and the glass (composited by the system)
  /// leaves the window's pixels empty. With 2% opacity every point of the
  /// wheel receives the drag, without it being visible.
  override func draw(_ dirtyRect: NSRect) {
    NSColor(white: 0, alpha: 0.02).setFill()
    NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
  }

  /// Offset from the view's centre, with y pointing down as in the layout.
  private func offset(of sender: any NSDraggingInfo) -> CGPoint {
    let point = convert(sender.draggingLocation, from: nil)
    return CGPoint(x: point.x - bounds.midX, y: bounds.midY - point.y)
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    onHover?(offset(of: sender))
    return .copy
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    onHover?(offset(of: sender))
    // Over the wheel the system calls back here even with the pointer still: ⇧ takes
    // effect immediately.
    onModifiers?(NSEvent.modifierFlags)
    return .copy
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) { onHover?(nil) }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let accepted = onDrop?(offset(of: sender)) ?? false
    log.notice("drop: \(String(describing: self.offset(of: sender)), privacy: .public) accepted \(accepted)")
    return accepted
  }
}

/// Non-activating panel that becomes "key" only during conversion,
/// to receive Esc without stealing focus from the app in use.
final class RadialPanel: NSPanel {
  var acceptsKey = false
  var onCancel: (() -> Void)?

  override var canBecomeKey: Bool { acceptsKey }

  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Picker panel: exists only while visible.
@MainActor
final class RadialPanelController {
  let model = RadialModel()
  /// Drop on a petal.
  var onChoose: ((RadialItem, [URL]) -> Void)?
  private let resources: ResourceBag
  private var panel: RadialPanel?
  private var thumbnailTask: Task<Void, Never>?
  private var guardTask: Task<Void, Never>?
  /// For tests: the view that receives the drag.
  private(set) var dropView: RadialDropView?

  static var side: CGFloat { (RadialLayout(petals: 1).outerRadius + 18) * 2 }

  init(resources: ResourceBag) {
    self.resources = resources
    resources.add(.window) { [weak self] in self?.hide() }
  }

  var frame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

  /// Shows the picker centred on the pointer (AppKit coordinates).
  func show(files: [URL], formats: [OutputFormat], tools: [ConvertTool], advanced: Bool, at point: CGPoint) {
    model.files = files
    model.formats = formats
    model.tools = tools
    model.mode = Self.mode(advanced: advanced, formats: formats, tools: tools)
    model.highlighted = nil
    model.status = .choosing
    dropView?.passesClicksThrough = false
    panel?.acceptsKey = false
    model.sizeText = Self.sizeText(for: files)
    loadThumbnail(for: files.first)
    let panel = panel ?? makePanel()
    self.panel = panel
    panel.setFrame(Self.frame(centeredAt: point), display: true)
    panel.orderFrontRegardless()
    Logger(subsystem: "dev.local.tsukumo", category: "convert").notice(
      "picker shown at \(String(describing: panel.frame), privacy: .public)")
    startGuard()
  }

  /// Esc cancels the conversion in progress (like the button in the picker).
  var onCancel: (() -> Void)? {
    get { model.onCancel }
    set {
      model.onCancel = newValue
      panel?.onCancel = newValue
    }
  }

  /// Starts the conversion: the picker shows progress and the "Cancel" button.
  func beginWorking() {
    model.status = .working
    model.progress = nil
    dropView?.passesClicksThrough = true
    panel?.acceptsKey = true
    panel?.makeKey()
  }

  /// Safety net: if the mouse button is no longer pressed and the picker
  /// is still waiting, the drag has ended (or been cancelled) without the global
  /// monitor noticing: close. Runs only while the picker is visible.
  private func startGuard() {
    guardTask?.cancel()
    let task = Task { [weak self] in
      var released = 0
      var commandUp = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100), tolerance: .milliseconds(20))
        // Choice made (or panel gone): the guard is done. It used to stay on
        // waking the app for the whole conversion.
        guard let self, self.model.status == .choosing else { return }
        released = NSEvent.pressedMouseButtons & 1 == 0 ? released + 1 : 0
        if released >= 5 {
          self.hide(reason: "mouse button released")
          return
        }
        // Modifiers are read here too: with the pointer still no
        // drag event arrives, and the global `flagsChanged` requires a
        // permission that Convert does not ask for. Without this read ⇧ pressed while
        // still did not change the petals until the mouse moved.
        let flags = NSEvent.modifierFlags
        commandUp = flags.contains(.command) ? 0 : commandUp + 1
        if commandUp >= 2 {
          self.hide(reason: "⌘ rilasciato")
          return
        }
        if commandUp == 0 { self.setAdvanced(flags.contains(.shift)) }
      }
    }
    guardTask = task
    resources.addTask(task)
  }

  func hide(reason: String = "") {
    if panel?.isVisible == true {
      Logger(subsystem: "dev.local.tsukumo", category: "convert").notice(
        "picker hidden: \(reason, privacy: .public)")
    }
    guardTask?.cancel()
    guardTask = nil
    thumbnailTask?.cancel()
    thumbnailTask = nil
    panel?.orderOut(nil)
    panel?.acceptsKey = false
    model.thumbnail = nil
  }

  private func makePanel() -> RadialPanel {
    let side = Self.side
    let panel = RadialPanel(
      contentRect: CGRect(x: 0, y: 0, width: side, height: side),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

    // The drag view sits above the wheel and receives the whole drag (see `draw`).
    let bounds = CGRect(x: 0, y: 0, width: side, height: side)
    let container = NSView(frame: bounds)
    let hosting = NSHostingView(rootView: RadialPicker(model: model))
    hosting.frame = bounds
    hosting.autoresizingMask = [.width, .height]
    let drop = RadialDropView(frame: bounds)
    drop.autoresizingMask = [.width, .height]
    drop.registerForDraggedTypes([.fileURL])
    drop.onHover = { [weak self] offset in self?.hover(offset) }
    drop.onDrop = { [weak self] offset in self?.drop(offset) ?? false }
    drop.onModifiers = { [weak self] flags in
      if flags.contains(.command) { self?.setAdvanced(flags.contains(.shift)) }
    }
    container.addSubview(hosting)
    container.addSubview(drop)
    panel.contentView = container
    dropView = drop
    panel.onCancel = model.onCancel
    return panel
  }

  /// ⇧ pressed or released with the picker open: switches set if the other is not empty.
  func setAdvanced(_ advanced: Bool) {
    guard model.status == .choosing, panel?.isVisible == true else { return }
    let mode = Self.mode(advanced: advanced, formats: model.formats, tools: model.tools)
    guard mode != model.mode else { return }
    model.mode = mode
    model.highlighted = nil
  }

  /// ⌘ = formats, ⌘⇧ = tools; if the requested set is missing the other is shown.
  private static func mode(advanced: Bool, formats: [OutputFormat], tools: [ConvertTool]) -> RadialModel.Mode {
    if advanced, !tools.isEmpty { return .tools }
    if !advanced, !formats.isEmpty { return .formats }
    return formats.isEmpty ? .tools : .formats
  }

  private func hover(_ offset: CGPoint?) {
    guard model.status == .choosing else { return }
    let petal = offset.flatMap { model.layout.petal(at: $0) }
    if petal != model.highlighted { model.highlighted = petal }
  }

  private func drop(_ offset: CGPoint) -> Bool {
    let items = model.items
    guard model.status == .choosing, let index = model.layout.petal(at: offset), items.indices.contains(index)
    else { return false }
    onChoose?(items[index], model.files)
    return true
  }

  private func loadThumbnail(for url: URL?) {
    thumbnailTask?.cancel()
    model.thumbnail = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
    guard let url else { return }
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: 120, height: 120), scale: 2, representationTypes: .thumbnail)
    thumbnailTask = Task { [weak self] in
      guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage,
        !Task.isCancelled
      else { return }
      self?.model.thumbnail = image
    }
  }

  private static func frame(centeredAt point: CGPoint) -> CGRect {
    let side = Self.side
    var frame = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
      let visible = screen.visibleFrame
      frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - side)
      frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - side)
    }
    return frame.integral
  }

  private static func sizeText(for files: [URL]) -> String {
    let bytes = files.reduce(Int64(0)) { total, url in
      total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    return files.count > 1 ? String(localized: "\(files.count) files · \(size)") : size
  }
}
