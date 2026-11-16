// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics

// MARK: - Crop geometry

/// Crop rectangle in image pixels (origin at top left), with
/// constraints on aspect ratio, edges and minimum size. Pure logic, no UI.
struct CropGeometry: Equatable, Sendable {
  enum Aspect: CaseIterable, Hashable, Sendable {
    case free, original, square, fourThree, threeTwo, sixteenNine, nineSixteen

    /// Imposed width / height, `nil` if free.
    func ratio(for imageSize: CGSize) -> CGFloat? {
      switch self {
      case .free: nil
      case .original: imageSize.height > 0 ? imageSize.width / imageSize.height : nil
      case .square: 1
      case .fourThree: 4.0 / 3.0
      case .threeTwo: 3.0 / 2.0
      case .sixteenNine: 16.0 / 9.0
      case .nineSixteen: 9.0 / 16.0
      }
    }
  }

  enum Handle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isCorner: Bool {
      switch self {
      case .topLeft, .topRight, .bottomRight, .bottomLeft: true
      default: false
      }
    }
  }

  static let minimumSide: CGFloat = 16

  var imageSize: CGSize
  var rect: CGRect
  var aspect: Aspect

  /// Starts with the crop covering the whole image.
  init(imageSize: CGSize, aspect: Aspect = .free) {
    self.imageSize = imageSize
    self.rect = CGRect(origin: .zero, size: imageSize)
    self.aspect = .free
    setAspect(aspect)
  }

  init(imageSize: CGSize, rect: CGRect, aspect: Aspect = .free) {
    self.imageSize = imageSize
    self.rect = rect
    self.aspect = aspect
  }

  var ratio: CGFloat? { aspect.ratio(for: imageSize) }

  /// Rectangle in normalised coordinates (0–1).
  var normalizedRect: CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    return CGRect(
      x: rect.minX / imageSize.width, y: rect.minY / imageSize.height,
      width: rect.width / imageSize.width, height: rect.height / imageSize.height)
  }

  var pixelSize: (width: Int, height: Int) { (Int(rect.width.rounded()), Int(rect.height.rounded())) }

  // MARK: Aspect ratio

  /// Changes aspect ratio keeping the centre and (as far as possible) the crop area.
  mutating func setAspect(_ newAspect: Aspect) {
    aspect = newAspect
    refit()
  }

  private mutating func refit() {
    guard let ratio, ratio > 0 else { return }
    let area = max(rect.width * rect.height, 1)
    var width = (area * ratio).squareRoot()
    var height = width / ratio
    let scale = min(1, imageSize.width / width, imageSize.height / height)
    width *= scale
    height *= scale
    let minWidth = Self.minimumSide * max(1, ratio)
    if width < minWidth {
      width = min(minWidth, imageSize.width)
      height = width / ratio
    }
    if height > imageSize.height {
      height = imageSize.height
      width = height * ratio
    }
    rect = CGRect(
      x: clamp(rect.midX - width / 2, 0, imageSize.width - width),
      y: clamp(rect.midY - height / 2, 0, imageSize.height - height),
      width: width, height: height)
  }

  // MARK: Move and resize

  /// Moves the crop while staying inside the image.
  func moved(by delta: CGSize) -> CGRect {
    CGRect(
      x: clamp(rect.minX + delta.width, 0, imageSize.width - rect.width),
      y: clamp(rect.minY + delta.height, 0, imageSize.height - rect.height),
      width: rect.width, height: rect.height)
  }

  /// Position of a handle on the rectangle.
  func position(of handle: Handle) -> CGPoint {
    Self.position(of: handle, in: rect)
  }

  static func position(of handle: Handle, in rect: CGRect) -> CGPoint {
    switch handle {
    case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
    case .top: CGPoint(x: rect.midX, y: rect.minY)
    case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
    case .right: CGPoint(x: rect.maxX, y: rect.midY)
    case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
    case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
    case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
    case .left: CGPoint(x: rect.minX, y: rect.midY)
    }
  }

  /// New rectangle by dragging `handle` to `target` (in pixels). The opposite side or
  /// corner stays fixed; aspect ratio, edges and minimum size are respected.
  func resizing(_ handle: Handle, to target: CGPoint) -> CGRect {
    let point = CGPoint(x: clamp(target.x, 0, imageSize.width), y: clamp(target.y, 0, imageSize.height))
    if handle.isCorner { return resizingCorner(handle, to: point) }
    return resizingEdge(handle, to: point)
  }

  private var minimumSides: CGSize {
    guard let ratio else { return CGSize(width: Self.minimumSide, height: Self.minimumSide) }
    let width = Self.minimumSide * max(1, ratio)
    return CGSize(width: width, height: width / ratio)
  }

  private func resizingCorner(_ handle: Handle, to point: CGPoint) -> CGRect {
    let signX: CGFloat = (handle == .topLeft || handle == .bottomLeft) ? -1 : 1
    let signY: CGFloat = (handle == .topLeft || handle == .topRight) ? -1 : 1
    let anchor = CGPoint(x: signX > 0 ? rect.minX : rect.maxX, y: signY > 0 ? rect.minY : rect.maxY)
    let availWidth = signX > 0 ? imageSize.width - anchor.x : anchor.x
    let availHeight = signY > 0 ? imageSize.height - anchor.y : anchor.y
    let mins = minimumSides
    var width = max((point.x - anchor.x) * signX, mins.width)
    var height = max((point.y - anchor.y) * signY, mins.height)
    if let ratio {
      if width / ratio >= height {
        height = width / ratio
      } else {
        width = height * ratio
      }
      let shrink = min(1, availWidth / width, availHeight / height)
      width *= shrink
      height *= shrink
    } else {
      width = min(width, availWidth)
      height = min(height, availHeight)
    }
    return CGRect(
      x: signX > 0 ? anchor.x : anchor.x - width, y: signY > 0 ? anchor.y : anchor.y - height,
      width: width, height: height)
  }

  private func resizingEdge(_ handle: Handle, to point: CGPoint) -> CGRect {
    let mins = minimumSides
    let horizontal = handle == .left || handle == .right
    // Requested length on the dragged axis, opposite side fixed.
    let anchor: CGFloat
    var length: CGFloat
    let available: CGFloat
    switch handle {
    case .right:
      anchor = rect.minX
      length = point.x - anchor
      available = imageSize.width - anchor
    case .left:
      anchor = rect.maxX
      length = anchor - point.x
      available = anchor
    case .bottom:
      anchor = rect.minY
      length = point.y - anchor
      available = imageSize.height - anchor
    default:
      anchor = rect.maxY
      length = anchor - point.y
      available = anchor
    }
    length = max(length, horizontal ? mins.width : mins.height)
    var crossLength = horizontal ? rect.height : rect.width
    let crossCenter = horizontal ? rect.midY : rect.midX
    let crossLimit = horizontal ? imageSize.height : imageSize.width
    length = min(length, available)
    if let ratio {
      // The other axis follows the aspect ratio, staying centred on the current crop.
      let maxCross = 2 * min(crossCenter, crossLimit - crossCenter)
      var cross = horizontal ? length / ratio : length * ratio
      if cross > maxCross {
        cross = maxCross
        length = horizontal ? cross * ratio : cross / ratio
      }
      crossLength = cross
    }
    let crossOrigin = ratio == nil ? (horizontal ? rect.minY : rect.minX) : crossCenter - crossLength / 2
    switch handle {
    case .right: return CGRect(x: anchor, y: crossOrigin, width: length, height: crossLength)
    case .left: return CGRect(x: anchor - length, y: crossOrigin, width: length, height: crossLength)
    case .bottom: return CGRect(x: crossOrigin, y: anchor, width: crossLength, height: length)
    default: return CGRect(x: crossOrigin, y: anchor - length, width: crossLength, height: length)
    }
  }

  // MARK: Rotation and mirror

  /// Rotates the image by 90° and the crop with it.
  mutating func rotate(clockwise: Bool) {
    let width = imageSize.width
    let height = imageSize.height
    if clockwise {
      rect = CGRect(x: height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
    } else {
      rect = CGRect(x: rect.minY, y: width - rect.maxX, width: rect.height, height: rect.width)
    }
    imageSize = CGSize(width: height, height: width)
    refit()
  }

  mutating func flipHorizontally() {
    rect = CGRect(x: imageSize.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
  }

  // MARK: Hit test (in view points)

  /// Handle under `point`; corners take precedence over sides.
  static func handle(at point: CGPoint, in viewRect: CGRect, tolerance: CGFloat) -> Handle? {
    for handle in Handle.allCases where handle.isCorner {
      let spot = position(of: handle, in: viewRect)
      if hypot(point.x - spot.x, point.y - spot.y) <= tolerance { return handle }
    }
    let nearX = point.x >= viewRect.minX && point.x <= viewRect.maxX
    let nearY = point.y >= viewRect.minY && point.y <= viewRect.maxY
    if nearX, abs(point.y - viewRect.minY) <= tolerance { return .top }
    if nearX, abs(point.y - viewRect.maxY) <= tolerance { return .bottom }
    if nearY, abs(point.x - viewRect.minX) <= tolerance { return .left }
    if nearY, abs(point.x - viewRect.maxX) <= tolerance { return .right }
    return nil
  }
}
