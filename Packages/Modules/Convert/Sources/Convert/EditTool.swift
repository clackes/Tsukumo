// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import SwiftUI

/// Edit Photo: light adjustments with live preview; Apply reprocesses the original at full resolution.
struct EditToolView: View {
  let context: ToolContext

  @State private var engine = ImageEditingEngine()
  @State private var adjustments = EditAdjustments()
  @State private var source: CGImage?
  @State private var preview: CGImage?
  @State private var loadFailed = false

  var body: some View {
    VStack(spacing: 0) {
      previewArea
      controls
      Divider()
      ToolFooter(context: context, canApply: !adjustments.isNeutral, apply: apply)
    }
    .task { await loadSource() }
    .task(id: adjustments) { await updatePreview() }
  }

  private var previewArea: some View {
    ZStack(alignment: .topTrailing) {
      RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.82))
      if let shown = preview ?? source {
        Image(decorative: shown, scale: 1)
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .padding(10)
      } else if loadFailed {
        Label("Preview unavailable", systemImage: "photo.badge.exclamationmark")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Button("Restore") { adjustments = EditAdjustments() }
        .buttonStyle(.glass)
        .controlSize(.small)
        .disabled(adjustments.isNeutral)
        .padding(12)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(14)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Light").font(.subheadline.weight(.semibold))
      AdjustmentRow(title: "Exposure", value: $adjustments.exposure, range: -3...3, unit: " EV", decimals: 2)
      AdjustmentRow(title: "Brightness", value: $adjustments.brightness, range: -100...100)
      AdjustmentRow(title: "Contrast", value: $adjustments.contrast, range: -100...100)
      AdjustmentRow(title: "Highlights", value: $adjustments.highlights, range: -100...100)
      AdjustmentRow(title: "Shadows", value: $adjustments.shadows, range: -100...100)
    }
    .padding(.horizontal, 18)
    .padding(.bottom, 12)
  }

  private func loadSource() async {
    guard let first = context.files.first else { return }
    let loaded = try? await Task.detached(priority: .userInitiated) {
      try ToolImage.load(first, maxPixel: 1600)
    }.value
    if let loaded {
      source = loaded
    } else {
      loadFailed = true
    }
  }

  /// Reprocesses the preview; a change to `adjustments` cancels the previous pass.
  private func updatePreview() async {
    guard let source, !adjustments.isNeutral else {
      preview = nil
      return
    }
    let current = adjustments
    let engine = engine
    // Short wait: if the user keeps dragging, this pass is cancelled before the computation.
    try? await Task.sleep(for: .milliseconds(20))
    if Task.isCancelled { return }
    let result = await Task.detached(priority: .userInitiated) {
      engine.render(source, adjustments: current)
    }.value
    if !Task.isCancelled { preview = result }
  }

  private func apply() {
    let files = context.files
    let values = adjustments
    let engine = engine
    context.apply {
      var saved = 0
      for file in files {
        try Task.checkCancellation()
        let original = try ToolImage.load(file)
        guard let edited = engine.render(original, adjustments: values) else {
          throw ToolImageError.unwritable(file.lastPathComponent)
        }
        try ToolImage.save(edited, like: file, suffix: "-edited", quality: 0.95)
        saved += 1
      }
      return saved == 1 ? String(localized: "Photo saved") : String(localized: "\(saved) photos saved")
    }
  }
}

/// Slider with value, unit and per-item reset.
private struct AdjustmentRow: View {
  let title: LocalizedStringKey
  @Binding var value: Double
  let range: ClosedRange<Double>
  var unit = ""
  var decimals = 0

  var body: some View {
    HStack(spacing: 8) {
      Text(title).frame(width: 92, alignment: .leading)
      Slider(value: $value, in: range)
      Text(verbatim: formatted)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .trailing)
      Button {
        value = 0
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .opacity(value == 0 ? 0.25 : 1)
      .disabled(value == 0)
      .accessibilityLabel(Text("Reset"))
    }
    .font(.callout)
  }

  private var formatted: String {
    if decimals > 0 {
      return value.formatted(.number.precision(.fractionLength(decimals)).sign(strategy: .always(includingZero: false)))
        + unit
    }
    return value.rounded().formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: true)))
      + unit
  }
}
