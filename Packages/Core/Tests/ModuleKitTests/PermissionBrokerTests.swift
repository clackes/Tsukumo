// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftUI
import Testing

@testable import ModuleKit

@MainActor
private final class GuardedModule: TsukumoModule {
  nonisolated static let descriptor = ModuleDescriptor(
    id: "test.guarded", nameKey: "module.guarded.name", symbol: "lock", tint: .red,
    permissions: [.accessibility, .screenRecording, .localNetwork], energyClass: .low
  )
  nonisolated(unsafe) static var instances = 0

  init(context: ModuleContext) { Self.instances += 1 }
  func start() async throws {}
  func stop() async {}
  var settings: AnyView { AnyView(EmptyView()) }
}

@MainActor
@Suite("PermissionBroker", .serialized)
struct PermissionBrokerTests {
  private let id = GuardedModule.descriptor.id

  init() {
    GuardedModule.instances = 0
  }

  @Test("missing lists only the verifiable and not granted permissions, in order")
  func missingList() {
    let broker = PermissionBroker { permission in
      switch permission {
      case .accessibility: .denied
      case .screenRecording: .notDetermined
      case .calendars: .granted
      default: .unknown
      }
    }
    #expect(
      broker.missing(from: [.screenRecording, .accessibility, .calendars, .bluetooth]) == [
        .accessibility, .screenRecording,
      ])
    #expect(broker.missing(from: []).isEmpty)
  }

  @Test("every permission has a deep link to System Settings")
  func settingsLinks() {
    let urls = Permission.allCases.compactMap(PermissionBroker.settingsURL)
    #expect(urls.count == Permission.allCases.count)
    #expect(Set(urls).count == urls.count)
    #expect(urls.allSatisfy { $0.scheme == "x-apple.systempreferences" })
  }

  @Test("without permissions the module is not instantiated")
  func registryBlocksOnMissingPermissions() async throws {
    let registry = ModuleRegistry(permissions: PermissionBroker { $0 == .accessibility ? .denied : .granted })
    try registry.register(GuardedModule.self)

    await #expect(throws: ModuleRegistryError.missingPermissions(id: id, permissions: [.accessibility])) {
      try await registry.enable(id)
    }
    #expect(registry.state(of: id) == .off)
    #expect(registry.liveCount == 0)
    #expect(GuardedModule.instances == 0)
  }

  @Test("with permissions granted the module starts; the non-verifiable ones do not block")
  func registryStartsWhenGranted() async throws {
    let registry = ModuleRegistry(permissions: PermissionBroker { $0 == .localNetwork ? .unknown : .granted })
    try registry.register(GuardedModule.self)

    try await registry.enable(id)
    #expect(registry.state(of: id) == .running)
    await registry.disable(id)
  }

  @Test("system state is read without a prompt for every permission")
  func systemStatusIsReadable() {
    let broker = PermissionBroker()
    for permission in Permission.allCases {
      _ = broker.status(of: permission)
    }
    #expect(broker.status(of: .localNetwork) == .unknown)
  }
}
