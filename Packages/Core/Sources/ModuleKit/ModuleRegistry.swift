// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation
import os

/// Registry entry: the descriptor plus the factory. Registering an entry does not
/// run module code.
public struct ModuleEntry: Sendable {
  public let descriptor: ModuleDescriptor
  public let factory: @MainActor @Sendable (ModuleContext) -> any TsukumoModule

  public init(
    descriptor: ModuleDescriptor,
    factory: @escaping @MainActor @Sendable (ModuleContext) -> any TsukumoModule
  ) {
    self.descriptor = descriptor
    self.factory = factory
  }

  public init<Module: TsukumoModule>(_ type: Module.Type) {
    self.init(descriptor: type.descriptor) { Module(context: $0) }
  }
}

public enum ModuleState: Sendable, Equatable {
  case off
  case starting
  case running
  /// `start()` failed or `health` reported a fault: the module is
  /// paused and the rest of the app carries on.
  case suspended(reason: String)
}

public enum ModuleRegistryError: Error, Equatable {
  case duplicateID(String)
  case unknownID(String)
  case unsupportedOS(id: String, required: String)
  /// Verifiable permissions not yet granted: the module is not instantiated.
  case missingPermissions(id: String, permissions: [Permission])
}

/// Module registry, keyed on `id: String`. A module that is off is not
/// instantiated: only its `ModuleEntry` exists.
@MainActor
@Observable
public final class ModuleRegistry {
  private struct Live {
    let module: any TsukumoModule
    let resources: ResourceBag
  }

  public private(set) var entries: [ModuleEntry] = []
  public private(set) var states: [String: ModuleState] = [:]

  @ObservationIgnored private var live: [String: Live] = [:]
  /// Modules whose `stop()` is still in progress, with whoever is waiting for it to finish
  /// to turn them back on: a quick off→on must not be lost.
  @ObservationIgnored private var stopping: [String: [CheckedContinuation<Void, Never>]] = [:]
  @ObservationIgnored private let events: EventBus
  @ObservationIgnored private let osVersion: OperatingSystemVersion
  @ObservationIgnored private let permissions: PermissionBroker?
  /// Status items and overlays of the modules; Settings reads it for the visibility checkmarks.
  @ObservationIgnored public let surfaces: SurfaceManager
  @ObservationIgnored private let inputTaps: InputTapService
  @ObservationIgnored private let settings: ModuleSettingsStore
  @ObservationIgnored private let hotkeys: Hotkeys
  @ObservationIgnored private let sampler: SharedSampler
  @ObservationIgnored private let log = Logger(subsystem: "tsukumo.core", category: "registry")

  public init(
    events: EventBus = EventBus(),
    osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    permissions: PermissionBroker? = nil,
    surfaces: SurfaceManager = SurfaceManager(),
    inputTaps: InputTapService = InputTapService(),
    settings: ModuleSettingsStore = .shared,
    hotkeys: Hotkeys = .shared,
    sampler: SharedSampler = SharedSampler()
  ) {
    self.events = events
    self.osVersion = osVersion
    self.permissions = permissions
    self.surfaces = surfaces
    self.inputTaps = inputTaps
    self.settings = settings
    self.hotkeys = hotkeys
    self.sampler = sampler
  }

  // MARK: Registration

  public func register(_ entry: ModuleEntry) throws(ModuleRegistryError) {
    let id = entry.descriptor.id
    guard !entries.contains(where: { $0.descriptor.id == id }) else { throw .duplicateID(id) }
    entries.append(entry)
    states[id] = .off
  }

  public func register<Module: TsukumoModule>(_ type: Module.Type) throws(ModuleRegistryError) {
    try register(ModuleEntry(type))
  }

  // MARK: State

  public func state(of id: String) -> ModuleState {
    states[id] ?? .off
  }

  public func isRunning(_ id: String) -> Bool {
    state(of: id) == .running
  }

  /// Live instance of the module; `nil` if it is off.
  public func module(_ id: String) -> (any TsukumoModule)? {
    live[id]?.module
  }

  /// Live resources of the module; `nil` if it is off.
  public func resources(of id: String) -> ResourceBag? {
    live[id]?.resources
  }

  /// Number of instantiated modules.
  public var liveCount: Int { live.count }

  // MARK: Lifecycle

  /// Turns a module on. If `start()` throws, the module goes to `.suspended`,
  /// its resources are closed and the error does not propagate to the rest of the app.
  public func enable(_ id: String) async throws(ModuleRegistryError) {
    guard let entry = entries.first(where: { $0.descriptor.id == id }) else { throw .unknownID(id) }
    // A shutdown in progress is awaited, then the module is turned back on (the loop covers a
    // second shutdown that arrived in the meantime).
    while stopping[id] != nil {
      await withCheckedContinuation { stopping[id, default: []].append($0) }
    }
    guard live[id] == nil, state(of: id) != .starting else { return }

    let descriptor = entry.descriptor
    guard descriptor.supports(osMajor: osVersion.majorVersion, osMinor: osVersion.minorVersion) else {
      throw .unsupportedOS(id: id, required: "\(descriptor.minOSMajor).\(descriptor.minOSMinor)")
    }

    // Permissions first, then start() (DESIGN.md §4.2, lazy start).
    if let missing = permissions?.missing(from: descriptor.permissions), !missing.isEmpty {
      throw .missingPermissions(id: id, permissions: missing)
    }

    states[id] = .starting
    let resources = ResourceBag()
    let context = ModuleContext(
      moduleID: id, resources: resources, events: events, surfaces: surfaces, inputTaps: inputTaps,
      settings: settings, hotkeys: hotkeys, sampler: sampler
    )
    let module = entry.factory(context)
    live[id] = Live(module: module, resources: resources)

    do {
      try await module.start()
      guard live[id]?.module === module else {
        // Turned off while `start()` was in progress: the bag is already closed, but the
        // state built after `stop()` must be torn down again.
        await module.stop()
        return
      }
      states[id] = .running
    } catch {
      log.error("Modulo \(id, privacy: .public) sospeso: \(String(describing: error), privacy: .public)")
      guard live[id]?.module === module else { return }
      await teardown(id)
      states[id] = .suspended(reason: String(describing: error))
    }
  }

  /// Turns a module off: `stop()`, closing the `ResourceBag`, releasing the instance.
  public func disable(_ id: String) async {
    await teardown(id)
    if states[id] != nil {
      states[id] = .off
    }
  }

  public func disableAll() async {
    for id in Array(live.keys) {
      await disable(id)
    }
  }

  /// Queries the module's canary and suspends it if it is broken.
  @discardableResult
  public func checkHealth(of id: String) async -> ModuleHealth? {
    guard let module = live[id]?.module else { return nil }
    let health = await module.health
    if case .broken(let reason) = health {
      await teardown(id)
      states[id] = .suspended(reason: reason)
    }
    return health
  }

  private func teardown(_ id: String) async {
    guard let entry = live.removeValue(forKey: id) else { return }
    stopping[id] = []
    await entry.module.stop()
    entry.resources.close()
    assert(entry.resources.isEmpty, "ResourceBag not empty after stop() of \(id)")
    // Whoever was waiting resumes after this round: the final state (`.off`,
    // `.suspended`) is written earlier by the caller of `teardown`.
    for waiter in stopping.removeValue(forKey: id) ?? [] { waiter.resume() }
  }
}
