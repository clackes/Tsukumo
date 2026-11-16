// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import PrivateBridges

@Suite("Private bridges: availability")
struct PrivateBridgesTests {
  /// On macOS 26+ these two frameworks must exist: if they disappear, CI
  /// notices right away, not a user.
  @Test("SkyLight opens and has the symbols we use")
  func skyLightAvailable() {
    #expect(SkyLightBridge.shared.isAvailable)
    #expect(SkyLightBridge.hasSymbolicHotKey)
  }

  @Test("DisplayServices opens")
  func displayServicesAvailable() {
    #expect(DisplayServicesBridge.shared.isAvailable)
  }

  @Test("a nonexistent path does not crash")
  func missingFramework() {
    let handle = FrameworkHandle(path: "/does/not/exist.framework/Nope")
    #expect(!handle.isAvailable)
    #expect(handle.symbol("nope", as: (@convention(c) () -> Int).self) == nil)
  }
}
