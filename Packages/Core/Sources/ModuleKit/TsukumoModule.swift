// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// What the registry hands to a module when it instantiates it.
@MainActor
public final class ModuleContext {
  public let moduleID: String
  /// All the module's resources go through here.
  public let resources: ResourceBag
  public let events: EventBus
  /// Status items and overlay windows, always tied to `resources`.
  public let surfaces: SurfaceManager
  /// Event taps shared between modules.
  public let inputTaps: InputTapService
  /// Persistent preferences isolated for the module.
  public let settings: ModuleSettingsStore
  /// Global hotkeys, with a single conflict table for the app.
  public let hotkeys: Hotkeys
  /// Sampling sources shared and suspended with the screen off/locked.
  public let sampler: SharedSampler

  public init(
    moduleID: String,
    resources: ResourceBag,
    events: EventBus,
    surfaces: SurfaceManager,
    inputTaps: InputTapService,
    settings: ModuleSettingsStore,
    hotkeys: Hotkeys,
    sampler: SharedSampler
  ) {
    self.moduleID = moduleID
    self.resources = resources
    self.events = events
    self.surfaces = surfaces
    self.inputTaps = inputTaps
    self.settings = settings
    self.hotkeys = hotkeys
    self.sampler = sampler
  }
}

/// Contract of a Tsukumo module (DESIGN.md §4.2).
@MainActor
public protocol TsukumoModule: AnyObject, Sendable {
  /// Constant, readable without instantiating and off the MainActor.
  nonisolated static var descriptor: ModuleDescriptor { get }
  /// No side effects: no observers, timers, windows, items.
  init(context: ModuleContext)
  /// Registers resources only through `context.resources`.
  func start() async throws
  /// The `ResourceBag` cancels everything automatically after this call.
  func stop() async
  /// Built only when the Settings page is visible.
  var settings: AnyView { get }
  /// Canary for private APIs.
  var health: ModuleHealth { get async }
}

extension TsukumoModule {
  public var health: ModuleHealth {
    get async { .ok }
  }
}
