// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics

/// Positions where Snap can put a window.
public enum SnapAction: String, CaseIterable, Codable, Sendable {
  case leftHalf, rightHalf, topHalf, bottomHalf
  case topLeft, topRight, bottomLeft, bottomRight
  case maximize, center, restore
}

/// Screen edges.
public struct SnapEdges: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let left = SnapEdges(rawValue: 1)
  public static let right = SnapEdges(rawValue: 2)
  public static let top = SnapEdges(rawValue: 4)
  public static let bottom = SnapEdges(rawValue: 8)
}

/// Pure computations, in coordinates with the origin at the top left (the AX ones).
public enum SnapGeometry {
  /// Destination frame inside the screen's usable area. `nil` for `restore`,
  /// which does not depend on the screen.
  public static func frame(for action: SnapAction, current: CGRect, in area: CGRect) -> CGRect? {
    switch action {
    case .restore: return nil
    case .maximize: return area
    case .center:
      let width = min(current.width, area.width)
      let height = min(current.height, area.height)
      return CGRect(
        x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height
      )
    default: return tile(action, in: area)
    }
  }

  /// Halves and quarters: columns and rows from 0 to 2 (0 = first half, 1 = second, 2 = whole).
  private static func tile(_ action: SnapAction, in area: CGRect) -> CGRect {
    let cells: [SnapAction: (column: Int, row: Int)] = [
      .leftHalf: (0, 2), .rightHalf: (1, 2), .topHalf: (2, 0), .bottomHalf: (2, 1),
      .topLeft: (0, 0), .topRight: (1, 0), .bottomLeft: (0, 1), .bottomRight: (1, 1),
    ]
    let cell = cells[action] ?? (2, 2)
    let horizontal = span(cell.column, origin: area.minX, length: area.width)
    let vertical = span(cell.row, origin: area.minY, length: area.height)
    return CGRect(x: horizontal.origin, y: vertical.origin, width: horizontal.length, height: vertical.length)
  }

  /// The first half rounds down, the second takes the rest: no gaps.
  private static func span(_ index: Int, origin: CGFloat, length: CGFloat) -> (origin: CGFloat, length: CGFloat) {
    let half = (length / 2).rounded(.down)
    switch index {
    case 0: return (origin, half)
    case 1: return (origin + half, length - half)
    default: return (origin, length)
    }
  }

  /// Snap zone for a pointer near the screen edges, or `nil`.
  /// Corners give quarters, sides halves, the top edge the full screen.
  public static func action(
    at point: CGPoint, in screen: CGRect, margin: CGFloat = 6, corner: CGFloat = 120,
    ignoring shared: SnapEdges = []
  ) -> SnapAction? {
    guard screen.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
    // An edge shared with another monitor does not snap: there the window is
    // just passing from one screen to the other.
    let nearLeft = !shared.contains(.left) && point.x <= screen.minX + margin
    let nearRight = !shared.contains(.right) && point.x >= screen.maxX - margin
    let nearTop = !shared.contains(.top) && point.y <= screen.minY + margin
    let nearBottom = !shared.contains(.bottom) && point.y >= screen.maxY - margin
    guard nearLeft || nearRight || nearTop || nearBottom else { return nil }

    let inTopBand = point.y <= screen.minY + corner
    let inBottomBand = point.y >= screen.maxY - corner
    let inLeftBand = point.x <= screen.minX + corner
    let inRightBand = point.x >= screen.maxX - corner
    if nearLeft || (inLeftBand && (nearTop || nearBottom)) {
      if inTopBand { return .topLeft }
      if inBottomBand { return .bottomLeft }
      return .leftHalf
    }
    if nearRight || (inRightBand && (nearTop || nearBottom)) {
      if inTopBand { return .topRight }
      if inBottomBand { return .bottomRight }
      return .rightHalf
    }
    return nearTop ? .maximize : nil
  }
}
