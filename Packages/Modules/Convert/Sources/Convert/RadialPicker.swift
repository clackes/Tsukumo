// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import SwiftUI

/// Radial picker in Liquid Glass: petals around, preview in the centre.
/// Mechanics as in the reference (Tangerine), our own graphics (DESIGN.md §2.5).
struct RadialPicker: View {
  let model: RadialModel

  private var layout: RadialLayout { model.layout }

  var body: some View {
    ZStack {
      GlassEffectContainer(spacing: 6) {
        ZStack {
          ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
            petal(item, index: index)
          }
        }
        .frame(width: RadialPanelController.side, height: RadialPanelController.side)
      }
      .frame(width: RadialPanelController.side, height: RadialPanelController.side)
      center
    }
    .frame(width: RadialPanelController.side, height: RadialPanelController.side)
    .animation(.spring(response: 0.22, dampingFraction: 0.8), value: model.highlighted)
    .animation(.easeOut(duration: TsukumoTokens.Motion.quick), value: model.status)
    .transition(.scale(0.85).combined(with: .opacity))
  }

  private func petal(_ item: RadialItem, index: Int) -> some View {
    let selected = model.highlighted == index
    let angle = layout.centerAngle(of: index)
    let radius = (layout.innerRadius + layout.outerRadius) / 2
    let shape = PetalShape(layout: layout, index: index)
    // The label is the content of the glass view: the glass is drawn
    // behind it. If it were a sibling view, the container would cover it.
    return ZStack {
      // The chosen petal: accent fill over the glass, which alone in
      // an inactive window barely tints.
      if selected { shape.fill(Color.accentColor.opacity(0.85)) }
      VStack(spacing: 5) {
        if let symbol = item.symbol {
          Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
        }
        Text(verbatim: item.symbol == nil ? item.label : item.label.uppercased())
          .font(.system(size: item.symbol == nil ? 15 : 11, weight: .bold, design: .rounded))
      }
      .offset(x: sin(angle) * radius, y: -cos(angle) * radius)
    }
    .foregroundStyle(selected ? Color.white : Color.primary)
    .frame(width: RadialPanelController.side, height: RadialPanelController.side)
    .glassEffect(selected ? .regular.tint(.accentColor) : .regular, in: shape)
    .accessibilityElement()
    .accessibilityLabel(Text(verbatim: item.label))
  }

  @ViewBuilder private var center: some View {
    let side = layout.innerRadius * 2 - 10
    ZStack {
      Circle().fill(.black.opacity(0.08))
      switch model.status {
      case .choosing:
        preview(side: side)
      case .working:
        VStack(spacing: 8) {
          if let progress = model.progress {
            ProgressView(value: progress).progressViewStyle(.circular).controlSize(.large)
          } else {
            ProgressView().controlSize(.large)
          }
          Button {
            model.onCancel?()
          } label: {
            Label("Cancel", systemImage: "xmark.circle.fill")
              .labelStyle(.titleAndIcon)
              .font(.system(size: 11, weight: .semibold))
          }
          .buttonStyle(.plain)
          .help("Cancel (Esc)")
        }
      case .done(let message):
        statusLabel("checkmark.circle.fill", message, tint: .green)
      case .failed(let message):
        statusLabel("exclamationmark.triangle.fill", message, tint: .orange)
      }
    }
    .frame(width: side, height: side)
    .clipShape(Circle())
  }

  private func preview(side: CGFloat) -> some View {
    ZStack(alignment: .bottom) {
      if let thumbnail = model.thumbnail {
        Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: side, height: side)
      }
      VStack(spacing: 4) {
        if model.canSwitch {
          Label(
            model.mode == .formats ? "⇧ tools" : "⌘ formats",
            systemImage: "command"
          )
          .labelStyle(.titleOnly)
          .font(.system(size: 10, weight: .semibold))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .glassEffect(.regular, in: Capsule())
        }
        Text(verbatim: model.sizeText)
          .font(.system(size: 11, weight: .semibold))
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .glassEffect(.regular, in: Capsule())
      }
      .padding(.bottom, 12)
    }
  }

  private func statusLabel(_ symbol: String, _ text: String, tint: Color) -> some View {
    VStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(tint)
      Text(verbatim: text).font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center)
        .lineLimit(2).padding(.horizontal, 8)
    }
  }
}

/// Annular sector for a petal, with a gap between petals.
struct PetalShape: Shape {
  let layout: RadialLayout
  let index: Int
  /// Gap between two petals, in points measured on the inner edge.
  private let gap: CGFloat = 6

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let inner = layout.innerRadius + 4
    let outer = layout.outerRadius
    let middle = layout.centerAngle(of: index) - .pi / 2
    let halfInner = layout.slice / 2 - Double(gap / 2 / inner)
    let halfOuter = layout.slice / 2 - Double(gap / 2 / outer)
    var path = Path()
    path.addArc(
      center: center, radius: outer, startAngle: .radians(middle - halfOuter), endAngle: .radians(middle + halfOuter),
      clockwise: false)
    path.addArc(
      center: center, radius: inner, startAngle: .radians(middle + halfInner), endAngle: .radians(middle - halfInner),
      clockwise: true)
    path.closeSubpath()
    return path
  }
}
