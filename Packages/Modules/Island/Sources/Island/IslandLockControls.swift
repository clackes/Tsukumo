// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Draggable horizontal bar for the volume, in the style of the time bar.
struct LockLevelBar: View {
  let value: Double
  let onChange: (Double) -> Void
  @State private var dragging = false

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      let height: CGFloat = dragging ? LockSeekBar.activeTrackHeight : LockSeekBar.trackHeight
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.25))
        Capsule().fill(.white.opacity(0.9)).frame(width: width * min(max(value, 0), 1))
      }
      .frame(height: height)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in
            dragging = true
            onChange(min(max(drag.location.x / width, 0), 1))
          }
          .onEnded { _ in dragging = false }
      )
    }
    .frame(height: 18)
    .accessibilityElement()
    .accessibilityValue(Text(verbatim: "\(Int((value * 100).rounded()))%"))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: onChange(min(value + 0.1, 1))
      case .decrement: onChange(max(value - 0.1, 0))
      @unknown default: break
      }
    }
  }
}

/// Average color of the artwork, to tint the card. Computed once
/// per image (shrunk to 1×1 pixel) and kept in cache.
@MainActor
enum LockArtworkTint {
  private static var cache: (key: ObjectIdentifier, color: Color)?

  static func color(for image: NSImage?) -> Color {
    guard let image else { return .black.opacity(0.3) }
    let key = ObjectIdentifier(image)
    if let cache, cache.key == key { return cache.color }
    let color = average(of: image).map { Color(nsColor: $0) } ?? .black.opacity(0.3)
    cache = (key, color)
    return color
  }

  static func average(of image: NSImage) -> NSColor? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    // A bit darker than the average: the white text on top must be readable.
    func channel(_ index: Int) -> CGFloat { CGFloat(data[index]) / 255 * 0.7 }
    return NSColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: 1)
  }
}

/// `AudioObjectID` as comparable SwiftUI state.
struct AudioObjectIDBox: Equatable {
  let id: UInt32
}
