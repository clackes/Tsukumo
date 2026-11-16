// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Engine

enum RedactStyle: String, CaseIterable, Sendable {
  case pixelate, blur, black

  var title: LocalizedStringKey {
    switch self {
    case .pixelate: "Pixelated"
    case .blur: "Blurred"
    case .black: "Black"
    }
  }
}

/// Area to obscure, in normalised coordinates (0–1, origin at top left).
struct RedactRegion: Identifiable, Equatable, Sendable {
  var id = UUID()
  var rect: CGRect
  var style: RedactStyle
}

enum RedactError: LocalizedError {
  case renderFailed

  var errorDescription: String? { String(localized: "Can't redact the image") }
}

/// Redaction that really destroys the pixels: the effect is applied to the image
/// data and the image is re-encoded from scratch, without metadata or thumbnails.
enum RedactEngine {
  /// Area in whole pixels (origin at top left), kept inside the image; `nil` if empty.
  static func pixelRect(_ region: RedactRegion, width: Int, height: Int) -> CGRect? {
    let minX = max(0, floor(region.rect.minX * CGFloat(width)))
    let minY = max(0, floor(region.rect.minY * CGFloat(height)))
    let maxX = min(CGFloat(width), ceil(region.rect.maxX * CGFloat(width)))
    let maxY = min(CGFloat(height), ceil(region.rect.maxY * CGFloat(height)))
    guard maxX - minX >= 1, maxY - minY >= 1 else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// Side of the pixelation blocks: large relative to the area (at least a third of the
  /// short side), so even small text stays unreadable. Proportional
  /// to the image, so the preview and the output look alike.
  static func blockSize(for rect: CGRect, imageSize: CGSize) -> CGFloat {
    let floorSize = max(4, max(imageSize.width, imageSize.height) / 160)
    let block = max(floorSize, min(rect.width, rect.height) / 3, max(rect.width, rect.height) / 16)
    return min(block, max(rect.width, rect.height))
  }

  /// Blur radius: strong relative to the area.
  static func blurRadius(for rect: CGRect, imageSize: CGSize) -> CGFloat {
    let floorSize = max(6, max(imageSize.width, imageSize.height) / 100)
    return max(floorSize, min(rect.width, rect.height) * 0.6)
  }

  static func apply(_ regions: [RedactRegion], to image: CGImage) throws -> CGImage {
    guard let ctx = ToolBitmap.context(width: image.width, height: image.height, like: image) else {
      throw RedactError.renderFailed
    }
    let width = image.width
    let height = image.height
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let space = ctx.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let environment = EffectEnvironment(
      context: CIContext(options: [.workingColorSpace: space]), space: space,
      imageSize: CGSize(width: width, height: height))

    for region in regions {
      guard let rect = pixelRect(region, width: width, height: height) else { continue }
      // The CoreGraphics context has its origin at the bottom.
      let target = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
      ctx.saveGState()
      ctx.setBlendMode(.copy)
      ctx.clip(to: target)
      switch region.style {
      case .black:
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(target)
      case .pixelate, .blur:
        guard let source = image.cropping(to: rect) else { throw RedactError.renderFailed }
        let processed = try effect(region.style, on: source, environment: environment)
        ctx.draw(processed, in: target)
      }
      ctx.restoreGState()
    }
    guard let result = ctx.makeImage() else { throw RedactError.renderFailed }
    return result
  }

  private struct EffectEnvironment {
    let context: CIContext
    let space: CGColorSpace
    let imageSize: CGSize
  }

  private static func effect(_ style: RedactStyle, on source: CGImage, environment: EffectEnvironment) throws
    -> CGImage
  {
    let size = CGSize(width: source.width, height: source.height)
    let imageSize = environment.imageSize
    let context = environment.context
    let space = environment.space
    let input = CIImage(cgImage: source)
    let extent = input.extent
    // Edges are extended with the area's own pixels: no data from outside or transparent fades.
    let clamped = input.clampedToExtent()
    let output: CIImage?
    switch style {
    case .pixelate:
      let filter = CIFilter.pixellate()
      filter.inputImage = clamped
      filter.center = CGPoint(x: extent.minX, y: extent.minY)
      filter.scale = Float(blockSize(for: CGRect(origin: .zero, size: size), imageSize: imageSize))
      output = filter.outputImage
    case .blur:
      let filter = CIFilter.gaussianBlur()
      filter.inputImage = clamped
      filter.radius = Float(blurRadius(for: CGRect(origin: .zero, size: size), imageSize: imageSize))
      output = filter.outputImage
    case .black:
      output = nil
    }
    guard let output,
      let rendered = context.createCGImage(output.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: space)
    else { throw RedactError.renderFailed }
    return rendered
  }
}

// MARK: - View

struct RedactToolView: View {
  let context: ToolContext

  var body: some View {
    PreviewHost(url: context.files.first) { preview in
      RedactEditor(context: context, preview: preview)
    }
  }
}

private struct RedactEditor: View {
  let context: ToolContext
  let preview: PreviewImage

  private struct DragRecord {
    var movingOriginal: RedactRegion?
    var start: CGPoint
  }

  @State private var history = EditHistory<[RedactRegion]>([])
  @State private var selection: UUID?
  @State private var draft: CGRect?
  @State private var moving: RedactRegion?
  @State private var record: DragRecord?
  @State private var defaultStyle: RedactStyle = .pixelate
  @State private var effectImage: CGImage?

  var body: some View {
    VStack(spacing: 12) {
      ImageCanvas(image: effectImage ?? preview.image, imageSize: preview.pixelSize) { fit in
        canvas(fit)
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      controls
      zoneList
      ToolFooter(context: context, canApply: !history.current.isEmpty, apply: applyRedaction)
    }
    .task(id: history.current) { await refreshEffect() }
  }

  // MARK: Effect preview

  private func refreshEffect() async {
    let regions = history.current
    guard !regions.isEmpty else {
      effectImage = nil
      return
    }
    let image = preview.image
    let result = await Task.detached(priority: .userInitiated) { try? RedactEngine.apply(regions, to: image) }.value
    if !Task.isCancelled { effectImage = result }
  }

  private var displayedRegions: [RedactRegion] {
    guard let moving else { return history.current }
    return history.current.map { $0.id == moving.id ? moving : $0 }
  }

  // MARK: Canvas

  private func canvas(_ fit: ImageFit) -> some View {
    Canvas { gc, _ in
      for region in displayedRegions {
        let box = fit.viewRect(region.rect)
        let isSelected = region.id == selection
        gc.stroke(
          Path(box), with: .color(isSelected ? Color.accentColor : .white.opacity(0.9)),
          style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [4, 3]))
      }
      if let draft {
        let box = fit.viewRect(draft)
        gc.fill(Path(box), with: .color(.accentColor.opacity(0.18)))
        gc.stroke(Path(box), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in dragChanged(value, fit: fit) }
        .onEnded { value in dragEnded(value, fit: fit) }
    )
  }

  private func dragChanged(_ value: DragGesture.Value, fit: ImageFit) {
    let start = fit.normalized(value.startLocation)
    let current = fit.normalized(value.location)
    if record == nil {
      let inSelection = history.current.first { $0.id == selection && $0.rect.contains(start) }
      record = DragRecord(movingOriginal: inSelection, start: start)
    }
    guard let record else { return }
    if var original = record.movingOriginal {
      let delta = CGPoint(x: current.x - record.start.x, y: current.y - record.start.y)
      original.rect = CGRect(
        x: clamp(original.rect.minX + delta.x, 0, 1 - original.rect.width),
        y: clamp(original.rect.minY + delta.y, 0, 1 - original.rect.height),
        width: original.rect.width, height: original.rect.height)
      moving = original
    } else {
      draft = rectBetween(record.start, current)
    }
  }

  private func dragEnded(_ value: DragGesture.Value, fit: ImageFit) {
    defer {
      record = nil
      draft = nil
      moving = nil
    }
    let travel = hypot(value.translation.width, value.translation.height)
    if travel < 4 {
      // A tap selects the area under the finger (or clears the selection).
      let point = fit.normalized(value.startLocation)
      selection = history.current.last { $0.rect.contains(point) }?.id
      return
    }
    if let moving {
      history.commit(history.current.map { $0.id == moving.id ? moving : $0 })
    } else if let draft {
      let box = fit.viewRect(draft)
      guard box.width >= 6, box.height >= 6 else { return }
      let region = RedactRegion(rect: draft, style: defaultStyle)
      history.commit(history.current + [region])
      selection = region.id
    }
  }

  // MARK: Controls

  private var controls: some View {
    HStack(spacing: 8) {
      Picker("Style", selection: styleBinding) {
        ForEach(RedactStyle.allCases, id: \.self) { style in
          Text(style.title).tag(style)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Button {
        history.undo()
        selection = nil
      } label: {
        Label("Cancel", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly)
      }
      .disabled(!history.canUndo)
      .keyboardShortcut("z", modifiers: .command)
      .help(Text("Cancel"))
      Button {
        history.redo()
        selection = nil
      } label: {
        Label("Redo", systemImage: "arrow.uturn.forward").labelStyle(.iconOnly)
      }
      .disabled(!history.canRedo)
      .keyboardShortcut("z", modifiers: [.command, .shift])
      .help(Text("Redo"))
      Button(role: .destructive) {
        deleteSelected()
      } label: {
        Label("Delete region", systemImage: "trash").labelStyle(.iconOnly)
      }
      .disabled(selection == nil)
      .help(Text("Delete region"))
    }
    .buttonStyle(.glass)
    .padding(.horizontal, 16)
  }

  /// The style shown is that of the selected area; if there is none, that of new areas.
  private var styleBinding: Binding<RedactStyle> {
    Binding(
      get: { history.current.first { $0.id == selection }?.style ?? defaultStyle },
      set: { newStyle in
        defaultStyle = newStyle
        guard let selection else { return }
        history.commit(
          history.current.map { region in
            guard region.id == selection else { return region }
            var copy = region
            copy.style = newStyle
            return copy
          })
      })
  }

  private var zoneList: some View {
    Group {
      if history.current.isEmpty {
        Text("Drag on the image to choose the areas to redact")
          .font(.callout).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      } else {
        ScrollView {
          VStack(spacing: 4) {
            ForEach(Array(history.current.enumerated()), id: \.element.id) { index, region in
              HStack {
                Text("Region \(index + 1)")
                Text(region.style.title).foregroundStyle(.secondary)
                Spacer()
                Button {
                  selection = region.id
                  deleteSelected()
                } label: {
                  Label("Delete region", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(
                region.id == selection ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
              )
              .contentShape(Rectangle())
              .onTapGesture { selection = region.id }
            }
          }
        }
        .frame(maxHeight: 88)
      }
    }
    .padding(.horizontal, 16)
  }

  private func deleteSelected() {
    guard let selection else { return }
    history.commit(history.current.filter { $0.id != selection })
    self.selection = nil
  }

  // MARK: Apply

  private func applyRedaction() {
    guard let url = context.files.first else { return }
    let regions = history.current
    context.apply {
      let image = try ToolImage.load(url)
      let result = try RedactEngine.apply(regions, to: image)
      // The image is new: no metadata from the original (nor its EXIF thumbnail) is copied.
      let saved = try ToolImage.save(result, like: url, suffix: "-redacted")
      return String(localized: "Saved \(saved.lastPathComponent)")
    }
  }
}
