// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import ModuleKit
import SwiftUI

/// Design tokens shared by app and modules.
public enum TsukumoTokens {
  /// Spacing scale (pt), on a 4-point grid.
  public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
  }

  /// Corner radii (pt), always with `.continuous` style.
  public enum Radius {
    public static let control: CGFloat = 8
    public static let card: CGFloat = 14
    public static let panel: CGFloat = 18
  }

  /// Recurring sizes (pt).
  public enum Size {
    public static let moduleIcon: CGFloat = 26
    public static let sidebarMinWidth: CGFloat = 210
    public static let settingsMinWidth: CGFloat = 720
    public static let settingsMinHeight: CGFloat = 460
  }

  /// Animation durations (seconds).
  public enum Motion {
    public static let quick: Double = 0.18
    public static let standard: Double = 0.3
  }
}

extension ModuleTint {
  /// Corresponding system color: adapts by itself to theme and contrast.
  public var color: Color {
    switch self {
    case .blue: .blue
    case .cyan: .cyan
    case .green: .green
    case .indigo: .indigo
    case .mint: .mint
    case .orange: .orange
    case .pink: .pink
    case .purple: .purple
    case .red: .red
    case .teal: .teal
    case .yellow: .yellow
    case .gray: .gray
    }
  }
}
