// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConverterKit
import DesignSystem
import ModuleKit
import SwiftUI

/// On-the-fly file conversion: drag a file, hold ⌘, release
/// on a format (DESIGN.md §2.5). At rest there is only a click monitor.
@MainActor
public final class ConvertModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "convert",
    nameKey: "Convert",
    symbol: "arrow.triangle.2.circlepath",
    tint: .orange,
    permissions: [],
    energyClass: .zero
  )

  /// How long the outcome stays visible before the picker disappears.
  static let resultDuration: Duration = .milliseconds(1400)

  private let context: ModuleContext
  private var panel: RadialPanelController?
  private var tools: ToolPanelController?
  private var watcher: FileDragWatcher?
  private var jobToken: ResourceBag.Token?
  private var jobTask: Task<Void, Never>?

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    let panel = RadialPanelController(resources: context.resources)
    panel.onChoose = { [weak self] item, files in self?.choose(item, files: files) }
    self.panel = panel
    tools = ToolPanelController(resources: context.resources)
    watcher = FileDragWatcher(
      resources: context.resources,
      onCommandDrag: { [weak self] files, point, advanced in self?.commandDrag(files, at: point, advanced: advanced) },
      onAdvancedChanged: { [weak self] advanced in self?.panel?.setAdvanced(advanced) },
      onCommandReleased: { [weak self] in self?.commandReleased() },
      onEnd: { [weak self] in self?.dragEnded() }
    )
  }

  public func stop() async {
    watcher = nil
    panel = nil
    tools?.close()
    tools = nil
    jobToken = nil
    jobTask = nil
  }

  public var settings: AnyView { AnyView(ConvertSettingsView()) }

  // MARK: Drag

  private func commandDrag(_ files: [URL], at point: CGPoint, advanced: Bool) {
    guard let panel, panel.model.status == .choosing || panel.frame == nil else { return }
    let formats = ConvertCatalog.formats(for: files)
    let tools = ConvertCatalog.tools(for: files)
    guard !formats.isEmpty || !tools.isEmpty else { return }
    panel.show(files: files, formats: formats, tools: tools, advanced: advanced, at: point)
  }

  /// Releasing ⌘ without choosing closes the picker and the drag continues (DESIGN.md §2.5).
  private func commandReleased() {
    guard let panel, panel.model.status == .choosing else { return }
    panel.hide(reason: "⌘ rilasciato")
  }

  /// The drop on the panel arrives before or after the global mouseUp: wait a moment.
  private func dragEnded() {
    let task = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard let panel = self?.panel, panel.model.status == .choosing else { return }
      panel.hide(reason: "drag ended")
    }
    context.resources.addTask(task)
  }

  // MARK: Choice

  private func choose(_ item: RadialItem, files: [URL]) {
    switch item {
    case .format(let format):
      convert(files, to: format)
    case .tool(let tool):
      panel?.hide()
      tools?.open(tool, files: files)
    }
  }

  // MARK: Conversion

  private func convert(_ files: [URL], to format: OutputFormat) {
    guard let panel else { return }
    panel.beginWorking()
    panel.onCancel = { [weak self] in self?.cancelConversion() }
    let model = panel.model
    let monotonic = MonotonicProgress()
    // QoS utility: a conversion must not compete for cores with the apps in use (§5.2 rule 6).
    let task = Task(priority: .utility) { [weak self] in
      let result = await Self.run(files, to: format) { fraction in
        // Hops to main arrive out of order: lower values are discarded.
        guard let value = monotonic.advance(to: fraction) else { return }
        Task { @MainActor in model.progress = max(model.progress ?? 0, value) }
      }
      guard let self, let panel = self.panel else { return }
      self.jobTask = nil
      guard let result else {
        // Cancelled by the user: no outcome, the picker closes.
        panel.hide(reason: "conversion cancelled")
        panel.model.status = .choosing
        return
      }
      panel.model.status = result
      try? await Task.sleep(for: Self.resultDuration)
      guard !Task.isCancelled else { return }
      panel.hide()
      panel.model.status = .choosing
    }
    jobTask = task
    jobToken = context.resources.addTask(task)
  }

  /// Esc or the button in the picker: stops the conversion in progress.
  private func cancelConversion() {
    guard panel?.model.status == .working else { return }
    jobTask?.cancel()
  }

  /// `nil` if the conversion was cancelled.
  nonisolated private static func run(
    _ files: [URL], to format: OutputFormat, progress: @escaping @Sendable (Double) -> Void
  ) async -> RadialModel.Status? {
    var created: [String] = []
    var failures: [String] = []
    for (index, file) in files.enumerated() {
      // Module off or job cancelled midway through a group: stop here.
      if Task.isCancelled { return nil }
      do {
        let urls = try await convertOne(file, to: format, index: index, count: files.count, progress: progress)
        created += urls.map(\.lastPathComponent)
      } catch is CancellationError {
        return nil
      } catch {
        if Task.isCancelled { return nil }
        // A file that fails to convert does not stop the others in the group.
        failures.append(message(for: error, file: file))
      }
    }
    if Task.isCancelled { return nil }
    return summary(created: created, failures: failures)
  }

  nonisolated private static func convertOne(
    _ file: URL, to format: OutputFormat, index: Int, count: Int, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> [URL] {
    if let preset = format.ffmpegPreset {
      let share = 1 / Double(count)
      return [
        try await FFmpegStage.convert(file, to: preset) { fraction in
          progress((Double(index) + fraction) * share)
        }
      ]
    }
    switch format.kind {
    case .audio, .video:
      return [try await MediaConverter.convert(file, to: format)]
    default:
      return try await Task.detached(priority: .utility) { try ImageConverter.convert(file, to: format) }.value
    }
  }

  /// Readable error text for a file that failed to convert.
  nonisolated static func message(for error: any Error, file: URL) -> String {
    switch error {
    case let error as FFmpegError:
      return error.localizedDescription
    case ConversionError.unreadable(let name):
      return String(localized: "Can't read \(name)")
    case ConversionError.unwritable(let name):
      return String(localized: "Can't write \(name)")
    default:
      return String(localized: "Can't convert \(file.lastPathComponent)")
    }
  }

  /// Outcome of a group: all succeeded, all failed or a mix "N created, M failed".
  nonisolated static func summary(created: [String], failures: [String]) -> RadialModel.Status {
    if failures.isEmpty {
      return created.count == 1 ? .done(created[0]) : .done(String(localized: "\(created.count) files created"))
    }
    if created.isEmpty { return .failed(failures[0]) }
    return .failed(String(localized: "\(created.count) created, \(failures.count) failed"))
  }
}

/// Progress that never goes backwards: several queues call it.
final class MonotonicProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var last = -1.0

  /// The value if it is greater than the last accepted one, otherwise `nil`.
  func advance(to value: Double) -> Double? {
    lock.withLock {
      guard value > last else { return nil }
      last = value
      return value
    }
  }
}

/// Prepares the input for ffmpeg: images that ffmpeg does not read well (HEIC,
/// AVIF…) go through a temporary PNG first. It sits in a system temporary folder,
/// not the user's: the helper wants the output next to
/// the input, so the intermediate output is also created there and then moved.
enum FFmpegStage {
  static let ffmpegImageInputs: Set<String> = FFmpegJob.imageSequenceExtensions

  static func convert(
    _ file: URL, to preset: FFmpegPreset, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    let ext = file.pathExtension.lowercased()
    // Names with `%` also go through the PNG: ffmpeg would read them as sequence patterns.
    let needsStaging =
      FileKind(file) == .image && (!ffmpegImageInputs.contains(ext) || file.path.contains("%"))
    guard preset == .webp, needsStaging else {
      return try await FFmpegConverter.convert(file, to: preset, progress: progress)
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let staged = folder.appendingPathComponent("ingresso").appendingPathExtension("png")
    try ImageConverter.writePNG(file, to: staged)
    let converted = try await FFmpegConverter.convert(staged, to: preset, progress: progress)
    // The final name follows the original, not the temporary file.
    let final = OutputNamer.url(for: file, extension: preset.fileExtension)
    try FileManager.default.moveItem(at: converted, to: final)
    return final
  }
}

struct ConvertSettingsView: View {
  var body: some View {
    Form {
      Section {
        Label("Drag one or more files and hold ⌘ to choose the format", systemImage: "command")
        Label("Hold ⌘⇧ to show the advanced tools (crop, annotations, audio…)", systemImage: "shift")
        Label("Drop the file on the petal you want", systemImage: "circle.dashed")
        Label("The new file appears next to the original, which stays untouched", systemImage: "doc.on.doc")
      } header: {
        Text("How to Use")
      }
      Section {
        LabeledContent("Images") {
          Text(verbatim: ConvertCatalog.rasterFormats.map(\.label).joined(separator: ", "))
        }
        LabeledContent("PDF") {
          Text(verbatim: ConvertCatalog.pdfFormats.map(\.label).joined(separator: ", "))
        }
      } header: {
        Text("Formats")
      } footer: {
        Text(
          FFmpegConverter.isAvailable
            ? "WebP, MP3, FLAC, Opus, WebM, MKV and animated GIF use the add-on engine (ffmpeg, LGPL)."
            : "WebP, MP3, FLAC, Opus, WebM, MKV and animated GIF need the add-on engine, which isn't in this build."
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text("Convert"))
  }
}
