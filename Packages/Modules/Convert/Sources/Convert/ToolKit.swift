// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import Observation
import SwiftUI

/// Outcome of a tool, shown in the panel before it closes.
enum ToolOutcome: Equatable {
  case done(String)
  case failed(String)
}

/// What the panel hands to a tool: the files and the shared state.
/// The tool draws only its own content and the Apply button
/// (`ToolFooter`); window, title and closing belong to the panel.
@MainActor
@Observable
final class ToolContext {
  enum Status: Equatable {
    case editing
    case working
    case finished(ToolOutcome)
  }

  let tool: ConvertTool
  let files: [URL]
  var status: Status = .editing
  /// Closes the panel (set by the controller).
  var close: () -> Void = {}

  init(tool: ConvertTool, files: [URL]) {
    self.tool = tool
    self.files = files
  }

  var isWorking: Bool { status == .working }

  /// Runs the work off the main actor and shows the outcome. The work returns
  /// the success message (for example the name of the file created); a thrown
  /// error becomes a message in the panel. After a success the panel closes by itself.
  func apply(_ work: @escaping @Sendable () async throws -> String) {
    guard status == .editing else { return }
    status = .working
    Task(priority: .utility) { [weak self] in
      do {
        let message = try await work()
        self?.status = .finished(.done(message))
        try? await Task.sleep(for: .milliseconds(1300))
        self?.close()
      } catch {
        self?.status = .finished(.failed(error.localizedDescription))
        try? await Task.sleep(for: .seconds(2.5))
        if self?.status == .finished(.failed(error.localizedDescription)) { self?.status = .editing }
      }
    }
  }
}

/// Apply button with working state and outcome, the same for all tools.
struct ToolFooter: View {
  let context: ToolContext
  var canApply = true
  var title: LocalizedStringKey = "Apply"
  let apply: () -> Void

  var body: some View {
    HStack {
      switch context.status {
      case .editing, .working:
        Spacer()
      case .finished(.done(let message)):
        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        Spacer()
      case .finished(.failed(let message)):
        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Spacer()
      }
      if context.isWorking { ProgressView().controlSize(.small) }
      Button(title, action: apply)
        .buttonStyle(.glassProminent)
        .disabled(!canApply || context.status != .editing)
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

/// Placeholder for tools not yet written.
struct ToolPlaceholder: View {
  let context: ToolContext

  var body: some View {
    ContentUnavailableView("Coming Soon", systemImage: context.tool.symbol)
      .frame(maxWidth: .infinity, minHeight: 240)
  }
}

/// Initial size of the panel and the view of each tool.
@MainActor
enum ToolContentFactory {
  static func size(for tool: ConvertTool) -> CGSize {
    switch tool {
    case .edit, .addBackground, .crop, .annotate, .redact: CGSize(width: 560, height: 680)
    case .compress, .metadata: CGSize(width: 460, height: 520)
    case .trimAudio, .audioChannels: CGSize(width: 520, height: 420)
    case .bleeps: CGSize(width: 560, height: 480)
    }
  }

  @ViewBuilder
  static func view(for context: ToolContext) -> some View {
    switch context.tool {
    case .compress: CompressToolView(context: context)
    case .metadata: MetadataToolView(context: context)
    case .edit: EditToolView(context: context)
    case .annotate: AnnotateToolView(context: context)
    case .addBackground: AddBackgroundToolView(context: context)
    case .crop: CropToolView(context: context)
    case .redact: RedactToolView(context: context)
    case .trimAudio: TrimAudioToolView(context: context)
    case .audioChannels: AudioChannelsToolView(context: context)
    case .bleeps: BleepsToolView(context: context)
    }
  }
}

/// Liquid Glass card with title and close, as in the reference.
struct ToolHostView: View {
  let context: ToolContext

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Text(verbatim: context.tool.title).font(.headline)
        HStack {
          Button {
            context.close()
          } label: {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 20, height: 20)
          }
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .accessibilityLabel(Text("Close"))
          Spacer()
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      ToolContentFactory.view(for: context)
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
  }
}

private final class KeyPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// Tool window: one at a time, exists only while open.
@MainActor
final class ToolPanelController {
  private let resources: ResourceBag
  private var panel: NSPanel?
  private(set) var context: ToolContext?

  init(resources: ResourceBag) {
    self.resources = resources
    resources.add(.window) { [weak self] in self?.close() }
  }

  func open(_ tool: ConvertTool, files: [URL]) {
    close()
    let context = ToolContext(tool: tool, files: files)
    context.close = { [weak self] in self?.close() }
    self.context = context

    let size = ToolContentFactory.size(for: tool)
    let panel = KeyPanel(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let hosting = NSHostingView(rootView: ToolHostView(context: context))
    hosting.frame = CGRect(origin: .zero, size: size)
    panel.contentView = hosting
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate()
    self.panel = panel
  }

  func close() {
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel = nil
    context = nil
  }
}
