// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Hand-drawn lock, with the proportions of `lock.fill`. On unlock
/// the shackle (the metal part) rises and then rotates to the right around the
/// right leg, like in a real padlock: an SF symbol would just be swapped.
struct IslandLockGlyph: View {
  let isLocked: Bool

  /// How far the shackle rises before turning.
  private static let lift: CGFloat = 3.4

  var body: some View {
    ZStack(alignment: .bottom) {
      LockShackle()
        .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        .frame(width: 7.2, height: 7.5)
        // Half turn around the right leg, which stays inserted in the body:
        // the shackle ends open on the right side. It starts after it has risen.
        .rotation3DEffect(.degrees(isLocked ? 0 : 180), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: 0)
        .animation(
          isLocked ? .easeOut(duration: 0.2) : .spring(response: 0.46, dampingFraction: 0.68).delay(0.12),
          value: isLocked
        )
        .offset(y: -8 - (isLocked ? 0 : Self.lift))
        .animation(.spring(response: 0.24, dampingFraction: 0.55), value: isLocked)
      RoundedRectangle(cornerRadius: 2.8, style: .continuous)
        .fill(.white)
        .frame(width: 12.5, height: 9.5)
    }
    .frame(width: 14, height: 20, alignment: .bottom)
    .offset(y: -1)
    .accessibilityElement()
    .accessibilityLabel(Text(isLocked ? "Screen locked" : "Screen unlocked"))
  }
}

/// Lock shackle: semicircle and two legs. The left one ends just inside
/// the body, so that when open it stays suspended; the right one is long and always stays inserted.
private struct LockShackle: Shape {
  func path(in rect: CGRect) -> Path {
    let radius = rect.width / 2
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY + 1))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addArc(
      center: CGPoint(x: rect.midX, y: rect.minY + radius), radius: radius,
      startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + 5))
    return path
  }
}
