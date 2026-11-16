// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Carbon.HIToolbox
import DesignSystem
import ModuleKit
import Observation
import SwiftUI

@MainActor
@Observable
public final class SnapModel {
  public fileprivate(set) var hotkeys: [SnapAction: Hotkey] = [:]
  public fileprivate(set) var errors: [SnapAction: String] = [:]
  public fileprivate(set) var dragEnabled = true
  /// macOS native edge tiling is on: it overlaps ours.
  public fileprivate(set) var nativeTilingEnabled = false
}

/// Window snapping with shortcuts and by dragging to the edges.
/// At rest: Carbon hotkeys and, with snapping by dragging, a click monitor.
/// Both event-driven, but the monitor wakes up on every click: "low" class.
@MainActor
public final class SnapModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "snap",
    nameKey: "Windows",
    symbol: "rectangle.split.2x1",
    tint: .blue,
    permissions: [.accessibility],
    energyClass: .low
  )

  /// Default shortcuts: ⌃⌥ plus arrows and letters, like the most common tools.
  static let defaultHotkeys: [SnapAction: Hotkey] = {
    let modifiers = UInt32(controlKey | optionKey)
    let keys: [SnapAction: Int] = [
      .leftHalf: kVK_LeftArrow, .rightHalf: kVK_RightArrow, .topHalf: kVK_UpArrow, .bottomHalf: kVK_DownArrow,
      .topLeft: kVK_ANSI_U, .topRight: kVK_ANSI_I, .bottomLeft: kVK_ANSI_J, .bottomRight: kVK_ANSI_K,
      .maximize: kVK_Return, .center: kVK_ANSI_C, .restore: kVK_Delete,
    ]
    return keys.mapValues { Hotkey(keyCode: UInt32($0), modifiers: modifiers) }
  }()

  public private(set) var model: SnapModel?
  private let context: ModuleContext
  private var hotkeyTokens: [SnapAction: ResourceBag.Token] = [:]
  private var dragController: SnapDragController?
  private var snapper = WindowSnapper()

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    let model = SnapModel()
    self.model = model
    let saved: [String: Hotkey]? = context.settings.value(forKey: "hotkeys", moduleID: Self.descriptor.id)
    if let saved {
      model.hotkeys = saved.reduce(into: [:]) { result, entry in
        if let action = SnapAction(rawValue: entry.key) { result[action] = entry.value }
      }
    } else {
      model.hotkeys = Self.defaultHotkeys
    }
    for (action, hotkey) in model.hotkeys { register(hotkey, for: action) }

    model.dragEnabled = context.settings.value(forKey: "dragEnabled", moduleID: Self.descriptor.id) ?? true
    if model.dragEnabled { startDragController() }
  }

  public func stop() async {
    dragController = nil
    hotkeyTokens.removeAll()
    snapper = WindowSnapper()
    model = nil
  }

  public var settings: AnyView {
    AnyView(SnapSettingsView(model: model, module: self))
  }

  // MARK: Actions

  func perform(_ action: SnapAction) {
    guard let window = TargetWindow.focused() else {
      NSSound.beep()
      return
    }
    snapper.apply(action, to: window)
  }

  func setHotkey(_ hotkey: Hotkey?, for action: SnapAction) {
    guard let model else { return }
    if let token = hotkeyTokens.removeValue(forKey: action) { context.resources.cancel(token) }
    model.hotkeys[action] = hotkey
    model.errors[action] = nil
    if let hotkey { register(hotkey, for: action) }
    let stored = Dictionary(uniqueKeysWithValues: model.hotkeys.map { ($0.key.rawValue, $0.value) })
    try? context.settings.set(stored, forKey: "hotkeys", moduleID: Self.descriptor.id)
  }

  func setDragEnabled(_ enabled: Bool) {
    guard let model, model.dragEnabled != enabled else { return }
    model.dragEnabled = enabled
    try? context.settings.set(enabled, forKey: "dragEnabled", moduleID: Self.descriptor.id)
    if enabled {
      startDragController()
    } else {
      dragController?.invalidate()
      dragController = nil
      refreshNativeTiling()
    }
  }

  private func register(_ hotkey: Hotkey, for action: SnapAction) {
    do {
      let subscription = try context.hotkeys.register(hotkey) { [weak self] in self?.perform(action) }
      hotkeyTokens[action] = context.resources.addHotkey(subscription)
    } catch HotkeyError.unsupportedCombination {
      model?.errors[action] = String(localized: "The shortcut needs ⌘ or ⌃.")
    } catch {
      model?.errors[action] = String(localized: "Shortcut already in use.")
    }
  }

  /// Rereads the native tiling: at the start of the drag and when the
  /// module's Settings are opened, never at intervals.
  func refreshNativeTiling() {
    guard let model else { return }
    let enabled = model.dragEnabled && NativeTiling.isEdgeDragEnabled
    if model.nativeTilingEnabled != enabled { model.nativeTilingEnabled = enabled }
  }

  func openNativeTilingSettings() {
    NativeTiling.openSettings()
  }

  private func startDragController() {
    refreshNativeTiling()
    dragController = SnapDragController(resources: context.resources) { [weak self] action, window, area, original in
      // Same screen as the preview, and "Restore" goes back to before the drag.
      self?.snapper.apply(action, to: window, area: area, original: original)
    }
  }
}

/// Applies the actions and remembers the original frame for "Restore".
@MainActor
struct WindowSnapper {
  private struct Saved {
    let original: CGRect
    let snapped: CGRect
  }

  private var saved: [CGWindowID: Saved] = [:]

  mutating func apply(
    _ action: SnapAction, to window: TargetWindow, area: CGRect? = nil, original dragOrigin: CGRect? = nil
  ) {
    guard !window.isFullScreen, let current = window.frame else {
      NSSound.beep()
      return
    }
    let identifier = window.windowID
    if action == .restore {
      guard let identifier, let entry = saved.removeValue(forKey: identifier) else { return }
      window.setFrame(entry.original)
      return
    }
    let center = CGPoint(x: current.midX, y: current.midY)
    guard
      let area = area ?? ScreenSpace.screen(containing: center).map({ ScreenSpace.flipped($0.visibleFrame) }),
      let target = SnapGeometry.frame(for: action, current: current, in: area)
    else { return }
    window.setFrame(target)

    guard let identifier else { return }
    // If the window is still where we put it, the original stays the previous one.
    let original =
      saved[identifier].flatMap { Self.matches($0.snapped, current) ? $0.original : nil } ?? dragOrigin ?? current
    if saved.count > 64 { saved.removeAll() }
    saved[identifier] = Saved(original: original, snapped: window.frame ?? target)
  }

  private static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
      && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
  }
}
