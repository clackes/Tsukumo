// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import SwiftUI

// MARK: - Transforms

/// Rotation or mirror applied to the image before cropping.
enum ImageOp: Equatable, Sendable {
  case rotateLeft
  case rotateRight
  case flipHorizontal

  func apply(to image: CGImage) -> CGImage? {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let swaps = self != .flipHorizontal
    guard
      let ctx = ToolBitmap.context(
        width: swaps ? image.height : image.width, height: swaps ? image.width : image.height, like: image)
    else { return nil }
    switch self {
    case .rotateRight:
      ctx.translateBy(x: 0, y: width)
      ctx.rotate(by: -.pi / 2)
    case .rotateLeft:
      ctx.translateBy(x: height, y: 0)
      ctx.rotate(by: .pi / 2)
    case .flipHorizontal:
      ctx.translateBy(x: width, y: 0)
      ctx.scaleBy(x: -1, y: 1)
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
  }

  static func apply(_ ops: [ImageOp], to image: CGImage) -> CGImage {
    ops.reduce(image) { $1.apply(to: $0) ?? $0 }
  }
}

// MARK: - View

struct CropToolView: View {
  let context: ToolContext

  var body: some View {
    PreviewHost(url: context.files.first) { preview in
      CropEditor(context: context, preview: preview)
    }
  }
}

private enum CropDragKind {
  case resize(CropGeometry.Handle, grabOffset: CGSize)
  case move
  case none
}

private struct CropDragState {
  let kind: CropDragKind
  let start: CropGeometry
}

private struct CropEditor: View {
  let context: ToolContext
  let preview: PreviewImage

  @State private var ops: [ImageOp] = []
  @State private var display: CGImage
  @State private var geometry: CropGeometry
  @State private var drag: CropDragState?

  init(context: ToolContext, preview: PreviewImage) {
    self.context = context
    self.preview = preview
    _display = State(initialValue: preview.image)
    _geometry = State(initialValue: CropGeometry(imageSize: preview.pixelSize))
  }

  var body: some View {
    VStack(spacing: 12) {
      ImageCanvas(image: display, imageSize: geometry.imageSize) { fit in
        overlay(fit)
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      controls
      ToolFooter(context: context, canApply: true, apply: applyCrop)
    }
  }

  // MARK: Canvas

  private func overlay(_ fit: ImageFit) -> some View {
    Canvas { gc, _ in
      let box = fit.viewRect(geometry.normalizedRect)
      var dim = Path(fit.rect)
      dim.addRect(box)
      gc.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
      gc.stroke(Path(box), with: .color(.white), lineWidth: 1.5)
      var grid = Path()
      for step in [1.0, 2.0] {
        let gridX = box.minX + box.width * step / 3
        let gridY = box.minY + box.height * step / 3
        grid.move(to: CGPoint(x: gridX, y: box.minY))
        grid.addLine(to: CGPoint(x: gridX, y: box.maxY))
        grid.move(to: CGPoint(x: box.minX, y: gridY))
        grid.addLine(to: CGPoint(x: box.maxX, y: gridY))
      }
      gc.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
      for handle in CropGeometry.Handle.allCases {
        let spot = CropGeometry.position(of: handle, in: box)
        let side: CGFloat = handle.isCorner ? 11 : 8
        let knob = Path(
          roundedRect: CGRect(x: spot.x - side / 2, y: spot.y - side / 2, width: side, height: side),
          cornerRadius: 3)
        gc.fill(knob, with: .color(.white))
        gc.stroke(knob, with: .color(.black.opacity(0.4)), lineWidth: 0.5)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in dragChanged(value, fit: fit) }
        .onEnded { _ in drag = nil }
    )
  }

  private func pixelPoint(_ viewPoint: CGPoint, fit: ImageFit) -> CGPoint {
    let norm = fit.normalized(viewPoint, clamped: false)
    return CGPoint(x: norm.x * geometry.imageSize.width, y: norm.y * geometry.imageSize.height)
  }

  private func dragChanged(_ value: DragGesture.Value, fit: ImageFit) {
    if drag == nil {
      let box = fit.viewRect(geometry.normalizedRect)
      if let handle = CropGeometry.handle(at: value.startLocation, in: box, tolerance: 14) {
        let spot = geometry.position(of: handle)
        let start = pixelPoint(value.startLocation, fit: fit)
        drag = CropDragState(
          kind: .resize(handle, grabOffset: CGSize(width: start.x - spot.x, height: start.y - spot.y)),
          start: geometry)
      } else if box.contains(value.startLocation) {
        drag = CropDragState(kind: .move, start: geometry)
      } else {
        drag = CropDragState(kind: .none, start: geometry)
      }
    }
    guard let drag else { return }
    switch drag.kind {
    case .resize(let handle, let offset):
      let point = pixelPoint(value.location, fit: fit)
      let target = CGPoint(x: point.x - offset.width, y: point.y - offset.height)
      geometry.rect = drag.start.resizing(handle, to: target)
    case .move:
      let scale = geometry.imageSize.width / max(fit.rect.width, 1)
      geometry.rect = drag.start.moved(
        by: CGSize(width: value.translation.width * scale, height: value.translation.height * scale))
    case .none:
      break
    }
  }

  // MARK: Controls

  private var controls: some View {
    VStack(spacing: 10) {
      Picker("Aspect Ratio", selection: aspectBinding) {
        Text("Free").tag(CropGeometry.Aspect.free)
        Text("Original").tag(CropGeometry.Aspect.original)
        Text(verbatim: "1:1").tag(CropGeometry.Aspect.square)
        Text(verbatim: "4:3").tag(CropGeometry.Aspect.fourThree)
        Text(verbatim: "3:2").tag(CropGeometry.Aspect.threeTwo)
        Text(verbatim: "16:9").tag(CropGeometry.Aspect.sixteenNine)
        Text(verbatim: "9:16").tag(CropGeometry.Aspect.nineSixteen)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      HStack(spacing: 8) {
        transformButton("Rotate Left", symbol: "rotate.left") { transform(.rotateLeft) }
        transformButton("Rotate Right", symbol: "rotate.right") { transform(.rotateRight) }
        transformButton("Flip", symbol: "flip.horizontal") { transform(.flipHorizontal) }
        Spacer()
        if context.files.count > 1 {
          Text("The same crop on \(context.files.count) images")
            .font(.caption).foregroundStyle(.secondary)
        }
        let size = geometry.pixelSize
        Text(verbatim: "\(size.width) × \(size.height) px")
          .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
  }

  private var aspectBinding: Binding<CropGeometry.Aspect> {
    Binding(get: { geometry.aspect }, set: { geometry.setAspect($0) })
  }

  private func transformButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(width: 22, height: 18)
    }
    .buttonStyle(.glass)
    .help(title)
  }

  private func transform(_ op: ImageOp) {
    guard let next = op.apply(to: display) else { return }
    ops.append(op)
    display = next
    switch op {
    case .rotateLeft: geometry.rotate(clockwise: false)
    case .rotateRight: geometry.rotate(clockwise: true)
    case .flipHorizontal: geometry.flipHorizontally()
    }
  }

  // MARK: Apply

  private func applyCrop() {
    let files = context.files
    let ops = ops
    let relative = geometry.normalizedRect
    context.apply {
      var saved: [URL] = []
      for url in files {
        let image = ImageOp.apply(ops, to: try ToolImage.load(url))
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let target = CGRect(
          x: relative.minX * width, y: relative.minY * height, width: relative.width * width,
          height: relative.height * height
        )
        .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cropped = image.cropping(to: target), !target.isNull, target.width >= 1, target.height >= 1 else {
          throw ToolImageError.unwritable(url.lastPathComponent)
        }
        saved.append(try ToolImage.save(cropped, like: url, suffix: "-cropped"))
      }
      if let first = saved.first, saved.count == 1 {
        return String(localized: "Saved \(first.lastPathComponent)")
      }
      return String(localized: "\(saved.count) images cropped")
    }
  }
}
