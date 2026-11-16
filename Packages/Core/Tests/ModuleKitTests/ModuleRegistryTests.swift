// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftUI
import Testing

@testable import ModuleKit

@MainActor
private final class ProbeModule: TsukumoModule {
  nonisolated static let descriptor = ModuleDescriptor(
    id: "test.probe", nameKey: "module.probe.name", symbol: "ant", tint: .gray, energyClass: .zero
  )

  struct StartFailure: Error {}

  nonisolated(unsafe) static var shouldFailStart = false
  nonisolated(unsafe) static var reportedHealth: ModuleHealth = .ok

  private let context: ModuleContext
  private(set) var stopped = false

  init(context: ModuleContext) {
    self.context = context
  }

  func start() async throws {
    context.resources.add(.other) {}
    context.resources.addTimer(every: .seconds(60)) {}
    if Self.shouldFailStart { throw StartFailure() }
  }

  func stop() async {
    stopped = true
  }

  var settings: AnyView { AnyView(EmptyView()) }

  var health: ModuleHealth {
    get async { Self.reportedHealth }
  }
}

@MainActor
private final class FutureModule: TsukumoModule {
  nonisolated static let descriptor = ModuleDescriptor(
    id: "test.future", nameKey: "module.future.name", symbol: "sparkles", tint: .blue,
    energyClass: .zero, minOSMajor: 99
  )

  init(context: ModuleContext) {}
  func start() async throws {}
  func stop() async {}
  var settings: AnyView { AnyView(EmptyView()) }
}

/// `start()` stays suspended until the test unblocks it, then registers a resource.
@MainActor
private final class SlowModule: TsukumoModule {
  nonisolated static let descriptor = ModuleDescriptor(
    id: "test.slow", nameKey: "module.slow.name", symbol: "tortoise", tint: .gray, energyClass: .zero
  )

  nonisolated(unsafe) static var gate: CheckedContinuation<Void, Never>?
  nonisolated(unsafe) static var lateResourceCancelled = false
  nonisolated(unsafe) static var stopCount = 0

  private let context: ModuleContext

  init(context: ModuleContext) {
    self.context = context
  }

  func start() async throws {
    await withCheckedContinuation { Self.gate = $0 }
    context.resources.add(.other) { Self.lateResourceCancelled = true }
  }

  func stop() async {
    Self.stopCount += 1
  }

  var settings: AnyView { AnyView(EmptyView()) }
}

/// `stop()` stays suspended until the test unblocks it.
@MainActor
private final class SlowStopModule: TsukumoModule {
  nonisolated static let descriptor = ModuleDescriptor(
    id: "test.slowstop", nameKey: "module.slowstop.name", symbol: "tortoise", tint: .gray, energyClass: .zero
  )

  nonisolated(unsafe) static var gate: CheckedContinuation<Void, Never>?
  nonisolated(unsafe) static var startCount = 0

  init(context: ModuleContext) {}

  func start() async throws {
    Self.startCount += 1
  }

  func stop() async {
    await withCheckedContinuation { Self.gate = $0 }
  }

  var settings: AnyView { AnyView(EmptyView()) }
}

@MainActor
@Suite("ModuleRegistry", .serialized)
struct ModuleRegistryTests {
  private let id = ProbeModule.descriptor.id

  init() {
    ProbeModule.shouldFailStart = false
    ProbeModule.reportedHealth = .ok
  }

  @Test("a duplicate id is rejected")
  func duplicateIDRejected() throws {
    let registry = ModuleRegistry()
    try registry.register(ProbeModule.self)
    #expect(throws: ModuleRegistryError.duplicateID(id)) {
      try registry.register(ProbeModule.self)
    }
    #expect(registry.entries.count == 1)
  }

  @Test("a registered but off module is not instantiated")
  func registeredModuleIsNotInstantiated() throws {
    let registry = ModuleRegistry()
    try registry.register(ProbeModule.self)

    #expect(registry.state(of: id) == .off)
    #expect(registry.module(id) == nil)
    #expect(registry.resources(of: id) == nil)
    #expect(registry.liveCount == 0)
  }

  @Test("enable → disable: resources closed and instance released")
  func enableDisableCycle() async throws {
    let registry = ModuleRegistry()
    try registry.register(ProbeModule.self)

    try await registry.enable(id)
    #expect(registry.state(of: id) == .running)
    let resources = try #require(registry.resources(of: id))
    #expect(resources.count == 2)
    weak let module = registry.module(id) as? ProbeModule
    #expect(module != nil)

    await registry.disable(id)
    #expect(registry.state(of: id) == .off)
    #expect(resources.isEmpty)
    #expect(registry.liveCount == 0)
    #expect(module == nil)
  }

  @Test("disable during start(): no orphan resources and the state stays off")
  func disableWhileStarting() async throws {
    SlowModule.gate = nil
    SlowModule.lateResourceCancelled = false
    SlowModule.stopCount = 0
    let slow = SlowModule.descriptor.id
    let registry = ModuleRegistry()
    try registry.register(SlowModule.self)

    let enabling = Task { try? await registry.enable(slow) }
    while SlowModule.gate == nil { await Task.yield() }
    #expect(registry.state(of: slow) == .starting)

    await registry.disable(slow)
    SlowModule.gate?.resume()
    await enabling.value

    #expect(registry.state(of: slow) == .off)
    #expect(registry.module(slow) == nil)
    // The resource registered after the shutdown was closed immediately,
    // and the state built after the first stop() was torn down again.
    #expect(SlowModule.lateResourceCancelled)
    #expect(SlowModule.stopCount == 2)
  }

  @Test("enable during stop(): waits for the shutdown to finish and turns on again")
  func enableWhileStopping() async throws {
    SlowStopModule.gate = nil
    SlowStopModule.startCount = 0
    let slow = SlowStopModule.descriptor.id
    let registry = ModuleRegistry()
    try registry.register(SlowStopModule.self)
    try await registry.enable(slow)

    let disabling = Task { await registry.disable(slow) }
    while SlowStopModule.gate == nil { await Task.yield() }
    let enabling = Task { try? await registry.enable(slow) }
    for _ in 0..<10 { await Task.yield() }
    // Until stop() finishes the module does not restart.
    #expect(SlowStopModule.startCount == 1)

    SlowStopModule.gate?.resume()
    await disabling.value
    await enabling.value

    #expect(registry.state(of: slow) == .running)
    #expect(registry.module(slow) != nil)
    #expect(SlowStopModule.startCount == 2)
    SlowStopModule.gate = nil
    let cleanup = Task { await registry.disable(slow) }
    while SlowStopModule.gate == nil { await Task.yield() }
    SlowStopModule.gate?.resume()
    await cleanup.value
  }

  @Test("if start() throws, the module is suspended and leaves no resources")
  func startFailureSuspends() async throws {
    ProbeModule.shouldFailStart = true
    let registry = ModuleRegistry()
    try registry.register(ProbeModule.self)

    try await registry.enable(id)

    guard case .suspended = registry.state(of: id) else {
      Issue.record("Expected state: suspended, found \(registry.state(of: id))")
      return
    }
    #expect(registry.liveCount == 0)
  }

  @Test("a broken canary suspends the module")
  func brokenHealthSuspends() async throws {
    let registry = ModuleRegistry()
    try registry.register(ProbeModule.self)
    try await registry.enable(id)

    ProbeModule.reportedHealth = .broken("API cambiata")
    let health = await registry.checkHealth(of: id)

    #expect(health == .broken("API cambiata"))
    #expect(registry.state(of: id) == .suspended(reason: "API cambiata"))
    #expect(registry.liveCount == 0)
  }

  @Test("a module that requires a newer OS does not start")
  func unsupportedOSRejected() async throws {
    let registry = ModuleRegistry(
      osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    )
    try registry.register(FutureModule.self)
    let futureID = FutureModule.descriptor.id

    await #expect(throws: ModuleRegistryError.unsupportedOS(id: futureID, required: "99.0")) {
      try await registry.enable(futureID)
    }
    #expect(registry.liveCount == 0)
    #expect(registry.state(of: futureID) == .off)
  }

  @Test("an unknown id is an error")
  func unknownID() async {
    let registry = ModuleRegistry()
    await #expect(throws: ModuleRegistryError.unknownID("nope")) {
      try await registry.enable("nope")
    }
  }

  @Test("version comparison uses major and minor")
  func descriptorVersionCheck() {
    let descriptor = ModuleDescriptor(
      id: "x", nameKey: "x", symbol: "x", tint: .red, energyClass: .low, minOSMajor: 26, minOSMinor: 2
    )
    #expect(!descriptor.supports(osMajor: 26, osMinor: 1))
    #expect(descriptor.supports(osMajor: 26, osMinor: 2))
    #expect(descriptor.supports(osMajor: 27, osMinor: 0))
  }
}
