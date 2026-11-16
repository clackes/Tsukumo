// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import Observation
import SwiftUI

/// Visible state of the switcher.
@MainActor
@Observable
final class SwitcherModel {
  var windows: [SwitcherWindow] = []
  var selection = 0
  var thumbnails: [CGWindowID: NSImage] = [:]
  var icons: [pid_t: NSImage] = [:]
  /// The panel is on screen: the grid enters with a short spring.
  var isShown = false

  var selected: SwitcherWindow? { windows.indices.contains(selection) ? windows[selection] : nil }

  func move(_ step: Int) {
    guard !windows.isEmpty else { return }
    selection = ((selection + step) % windows.count + windows.count) % windows.count
  }
}

/// Panel centered on the pointer's screen. It never takes focus.
@MainActor
final class SwitcherPanelController {
  let model = SwitcherModel()
  var onPick: ((Int) -> Void)?
  private var panel: NSPanel?

  var isVisible: Bool { panel?.isVisible == true }

  func show() {
    let panel = panel ?? makePanel()
    self.panel = panel
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    guard let screen else { return }
    let hosting = panel.contentView as? NSHostingView<SwitcherView>
    let size = hosting?.fittingSize ?? CGSize(width: 600, height: 200)
    let width = min(size.width, screen.visibleFrame.width * 0.9)
    let height = min(size.height, screen.visibleFrame.height * 0.8)
    panel.setFrame(
      CGRect(
        x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2, width: width,
        height: height
      ).integral, display: true)
    panel.orderFrontRegardless()
    model.isShown = true
  }

  func hide() {
    panel?.orderOut(nil)
    model.isShown = false
  }

  func close() {
    hide()
    panel?.contentView = nil
    panel = nil
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: 600, height: 200),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.contentView = NSHostingView(
      rootView: SwitcherView(model: model) { [weak self] index in self?.onPick?(index) })
    return panel
  }
}

/// Grid of cards: icon, thumbnail if present, title. Glass sits only on the
/// container (controls layer); the cards are content.
struct SwitcherView: View {
  let model: SwitcherModel
  let pick: (Int) -> Void

  private let columns = [GridItem(.adaptive(minimum: 168, maximum: 168), spacing: 10)]
  @Namespace private var highlight
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Quick: the switcher must never make you wait.
  private static let selectionSpring = Animation.spring(response: 0.22, dampingFraction: 0.8)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 10) {
      ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
        card(window, selected: index == model.selection)
          .onTapGesture { pick(index) }
      }
    }
    .padding(14)
    .frame(width: gridWidth)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .scaleEffect(model.isShown || reduceMotion ? 1 : 0.94)
    .opacity(model.isShown ? 1 : 0)
    .animation(model.isShown ? .spring(response: 0.24, dampingFraction: 0.78) : nil, value: model.isShown)
    // The highlight slides from one window to another instead of jumping.
    .animation(reduceMotion ? nil : Self.selectionSpring, value: model.selection)
    .animation(.easeOut(duration: 0.2), value: model.thumbnails.count)
  }

  /// Up to 6 columns, then it wraps.
  private var gridWidth: CGFloat {
    let count = CGFloat(min(max(model.windows.count, 1), 6))
    return count * 168 + (count - 1) * 10 + 28
  }

  private func card(_ window: SwitcherWindow, selected: Bool) -> some View {
    VStack(spacing: 6) {
      ZStack(alignment: .bottomTrailing) {
        if let thumbnail = model.thumbnails[window.id] {
          Image(nsImage: thumbnail).resizable().scaledToFit()
            .frame(width: 152, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
          icon(for: window).frame(width: 64, height: 64).frame(width: 152, height: 96)
        }
        if model.thumbnails[window.id] != nil {
          icon(for: window).frame(width: 28, height: 28).offset(x: 6, y: 6)
        }
      }
      Text(verbatim: window.title)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .truncationMode(.middle)
      if window.isMinimized {
        Text("Minimized in the Dock").font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
    .padding(8)
    .frame(width: 168)
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color.accentColor.opacity(0.35))
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
          )
          .matchedGeometryEffect(id: "selection", in: highlight)
      }
    }
    .scaleEffect(selected && !reduceMotion ? 1.03 : 1)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder private func icon(for window: SwitcherWindow) -> some View {
    if let icon = model.icons[window.pid] {
      Image(nsImage: icon).resizable().scaledToFit()
    } else {
      Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary)
    }
  }
}
