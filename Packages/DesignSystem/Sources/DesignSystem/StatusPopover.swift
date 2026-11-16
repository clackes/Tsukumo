// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Glass panel attached below a menu bar icon: the same one
/// for all modules (Tsukumo, Monitor, Sound), so they share a single look.
///
/// `NSPopover` leaves a gap and an arrow under the bar; here there is a borderless
/// `NSPanel` flush below the icon, like system menus. It closes on the first
/// click outside (event monitors installed only while it is open) or with Esc.
/// The content is built on open and thrown away on close: when closed
/// no view and no monitor exists.
@MainActor
public final class StatusPopover: NSObject {
  /// Standard width of the panels (pt).
  public static let width: CGFloat = 320

  public private(set) var isOpen = false
  /// Called on open (`true`) and on close (`false`).
  public var onVisibilityChange: ((Bool) -> Void)?

  private let button: NSStatusBarButton
  private let content: @MainActor () -> AnyView
  private var panel: NSPanel?
  private var monitors: [Any] = []
  /// Same distance from the menu bar that macOS uses for icon menus.
  private static let gapBelowMenuBar: CGFloat = 4

  /// - Parameter content: panel view, without background or margins: the
  ///   panel adds them.
  public init(button: NSStatusBarButton, content: @escaping @MainActor () -> AnyView) {
    self.button = button
    self.content = content
    super.init()
    button.target = self
    button.action = #selector(toggle)
  }

  /// Removes the panel and detaches the icon: to be called in the module's `stop()`.
  public func invalidate() {
    close()
    button.target = nil
    button.action = nil
  }

  @objc public func toggle() {
    if isOpen { close() } else { show() }
  }

  public func show() {
    guard panel == nil else { return }
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 200),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let root = StatusPopoverChrome(content: content())
      // The panel follows the view: rows that appear or disappear
      // resize it while it is open.
      .onGeometryChange(for: CGSize.self, of: \.size) { [weak self] size in self?.resize(to: size) }
    let host = NSHostingView(rootView: root)
    host.translatesAutoresizingMaskIntoConstraints = true
    panel.contentView = host
    panel.setContentSize(host.fittingSize)
    self.panel = panel
    position(panel)
    panel.orderFrontRegardless()
    button.highlight(true)
    installMonitors()
    isOpen = true
    onVisibilityChange?(true)
  }

  public func close() {
    guard let panel else { return }
    panel.orderOut(nil)
    panel.contentView = nil
    self.panel = nil
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []
    button.highlight(false)
    isOpen = false
    onVisibilityChange?(false)
  }

  private func resize(to size: CGSize) {
    guard let panel, size.height > 0, panel.frame.size != size else { return }
    panel.setContentSize(size)
    position(panel)
  }

  /// Centered on the icon, flush below the bar; stays inside the screen.
  private func position(_ panel: NSPanel) {
    guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
    let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
    let size = panel.frame.size
    let margin: CGFloat = 8
    let visible = screen.visibleFrame
    let originX = min(max(icon.midX - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
    let originY = icon.minY - Self.gapBelowMenuBar - size.height
    panel.setFrame(CGRect(x: originX, y: originY, width: size.width, height: size.height).integral, display: true)
  }

  private func installMonitors() {
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: clicks,
      handler: { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      })
    {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: clicks.union(.keyDown),
      handler: { [weak self] event in
        let isEscape = event.type == .keyDown && event.keyCode == 53
        if event.type == .keyDown, !isEscape { return event }
        let window = event.window
        let swallow = MainActor.assumeIsolated { () -> Bool in
          guard let self else { return false }
          if isEscape {
            // Esc closes, like a menu.
            self.close()
            return true
          }
          // Click on the icon: `toggle()` decides. Click elsewhere in the app: closes.
          if window !== self.button.window, window !== self.panel { self.close() }
          return false
        }
        return swallow ? nil : event
      })
    {
      monitors.append(local)
    }
  }
}

/// Background and margins common to all panels: glass like system menus.
public struct StatusPopoverChrome<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The panel is born from the icon: a single spring on open, then nothing.
  @State private var shown = false
  let content: Content

  public init(content: Content) { self.content = content }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: TsukumoTokens.Radius.panel, style: .continuous)
    let inner =
      content
      .padding(TsukumoTokens.Spacing.md)
      .frame(width: StatusPopover.width)
    Group {
      if reduceTransparency {
        inner.background(.regularMaterial, in: shape)
      } else {
        inner.glassEffect(.regular, in: shape)
      }
    }
    .scaleEffect(shown || reduceMotion ? 1 : 0.9, anchor: .top)
    .opacity(shown ? 1 : 0)
    .blur(radius: shown || reduceMotion ? 0 : 6)
    .onAppear {
      withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) { shown = true }
    }
  }
}

/// Backdrop that appears under the pointer, with a short fade.
public struct HoverHighlight: ViewModifier {
  @State private var hovering = false

  public init() {}

  public func body(content: Content) -> some View {
    content
      .background(
        .primary.opacity(hovering ? 0.08 : 0),
        in: RoundedRectangle(cornerRadius: TsukumoTokens.Radius.control, style: .continuous)
      )
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

/// Header of a panel: module icon, title and, on the right, an
/// optional accessory (a switch, a value).
public struct PopoverHeader<Accessory: View>: View {
  private let title: Text
  private let symbol: String
  private let tint: Color
  private let accessory: Accessory

  public init(_ title: Text, symbol: String, tint: Color, @ViewBuilder accessory: () -> Accessory) {
    self.title = title
    self.symbol = symbol
    self.tint = tint
    self.accessory = accessory()
  }

  public var body: some View {
    HStack(spacing: TsukumoTokens.Spacing.sm) {
      ModuleIcon(symbol: symbol, color: tint, size: 24)
      title.font(.headline)
      Spacer(minLength: 0)
      accessory
    }
  }
}

extension PopoverHeader where Accessory == EmptyView {
  public init(_ title: Text, symbol: String, tint: Color) {
    self.init(title, symbol: symbol, tint: tint) { EmptyView() }
  }
}

/// Inner box of a panel: a group of rows on lighter glass,
/// like the Control Center blocks.
public struct PopoverSection<Content: View>: View {
  private let title: Text?
  private let content: Content

  public init(_ title: Text? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.xs) {
      if let title {
        title.font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
          .padding(.horizontal, TsukumoTokens.Spacing.xs)
      }
      VStack(alignment: .leading, spacing: TsukumoTokens.Spacing.xs) { content }
        .padding(TsukumoTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: TsukumoTokens.Radius.card, style: .continuous))
    }
  }
}
