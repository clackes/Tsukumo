// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Base Liquid Glass surface for the controls layer (DESIGN.md §3.1).
///
/// With Reduce Transparency on it uses a static material. It must not be used on
/// content or on always-on surfaces (§5.2 rule 5).
public struct GlassCard<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private let cornerRadius: CGFloat
  private let padding: CGFloat
  private let content: Content

  public init(
    cornerRadius: CGFloat = TsukumoTokens.Radius.card,
    padding: CGFloat = TsukumoTokens.Spacing.lg,
    @ViewBuilder content: () -> Content
  ) {
    self.cornerRadius = cornerRadius
    self.padding = padding
    self.content = content()
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if reduceTransparency {
      content
        .padding(padding)
        .background(.regularMaterial, in: shape)
    } else {
      content
        .padding(padding)
        .glassEffect(.regular, in: shape)
    }
  }
}

/// Icon of a module: SF Symbol on a colored background, as in System Settings.
public struct ModuleIcon: View {
  private let symbol: String
  private let color: Color
  private let size: CGFloat

  public init(symbol: String, color: Color, size: CGFloat = TsukumoTokens.Size.moduleIcon) {
    self.symbol = symbol
    self.color = color
    self.size = size
  }

  public var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.54, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
      .accessibilityHidden(true)
  }
}
