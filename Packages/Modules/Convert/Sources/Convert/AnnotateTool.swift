// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import SwiftUI

// MARK: - View

enum AnnotationTool: Hashable, CaseIterable {
  case select, arrow, rectangle, oval, line, freehand, text

  var kind: Annotation.Kind? {
    switch self {
    case .select: nil
    case .arrow: .arrow
    case .rectangle: .rectangle
    case .oval: .oval
    case .line: .line
    case .freehand: .freehand
    case .text: .text
    }
  }

  var symbol: String {
    switch self {
    case .select: "cursorarrow"
    case .arrow: "arrow.up.right"
    case .rectangle: "rectangle"
    case .oval: "circle"
    case .line: "line.diagonal"
    case .freehand: "scribble"
    case .text: "textformat"
    }
  }

  var title: LocalizedStringKey {
    switch self {
    case .select: "Select"
    case .arrow: "Arrow"
    case .rectangle: "Rectangle"
    case .oval: "Oval"
    case .line: "Line"
    case .freehand: "Freehand"
    case .text: "Text"
    }
  }
}

struct AnnotateToolView: View {
  let context: ToolContext

  var body: some View {
    PreviewHost(url: context.files.first) { preview in
      AnnotateEditor(context: context, preview: preview)
    }
  }
}

private struct AnnotateEditor: View {
  let context: ToolContext
  let preview: PreviewImage

  private struct DragRecord {
    var original: Annotation?
    var startNormalized: CGPoint
    var placedText = false
  }

  @State private var history = EditHistory<[Annotation]>([])
  @State private var tool: AnnotationTool = .arrow
  @State private var selection: UUID?
  @State private var draft: Annotation?
  @State private var gesture: DragRecord?
  @State private var color = AnnotationColor.presets[0]
  @State private var thickness = 4.0
  @FocusState private var textFocused: Bool

  private static let thicknessUnit = 0.0015

  var body: some View {
    VStack(spacing: 12) {
      ImageCanvas(image: preview.image, imageSize: preview.pixelSize) { fit in
        canvas(fit)
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      controls
      ToolFooter(context: context, canApply: !history.current.isEmpty, apply: applyAnnotations)
    }
  }

  // MARK: Displayed elements

  private var displayed: [Annotation] {
    var items = history.current
    if let draft {
      if let index = items.firstIndex(where: { $0.id == draft.id }) {
        items[index] = draft
      } else {
        items.append(draft)
      }
    }
    return items
  }

  private var selected: Annotation? {
    guard let selection else { return nil }
    return displayed.first { $0.id == selection }
  }

  // MARK: Canvas

  private func canvas(_ fit: ImageFit) -> some View {
    let size = fit.rect.size
    return Canvas { gc, canvasSize in
      for item in displayed { draw(item, in: &gc, size: canvasSize) }
      if let selected {
        let box = AnnotationGeometry.bounds(of: selected, in: canvasSize).insetBy(dx: -4, dy: -4)
        gc.stroke(
          Path(roundedRect: box, cornerRadius: 4), with: .color(.accentColor),
          style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
      }
    }
    .frame(width: size.width, height: size.height)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in dragChanged(value, size: size) }
        .onEnded { value in dragEnded(value, size: size) }
    )
    .offset(x: fit.rect.minX, y: fit.rect.minY)
  }

  private func draw(_ item: Annotation, in gc: inout GraphicsContext, size: CGSize) {
    let tint = item.color.swiftUI
    if item.kind == .text {
      guard !item.text.isEmpty else { return }
      let font = Font.system(size: AnnotationGeometry.fontSize(item, in: size), weight: .bold)
      let origin = AnnotationGeometry.absolute(item.points.first ?? .zero, in: size)
      gc.draw(Text(verbatim: item.text).font(font).foregroundColor(tint), at: origin, anchor: .topLeading)
      return
    }
    guard let path = AnnotationGeometry.path(for: item, in: size) else { return }
    gc.stroke(
      Path(path), with: .color(tint),
      style: StrokeStyle(lineWidth: AnnotationGeometry.strokeWidth(item, in: size), lineCap: .round, lineJoin: .round))
  }

  // MARK: Gestures

  private func normalize(_ point: CGPoint, size: CGSize) -> CGPoint {
    CGPoint(x: clamp(point.x / max(size.width, 1), 0, 1), y: clamp(point.y / max(size.height, 1), 0, 1))
  }

  private func topmost(at point: CGPoint, size: CGSize) -> Annotation? {
    history.current.last { AnnotationGeometry.hit($0, at: point, in: size, tolerance: 8) }
  }

  private func dragChanged(_ value: DragGesture.Value, size: CGSize) {
    let current = normalize(value.location, size: size)
    if gesture == nil {
      begin(at: value.startLocation, size: size)
    }
    guard let state = gesture, !state.placedText else { return }
    if let original = state.original, tool == .select || tool == .text {
      let delta = CGPoint(x: current.x - state.startNormalized.x, y: current.y - state.startNormalized.y)
      draft = AnnotationGeometry.moved(original, by: delta)
      return
    }
    guard var item = draft, tool.kind != nil else { return }
    switch item.kind {
    case .freehand:
      if let last = item.points.last,
        hypot((current.x - last.x) * size.width, (current.y - last.y) * size.height) >= 1.5
      {
        item.points.append(current)
      }
    default:
      item.points = [item.points.first ?? current, current]
    }
    draft = item
  }

  private func begin(at start: CGPoint, size: CGSize) {
    let startNormalized = normalize(start, size: size)
    var state = DragRecord(original: nil, startNormalized: startNormalized)
    switch tool {
    case .select:
      let hit = topmost(at: start, size: size)
      selection = hit?.id
      state.original = hit
    case .text:
      if let hit = topmost(at: start, size: size), hit.kind == .text {
        selection = hit.id
        state.original = hit
      } else {
        placeText(at: startNormalized)
        state.placedText = true
      }
    default:
      guard let kind = tool.kind else { break }
      selection = nil
      draft = Annotation(
        kind: kind, points: [startNormalized, startNormalized], color: color, lineWidth: thickness * Self.thicknessUnit)
    }
    gesture = state
  }

  private func dragEnded(_ value: DragGesture.Value, size: CGSize) {
    defer {
      gesture = nil
      draft = nil
    }
    guard let state = gesture, !state.placedText, let item = draft else { return }
    if state.original != nil {
      history.commit(history.current.map { $0.id == item.id ? item : $0 })
      return
    }
    let first = item.points.first ?? .zero
    let last = item.points.last ?? first
    let spanX = (last.x - first.x) * size.width
    let spanY = (last.y - first.y) * size.height
    guard item.kind == .freehand ? item.points.count > 1 : hypot(spanX, spanY) >= 4 else { return }
    history.commit(history.current + [item])
    selection = item.id
  }

  private func placeText(at point: CGPoint) {
    let item = Annotation(
      kind: .text, points: [point], color: color, lineWidth: thickness * Self.thicknessUnit,
      text: String(localized: "Text"))
    history.commit(history.current + [item])
    selection = item.id
    textFocused = true
  }

  // MARK: Controls

  private var controls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 8) {
        Picker("Tool", selection: $tool) {
          ForEach(AnnotationTool.allCases, id: \.self) { item in
            Label(item.title, systemImage: item.symbol).labelStyle(.iconOnly).tag(item)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: tool) { _, _ in if tool != .select && tool != .text { selection = nil } }
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
        Button(role: .destructive, action: deleteSelected) {
          Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
        }
        .disabled(selection == nil)
        .help(Text("Delete selected"))
      }
      .buttonStyle(.glass)
      HStack(spacing: 10) {
        ForEach(Array(AnnotationColor.presets.enumerated()), id: \.offset) { _, preset in
          Button {
            setColor(preset)
          } label: {
            Circle().fill(preset.swiftUI)
              .overlay(
                Circle().strokeBorder(
                  .primary.opacity(preset == color ? 0.9 : 0.25), lineWidth: preset == color ? 2 : 1)
              )
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.plain)
        }
        ColorPicker("Color", selection: colorBinding, supportsOpacity: false).labelsHidden()
        Image(systemName: "lineweight").foregroundStyle(.secondary)
        Slider(value: thicknessBinding, in: 1...12).frame(maxWidth: 140)
      }
      if tool == .text || selected?.kind == .text {
        TextField("Text", text: textBinding)
          .textFieldStyle(.roundedBorder)
          .focused($textFocused)
          .disabled(selected?.kind != .text)
      }
    }
    .padding(.horizontal, 16)
  }

  private var colorBinding: Binding<Color> {
    Binding(get: { color.swiftUI }, set: { setColor(AnnotationColor($0)) })
  }

  private var thicknessBinding: Binding<Double> {
    Binding(
      get: { thickness },
      set: { newValue in
        thickness = newValue
        updateSelected { $0.lineWidth = newValue * Self.thicknessUnit }
      })
  }

  private var textBinding: Binding<String> {
    Binding(
      get: { selected?.kind == .text ? (selected?.text ?? "") : "" },
      set: { newValue in updateSelected { $0.text = newValue } })
  }

  private func setColor(_ new: AnnotationColor) {
    color = new
    updateSelected { $0.color = new }
  }

  /// Changes the selected element without adding an undo step.
  private func updateSelected(_ change: (inout Annotation) -> Void) {
    guard let selection else { return }
    var items = history.current
    guard let index = items.firstIndex(where: { $0.id == selection }) else { return }
    change(&items[index])
    history.replaceCurrent(items)
  }

  private func deleteSelected() {
    guard let selection else { return }
    history.commit(history.current.filter { $0.id != selection })
    self.selection = nil
  }

  // MARK: Apply

  private func applyAnnotations() {
    guard let url = context.files.first else { return }
    let items = history.current.filter { $0.kind != .text || !$0.text.isEmpty }
    context.apply {
      let image = try ToolImage.load(url)
      guard let result = AnnotationRenderer.render(items, onto: image) else {
        throw ToolImageError.unwritable(url.lastPathComponent)
      }
      let saved = try ToolImage.save(result, like: url, suffix: "-annotated")
      return String(localized: "Saved \(saved.lastPathComponent)")
    }
  }
}
