// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

// MARK: - Preview image

/// Reduced preview of an image (orientation already applied) and real size in pixels.
struct PreviewImage: @unchecked Sendable {
  let image: CGImage
  let pixelSize: CGSize
}

enum PreviewLoader {
  /// Loads the preview off the main actor.
  static func load(_ url: URL, maxPixel: Int = 1800) async throws -> PreviewImage {
    try await Task.detached(priority: .userInitiated) {
      let image = try ToolImage.load(url, maxPixel: maxPixel)
      return PreviewImage(
        image: image, pixelSize: pixelSize(of: url) ?? CGSize(width: image.width, height: image.height))
    }.value
  }

  /// Size in pixels after EXIF orientation, without decoding the image.
  static func pixelSize(of url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Double,
      let height = props[kCGImagePropertyPixelHeight] as? Double,
      width > 0, height > 0
    else { return nil }
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
  }
}

/// Loads the preview of the first image and then shows the tool's content.
struct PreviewHost<Content: View>: View {
  let url: URL?
  @ViewBuilder let content: (PreviewImage) -> Content

  private enum Phase {
    case loading
    case ready(PreviewImage)
    case failed(String)
  }

  @State private var phase: Phase = .loading

  var body: some View {
    Group {
      switch phase {
      case .loading:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .ready(let preview):
        content(preview)
      case .failed(let message):
        ContentUnavailableView {
          Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
        } description: {
          Text(verbatim: message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: url) { await load() }
  }

  private func load() async {
    guard let url else {
      phase = .failed("")
      return
    }
    do {
      phase = .ready(try await PreviewLoader.load(url))
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}

// MARK: - Fit to the panel and coordinates

/// Where the image falls inside the canvas (fitted with the right proportions) and
/// how to go from view points to normalised coordinates (0–1) and back.
struct ImageFit: Equatable, Sendable {
  let rect: CGRect

  init(container: CGSize, imageSize: CGSize, padding: CGFloat = 0) {
    let availW = max(1, container.width - padding * 2)
    let availH = max(1, container.height - padding * 2)
    guard imageSize.width > 0, imageSize.height > 0 else {
      rect = CGRect(origin: .zero, size: container)
      return
    }
    let scale = min(availW / imageSize.width, availH / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    rect = CGRect(
      x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
      width: size.width, height: size.height)
  }

  /// Normalised point (0–1) → point in the view.
  func viewPoint(_ normalized: CGPoint) -> CGPoint {
    CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
  }

  /// View point → normalised point, kept inside the image if `clamped`.
  func normalized(_ point: CGPoint, clamped: Bool = true) -> CGPoint {
    let nx = (point.x - rect.minX) / max(rect.width, 1)
    let ny = (point.y - rect.minY) / max(rect.height, 1)
    guard clamped else { return CGPoint(x: nx, y: ny) }
    return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
  }

  /// Normalised rectangle → rectangle in the view.
  func viewRect(_ normalized: CGRect) -> CGRect {
    CGRect(
      x: rect.minX + normalized.minX * rect.width, y: rect.minY + normalized.minY * rect.height,
      width: normalized.width * rect.width, height: normalized.height * rect.height)
  }
}

/// Rectangle with any two opposite corners.
func rectBetween(_ first: CGPoint, _ second: CGPoint) -> CGRect {
  CGRect(
    x: min(first.x, second.x), y: min(first.y, second.y),
    width: abs(first.x - second.x), height: abs(first.y - second.y))
}

func clamp<Value: Comparable>(_ value: Value, _ low: Value, _ high: Value) -> Value {
  min(max(value, low), high)
}

/// Tool windows are dragged by the background: under the canvas the
/// drag must stay with the user's gesture.
struct NoWindowDrag: NSViewRepresentable {
  final class Backing: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
  }

  func makeNSView(context: Context) -> Backing { Backing() }
  func updateNSView(_ nsView: Backing, context: Context) {}
}

/// Canvas with the image fitted to the panel; `overlay` draws and collects gestures
/// in the same space (container coordinates) using `ImageFit`.
struct ImageCanvas<Overlay: View>: View {
  let image: CGImage
  let imageSize: CGSize
  @ViewBuilder let overlay: (ImageFit) -> Overlay

  var body: some View {
    GeometryReader { proxy in
      let fit = ImageFit(container: proxy.size, imageSize: imageSize)
      ZStack(alignment: .topLeading) {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.medium)
          .frame(width: fit.rect.width, height: fit.rect.height)
          .offset(x: fit.rect.minX, y: fit.rect.minY)
        overlay(fit)
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .background(NoWindowDrag())
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

// MARK: - Undo/redo history

struct EditHistory<Value: Equatable & Sendable>: Equatable, Sendable {
  private(set) var current: Value
  private var undoStack: [Value] = []
  private var redoStack: [Value] = []

  init(_ initial: Value) { current = initial }

  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }

  /// New undoable state; clears redo.
  mutating func commit(_ value: Value) {
    guard value != current else { return }
    undoStack.append(current)
    redoStack.removeAll()
    current = value
  }

  /// Changes the current state without creating an undo step.
  mutating func replaceCurrent(_ value: Value) { current = value }

  mutating func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(current)
    current = previous
  }

  mutating func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(current)
    current = next
  }
}

// MARK: - Bitmap

enum ToolBitmap {
  /// 8-bit RGBA context with the image's colour space (sRGB if unsuitable) and,
  /// if the original has no transparency, without an alpha channel.
  static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
    guard width > 0, height > 0 else { return nil }
    let hasAlpha: Bool
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
    default: hasAlpha = true
    }
    let info = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
    var spaces: [CGColorSpace] = []
    if let own = image.colorSpace, own.model == .rgb { spaces.append(own) }
    if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { spaces.append(srgb) }
    for space in spaces {
      if let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
      {
        ctx.interpolationQuality = .high
        return ctx
      }
    }
    return nil
  }
}
