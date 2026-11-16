// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Shape of the island. The panel frame always matches the shape (DESIGN.md §2.1.1).
enum IslandPresentation: String, Sendable, CaseIterable {
  /// Just the physical notch rectangle: solid black and static.
  case collapsed
  /// Notch widened on the sides for a short activity (charging, track change).
  case compact
  /// Notch extended only to the left, with the lock next to the notch.
  case lock
  /// A line of song text just below the notch.
  case lyrics
  /// Volume or brightness bar just below the notch.
  case hud
  /// Open panel with the controls.
  case expanded
}

/// Temporary activity shown in the compact shape.
enum IslandActivity: Equatable, Sendable {
  case charging(percent: Int?)
  case track(title: String)
  case event(title: String, minutes: Int)
  /// Screen locked (closed lock) or just unlocked (opening lock).
  case lock(isLocked: Bool)
  /// Volume or brightness just changed with the keys.
  case hud(kind: HUDKind, level: Float, muted: Bool)

  var isHUD: Bool {
    if case .hud = self { return true }
    return false
  }

  var isLock: Bool {
    if case .lock = self { return true }
    return false
  }
}

/// Notch rectangle in AppKit coordinates (origin at bottom left).
struct NotchMetrics: Equatable, Sendable {
  var rect: CGRect
  /// `false` on screens without a notch: there the island is a pill that appears only for events.
  var isPhysical: Bool
}

enum IslandGeometry {
  /// Width of each side added in the compact shape.
  static let earWidth: CGFloat = 52
  /// Width of the left side hosting the lock: the notch does not widen to the right.
  static let lockEarWidth: CGFloat = 34
  static let expandedMinWidth: CGFloat = 400
  static let expandedBodyHeight: CGFloat = 92
  /// Extra player height when there is a track: time and controls rows.
  static let playerExtraHeight: CGFloat = 58
  static let pillWidth: CGFloat = 180
  static let fallbackMenuBarHeight: CGFloat = 24
  /// Height of the files row at the bottom of the open island.
  static let shelfHeight: CGFloat = 78
  /// Height of the song text row under the notch.
  static let lyricsRowHeight: CGFloat = 28
  static let lyricsMinWidth: CGFloat = 340
  /// Height of the next event row in the open island.
  static let eventRowHeight: CGFloat = 34
  /// Width of the AirDrop zone, on the right in the files row.
  static let airDropWidth: CGFloat = 84

  /// Physical notch derived from the auxiliary areas; centered pill where there is no notch.
  static func notch(
    screenFrame: CGRect,
    safeTop: CGFloat,
    leftArea: CGRect?,
    rightArea: CGRect?,
    menuBarHeight: CGFloat
  ) -> NotchMetrics {
    if safeTop > 0, let leftArea, let rightArea, rightArea.minX - leftArea.maxX > 1 {
      let rect = CGRect(
        x: leftArea.maxX,
        y: screenFrame.maxY - safeTop,
        width: rightArea.minX - leftArea.maxX,
        height: safeTop
      )
      return NotchMetrics(rect: rect, isPhysical: true)
    }
    let height = menuBarHeight > 0 ? menuBarHeight : fallbackMenuBarHeight
    let rect = CGRect(
      x: (screenFrame.midX - pillWidth / 2).rounded(),
      y: screenFrame.maxY - height,
      width: pillWidth,
      height: height
    )
    return NotchMetrics(rect: rect, isPhysical: false)
  }

  /// Frame of the shape: always anchored to the top edge and centered on the notch.
  static func frame(
    for presentation: IslandPresentation,
    notch: CGRect,
    screenFrame: CGRect,
    extraHeight: CGFloat = 0
  ) -> CGRect {
    let size: CGSize
    switch presentation {
    case .collapsed:
      return notch
    case .lock:
      // Asymmetric: on the right there is only the fillet, the body grows to the left.
      let minX = max(notch.minX - lockEarWidth - shoulderRadius, screenFrame.minX)
      let maxX = min(notch.maxX + shoulderRadius, screenFrame.maxX)
      return CGRect(x: minX, y: notch.minY, width: maxX - minX, height: notch.height)
    case .compact:
      size = CGSize(width: notch.width + (earWidth + shoulderRadius) * 2, height: notch.height)
    case .lyrics, .hud:
      size = CGSize(
        width: max(notch.width + earWidth * 2, lyricsMinWidth) + shoulderRadius * 2,
        height: notch.height + lyricsRowHeight
      )
    case .expanded:
      size = CGSize(
        width: max(notch.width + earWidth * 2, expandedMinWidth) + shoulderRadius * 2,
        height: notch.height + expandedBodyHeight + extraHeight
      )
    }
    let width = min(size.width, screenFrame.width)
    var originX = (notch.midX - width / 2).rounded()
    originX = min(max(originX, screenFrame.minX), screenFrame.maxX - width)
    return CGRect(x: originX, y: notch.maxY - size.height, width: width, height: size.height)
  }

  /// Zone where a dragged file makes the island open: the notch with a little margin.
  static func hotZone(notch: CGRect) -> CGRect {
    notch.insetBy(dx: -36, dy: -12)
  }

  /// `true` if the point (view coordinates, origin at bottom left) is on the AirDrop zone.
  static func isAirDropZone(_ point: CGPoint, in size: CGSize) -> Bool {
    let trailing = size.width - shoulderRadius
    return point.x >= trailing - airDropWidth && point.x <= trailing && point.y >= 0 && point.y <= shelfHeight
  }

  /// Which shape to show. Without a notch there is no opening on mouse hover.
  static func presentation(
    isOpen: Bool, activity: IslandActivity?, hasNotch: Bool, showsLyrics: Bool = false
  ) -> IslandPresentation {
    if isOpen, hasNotch || activity != nil || showsLyrics { return .expanded }
    if let activity {
      if activity.isHUD { return .hud }
      return activity.isLock ? .lock : .compact
    }
    return showsLyrics ? .lyrics : .collapsed
  }

  /// Radius of the open island's bottom corners.
  static let expandedCornerRadius: CGFloat = 36
  /// Margin of the blurred glow around the open island.
  static let haloMargin: CGFloat = 48

  /// Spring damping when opening (bounce of about 8%) and when closing
  /// (about 3%): the lower it is, the more the island overshoots before settling.
  static let openingDamping = 0.62
  static let closingDamping = 0.74

  /// Morph progress: starts at 0, slightly exceeds 1 and settles at 1.
  /// It is an underdamped spring, like the system animations.
  static func springProgress(_ time: Double, damping: Double) -> Double {
    guard time > 0 else { return 0 }
    guard time < 1 else { return 1 }
    let damping = min(max(damping, 0.1), 0.99)
    // The frequency is chosen so that the oscillation is extinguished at time = 1.
    let frequency = 7.6 / damping
    let damped = frequency * (1 - damping * damping).squareRoot()
    let envelope = exp(-damping * frequency * time)
    return 1 - envelope * (cos(damped * time) + damping * frequency / damped * sin(damped * time))
  }

  /// How open the island is (0 = as tall as the notch, 1 = open), from the frame height.
  static func openness(height: CGFloat, notchHeight: CGFloat) -> CGFloat {
    min(max((height - notchHeight) / expandedBodyHeight, 0), 1)
  }

  /// Radius of the concave fillets with the screen's top edge. It is fixed:
  /// it does not change between closed, compact, open and during animations.
  static let shoulderRadius: CGFloat = 10

  /// Radius of the bottom corners: always that of the open island, reduced only
  /// when the shape is too short to contain it.
  static func cornerRadius(height: CGFloat) -> CGFloat {
    min(expandedCornerRadius, max(height / 2, 0))
  }

  /// Glow opacity: zero until the island exceeds the text row, full when open.
  static func haloOpacity(height: CGFloat, notchHeight: CGFloat) -> CGFloat {
    let start = notchHeight + lyricsRowHeight
    return min(max((height - start) / (expandedBodyHeight - lyricsRowHeight), 0), 1)
  }

  /// Frame of the glow window: the island plus a margin on the sides and below, never above the screen.
  static func haloFrame(around frame: CGRect) -> CGRect {
    CGRect(
      x: frame.minX - haloMargin,
      y: frame.minY - haloMargin,
      width: frame.width + haloMargin * 2,
      height: frame.height + haloMargin
    )
  }

  /// Intermediate morph frame, rounded to screen pixels.
  static func interpolate(from: CGRect, to target: CGRect, progress: Double, scale: CGFloat) -> CGRect {
    // A little beyond 1 is allowed: it is the bounce of the opening spring.
    let amount = CGFloat(min(max(progress, 0), 1.2))
    let pixel = max(scale, 1)
    func mix(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
      ((start + (end - start) * amount) * pixel).rounded() / pixel
    }
    let minX = mix(from.minX, target.minX)
    let maxX = mix(from.maxX, target.maxX)
    let minY = mix(from.minY, target.minY)
    let maxY = mix(from.maxY, target.maxY)
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// Two frames equal up to AppKit's rounding to whole points.
  static func isSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1
      && abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
  }

  /// A real shrink, not the half point of the rounding.
  static func isShrinking(from current: CGRect, to target: CGRect) -> Bool {
    target.height < current.height - 1
  }
}
