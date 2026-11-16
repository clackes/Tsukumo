// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import ModuleKit
import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Design tokens")
struct TokensTests {
  @Test("the spacing scale is increasing")
  func spacingScaleIsMonotonic() {
    let scale = [
      TsukumoTokens.Spacing.xxs, TsukumoTokens.Spacing.xs, TsukumoTokens.Spacing.sm, TsukumoTokens.Spacing.md,
      TsukumoTokens.Spacing.lg, TsukumoTokens.Spacing.xl, TsukumoTokens.Spacing.xxl,
    ]
    #expect(scale == scale.sorted())
    #expect(Set(scale).count == scale.count)
  }

  @Test("every ModuleTint has a distinct color")
  func everyTintHasAColor() {
    let colors = ModuleTint.allCases.map(\.color)
    #expect(Set(colors).count == ModuleTint.allCases.count)
  }

  @MainActor
  @Test("GlassCard and ModuleIcon are built without side effects")
  func componentsBuild() {
    _ = GlassCard { Text("Tsukumo") }
    _ = ModuleIcon(symbol: "hand.wave", color: ModuleTint.mint.color)
  }
}
