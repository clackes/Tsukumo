// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Player and, if on, text to its right.
struct LockMediaContentView: View {
  let model: IslandModel
  let actions: IslandActions
  let size: CGSize
  let lyrics: Bool

  var body: some View {
    HStack(alignment: .top, spacing: LockMediaController.lyricsGap) {
      LockMediaCardView(model: model, actions: actions, size: size)
      if lyrics {
        LockLyricsView(model: model, size: LockMediaController.lyricsSize(for: size))
      }
    }
  }
}

/// Synchronized text as on iPhone: the current line is full and centered,
/// the others dimmed. It redraws only when the line changes, and the view
/// exists only while the screen is locked.
struct LockLyricsView: View {
  let model: IslandModel
  let size: CGSize
  /// Measured height of each line (a long line wraps).
  @State private var heights: [Int: CGFloat] = [:]

  private static let spacing: CGFloat = 16
  private static let horizontalPadding: CGFloat = 26
  private static let fallbackHeight: CGFloat = 30

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
    Group {
      if model.lyricLines.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "quote.bubble").font(.system(size: 30))
          Text("Lyrics unavailable").font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        lines
      }
    }
    .frame(width: size.width, height: size.height)
    .background(LockArtworkTint.color(for: model.artwork).opacity(0.55), in: shape)
    .background(Color.black.opacity(0.12), in: shape)
    .glassEffect(.clear, in: shape)
    .clipShape(shape)
    .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("Song lyrics"))
  }

  private var lines: some View {
    let current = model.lyricIndex
    return VStack(alignment: .leading, spacing: Self.spacing) {
      ForEach(Array(model.lyricLines.enumerated()), id: \.offset) { index, line in
        Text(verbatim: line.isEmpty ? "♪" : line)
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(.white.opacity(index == current ? 1 : 0.32))
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGFloat.self, of: \.size.height) { heights[index] = $0 }
      }
    }
    .padding(.horizontal, Self.horizontalPadding)
    .offset(y: size.height / 2 - Self.centerOffset(of: current ?? 0, heights: heights))
    .frame(width: size.width, height: size.height, alignment: .top)
    // The lines fade toward the top and bottom edges of the card.
    .mask(
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0), .init(color: .black, location: 0.18),
          .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    )
    .animation(.smooth(duration: 0.6), value: current)
  }

  /// Distance from the top of the list to the center of line `index`.
  static func centerOffset(of index: Int, heights: [Int: CGFloat]) -> CGFloat {
    let above = (0..<max(index, 0)).reduce(CGFloat.zero) { sum, line in
      sum + (heights[line] ?? fallbackHeight) + spacing
    }
    return above + (heights[index] ?? fallbackHeight) / 2
  }
}
