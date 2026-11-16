// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Add BG: the image on a background of choice (gradient, solid, colour or image), saved as PNG.
struct AddBackgroundToolView: View {
  let context: ToolContext

  @State private var style = BackgroundStyle.gradient(0)
  @State private var customColor = Color(.sRGB, red: 0.2, green: 0.5, blue: 0.95, opacity: 1)
  @State private var source: CGImage?
  @State private var preview: CGImage?
  @State private var loadFailed = false

  private let columns = [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 10)]

  var body: some View {
    VStack(spacing: 0) {
      previewArea
      picker
      Divider()
      ToolFooter(context: context, apply: apply)
    }
    .task { await loadSource() }
    .task(id: PreviewKey(style: style, ready: source != nil)) { await updatePreview() }
  }

  /// Changes when the preview needs redrawing: new background or newly loaded image.
  private struct PreviewKey: Hashable {
    let style: BackgroundStyle
    let ready: Bool
  }

  private var previewArea: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.12))
      if let preview {
        Image(decorative: preview, scale: 1)
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .padding(10)
      } else if loadFailed {
        Label("Preview unavailable", systemImage: "photo.badge.exclamationmark")
          .foregroundStyle(.secondary)
      } else {
        ProgressView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(14)
  }

  private var picker: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Background").font(.subheadline.weight(.semibold))
      ScrollView {
        LazyVGrid(columns: columns, spacing: 10) {
          ColorPicker("Choose Color", selection: $customColor, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44, height: 44)
            .help(Text("Custom color"))
            .onChange(of: customColor) { _, new in style = .color(RGBAColor(new)) }
          Button(action: chooseImage) {
            Image(systemName: "photo.badge.plus")
              .frame(width: 44, height: 44)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay(selection(isImage))
          }
          .buttonStyle(.plain)
          .help(Text("Choose an image"))
          .accessibilityLabel(Text("Choose an image"))
          ForEach(BackgroundPresets.gradients.indices, id: \.self) { index in
            swatch(.gradient(index)) {
              LinearGradient(
                colors: BackgroundPresets.gradients[index].map(\.swiftUI), startPoint: .topLeading,
                endPoint: .bottomTrailing)
            }
          }
          ForEach(BackgroundPresets.solids.indices, id: \.self) { index in
            swatch(.solid(index)) { BackgroundPresets.solids[index].swiftUI }
          }
        }
        .padding(3)
      }
      .frame(height: 132)
    }
    .padding(.horizontal, 18)
    .padding(.bottom, 12)
  }

  private var isImage: Bool {
    if case .image = style { return true }
    return false
  }

  private func swatch<Fill: View>(_ value: BackgroundStyle, @ViewBuilder fill: () -> Fill) -> some View {
    Button {
      style = value
    } label: {
      fill()
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        .overlay(selection(style == value))
    }
    .buttonStyle(.plain)
  }

  private func selection(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .strokeBorder(Color.accentColor, lineWidth: 3)
      .padding(-3)
      .opacity(selected ? 1 : 0)
  }

  /// The user picks the background image: the panel opens only on this action.
  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url { style = .image(url) }
  }

  private func loadSource() async {
    guard let first = context.files.first else { return }
    let loaded = try? await Task.detached(priority: .userInitiated) {
      try ToolImage.load(first, maxPixel: 1200)
    }.value
    if let loaded {
      source = loaded
    } else {
      loadFailed = true
    }
  }

  private func updatePreview() async {
    guard let source else { return }
    let current = style
    try? await Task.sleep(for: .milliseconds(20))
    if Task.isCancelled { return }
    let result = await Task.detached(priority: .userInitiated) {
      BackgroundCompositor.render(source, style: current)
    }.value
    if !Task.isCancelled { preview = result }
  }

  private func apply() {
    let files = context.files
    let chosen = style
    context.apply {
      var saved = 0
      for file in files {
        try Task.checkCancellation()
        let original = try ToolImage.load(file)
        guard let composed = BackgroundCompositor.render(original, style: chosen) else {
          throw ToolImageError.unwritable(file.lastPathComponent)
        }
        try BackgroundCompositor.savePNG(composed, like: file, suffix: "-background")
        saved += 1
      }
      return saved == 1 ? String(localized: "Image saved") : String(localized: "\(saved) images saved")
    }
  }
}
