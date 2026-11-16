// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import OSLog
import ScreenCaptureKit
import SwiftUI
import Synchronization

/// Switcher preferences.
struct SwitcherPrefs: Codable, Equatable, Sendable {
  var trigger: SwitcherTrigger = .optionTab
  var thumbnails = true
}

/// Alt-Tab with windows (DESIGN.md §2.2). At rest there is only the subscription to the
/// keyboard's active tap (µs per key); list, panel and thumbnails
/// exist only while the switcher is open.
@MainActor
public final class SwitcherModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "switcher",
    nameKey: "Switcher",
    symbol: "rectangle.stack",
    tint: .purple,
    permissions: [.accessibility],
    energyClass: .zero
  )

  private let context: ModuleContext
  private let model = SwitcherSettingsModel()
  private var controller: SwitcherController?
  private var signalGuard: ResourceBag.Token?

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    let prefs: SwitcherPrefs = context.settings.value(forKey: "prefs", moduleID: Self.descriptor.id) ?? SwitcherPrefs()
    model.prefs = prefs
    let controller = SwitcherController(prefs: prefs)
    let keys = controller.keys
    let sink = controller.sink
    let handler: InputTapHandler = { type, event in
      let code = event.getIntegerValueField(.keyboardEventKeycode)
      let (action, consume) = keys.withLock { $0.handle(type: type, keyCode: code, flags: event.flags) }
      if let action { sink.send(action) }
      return consume ? nil : event
    }
    let subscription = try context.inputTaps.subscribe(.active, mask: SwitcherController.mask, handler: handler)
    context.resources.addInputTap(subscription)
    // Spike 6: with which permissions the keyboard's active tap really works.
    Logger(subsystem: "dev.local.tsukumo", category: "switcher").notice(
      "active tap ready; accessibility \(AXIsProcessTrusted()), input monitoring \(CGPreflightListenEventAccess())")
    context.resources.add(.window) { [weak controller] in controller?.close() }
    self.controller = controller
    if prefs.trigger == .commandTab { takeCommandTab() }
    model.onChange = { [weak self] prefs in self?.apply(prefs) }
    model.onRestoreNative = { [weak self] in self?.restoreSystemCommandTab() }
  }

  public func stop() async {
    // Never leave the system ⌘⇥ off with the module stopped (§2.2.1, point 3).
    releaseCommandTab()
    controller?.close()
    controller = nil
    model.onChange = nil
    model.onRestoreNative = nil
  }

  /// "Restore system ⌘⇥": go back to ⌥⇥, so the module truly stops
  /// using ⌘⇥ (saved preference, keys, signals) instead of leaving
  /// `.commandTab` with the system ⌘⇥ turned on again underneath. Then ⌘⇥ is
  /// turned on anyway, even if it was not Tsukumo that turned it off.
  public func restoreSystemCommandTab() {
    if model.prefs.trigger == .commandTab { model.prefs.trigger = .optionTab }
    NativeSwitcherGuard.enableNative()
  }

  public var settings: AnyView { AnyView(SwitcherSettingsView(model: model)) }

  private func apply(_ prefs: SwitcherPrefs) {
    try? context.settings.set(prefs, forKey: "prefs", moduleID: Self.descriptor.id)
    controller?.prefs = prefs
    controller?.keys.withLock { $0.trigger = prefs.trigger }
    if prefs.trigger == .commandTab { takeCommandTab() } else { releaseCommandTab() }
  }

  /// System ⌘⇥ off, with the shutdown signals that turn it back on before
  /// exiting (§2.2.1, point 4): a SIGTERM does not go through `atexit`.
  private func takeCommandTab() {
    NativeSwitcherGuard.disableNative()
    guard signalGuard == nil else { return }
    let sources = [SIGTERM, SIGINT, SIGHUP].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler {
        NativeSwitcherGuard.enableNative()
        // Clean shutdown: the other modules run their `stop()` (for example
        // Island terminates its child process). `exit` remains as a fallback,
        // only once, if the shutdown hangs. On a global queue: if it is
        // the main thread itself that hangs, the fallback must fire all the same.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { exit(0) }
        NSApp.terminate(nil)
      }
      source.activate()
      return (number, source)
    }
    signalGuard = context.resources.add(.other) {
      for (number, source) in sources {
        source.cancel()
        signal(number, SIG_DFL)
      }
    }
  }

  private func releaseCommandTab() {
    // Only if we turned it off: otherwise we would turn on a ⌘⇥ that
    // the user disabled with another tool.
    NativeSwitcherGuard.restoreIfNeeded()
    if let signalGuard { context.resources.cancel(signalGuard) }
    signalGuard = nil
  }
}

/// Key state shared between the tap thread and the MainActor.
final class KeyBox: Sendable {
  private let state: Mutex<SwitcherKeys>

  init(_ keys: SwitcherKeys) {
    state = Mutex(keys)
  }

  func withLock<Result: Sendable>(_ body: (inout SwitcherKeys) -> Result) -> Result {
    state.withLock { body(&$0) }
  }
}

/// Carries the actions from the tap thread to the MainActor.
final class ActionSink: @unchecked Sendable {
  @MainActor weak var controller: SwitcherController?

  func send(_ action: SwitcherAction) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { self.controller?.handle(action) }
    }
  }
}

/// Opens, scrolls and confirms. Lives only with the module on.
@MainActor
final class SwitcherController {
  static let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)
  /// A quick ⌥⇥ changes window without making the panel flash.
  static let showDelay: Duration = .milliseconds(120)

  let keys: KeyBox
  let sink = ActionSink()
  var prefs: SwitcherPrefs
  private let panel = SwitcherPanelController()
  private let log = Logger(subsystem: "dev.local.tsukumo", category: "switcher")
  private var loaded = false
  private var pendingMoves = 0
  private var confirmPending = false
  private var openedAt = ContinuousClock.now
  private var work: [Task<Void, Never>] = []
  private var thumbnailCache = ThumbnailCache()

  init(prefs: SwitcherPrefs) {
    self.prefs = prefs
    keys = KeyBox(SwitcherKeys(trigger: prefs.trigger))
    sink.controller = self
    panel.onPick = { [weak self] index in self?.pick(index) }
  }

  func handle(_ action: SwitcherAction) {
    switch action {
    case .open(let step): open(step: step)
    case .move(let step):
      if loaded { panel.model.move(step) } else { pendingMoves += step }
    case .confirm:
      if loaded { pick(panel.model.selection) } else { confirmPending = true }
    case .cancel: dismiss()
    }
  }

  private func open(step: Int) {
    cancelWork()
    loaded = false
    pendingMoves = 0
    confirmPending = false
    openedAt = .now
    let own = ProcessInfo.processInfo.processIdentifier
    let load = Task { [weak self] in
      let windows = await Task.detached(priority: .userInitiated) { WindowCatalog.load(excluding: own) }.value
      guard let self, !Task.isCancelled else { return }
      self.loaded(windows, step: step)
    }
    let show = Task { [weak self] in
      try? await Task.sleep(for: Self.showDelay)
      guard let self, !Task.isCancelled, self.keys.withLock({ $0.isOpen }), self.loaded else { return }
      self.panel.show()
    }
    work = [load, show]
  }

  private func loaded(_ windows: [SwitcherWindow], step: Int) {
    let model = panel.model
    model.windows = windows
    model.icons = Dictionary(
      windows.map { ($0.pid, NSRunningApplication(processIdentifier: $0.pid)?.icon ?? NSImage()) },
      uniquingKeysWith: { first, _ in first })
    model.thumbnails = thumbnailCache.images(for: windows.map(\.id))
    model.selection = step > 0 ? min(1, max(windows.count - 1, 0)) : max(windows.count - 1, 0)
    model.move(pendingMoves)
    loaded = true
    log.notice("switcher: \(windows.count) windows")
    if confirmPending {
      pick(model.selection)
      return
    }
    if ContinuousClock.now - openedAt >= Self.showDelay, keys.withLock({ $0.isOpen }) { panel.show() }
    if prefs.thumbnails, CGPreflightScreenCaptureAccess() { captureThumbnails(for: windows) }
  }

  private func pick(_ index: Int) {
    keys.withLock { $0.reset() }
    let window = panel.model.windows.indices.contains(index) ? panel.model.windows[index] : nil
    dismiss()
    if let window { WindowFocuser.focus(window) }
  }

  private func dismiss() {
    cancelWork()
    keys.withLock { $0.reset() }
    panel.hide()
  }

  func close() {
    dismiss()
    panel.close()
  }

  private func cancelWork() {
    for task in work { task.cancel() }
    work = []
  }

  /// Thumbnails with ScreenCaptureKit, only if the permission is already there: never a prompt
  /// from here. The windows closest to the selection first.
  private func captureThumbnails(for windows: [SwitcherWindow]) {
    let ids = Set(windows.prefix(18).map(\.id))
    let task = Task { [weak self] in
      guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
      else { return }
      for window in content.windows where ids.contains(window.windowID) {
        guard !Task.isCancelled else { return }
        let configuration = SCStreamConfiguration()
        let scale = 320 / max(window.frame.width, 1)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard
          let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        else { continue }
        let picture = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        guard let self, !Task.isCancelled else { return }
        self.thumbnailCache.insert(picture, for: window.windowID)
        self.panel.model.thumbnails[window.windowID] = picture
      }
    }
    work.append(task)
  }
}

/// LRU cache of 320 px thumbnails (DESIGN.md §5.1: ≤ 40 MB).
struct ThumbnailCache {
  private var images: [CGWindowID: NSImage] = [:]
  private var order: [CGWindowID] = []
  /// ~320×200×4 bytes ≈ 256 kB each: 120 thumbnails ≈ 30 MB.
  static let limit = 120

  func images(for ids: [CGWindowID]) -> [CGWindowID: NSImage] {
    ids.reduce(into: [:]) { result, id in result[id] = images[id] }
  }

  mutating func insert(_ image: NSImage, for id: CGWindowID) {
    images[id] = image
    order.removeAll { $0 == id }
    order.append(id)
    while order.count > Self.limit {
      images[order.removeFirst()] = nil
    }
  }
}

@MainActor
@Observable
final class SwitcherSettingsModel {
  var prefs = SwitcherPrefs() { didSet { if prefs != oldValue { onChange?(prefs) } } }
  var onChange: ((SwitcherPrefs) -> Void)?
  var onRestoreNative: (() -> Void)?
}

struct SwitcherSettingsView: View {
  @Bindable var model: SwitcherSettingsModel

  var body: some View {
    Form {
      Section {
        Picker("Open with", selection: $model.prefs.trigger) {
          Text("⌥⇥ (recommended)").tag(SwitcherTrigger.optionTab)
          Text("⌘⇥ instead of the system switcher").tag(SwitcherTrigger.commandTab)
        }
        Label(
          "Hold the modifier and press ⇥ or the arrow keys; release to switch to the window",
          systemImage: "keyboard")
        Label("Esc cancels, ⇧⇥ goes back", systemImage: "escape")
      } header: {
        Text("Shortcut")
      } footer: {
        if model.prefs.trigger == .commandTab {
          Text(
            "If Tsukumo quits unexpectedly, the system ⌘⇥ comes back the next time Tsukumo starts or when you log out."
          )
        }
      }
      Section {
        Toggle("Show window thumbnails", isOn: $model.prefs.thumbnails)
        Button("Restore System ⌘⇥") {
          if let restore = model.onRestoreNative { restore() } else { NativeSwitcherGuard.enableNative() }
        }
      } footer: {
        Text("Thumbnails require Screen Recording permission; without it, the switcher shows icons and titles.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text("Switcher"))
  }
}
