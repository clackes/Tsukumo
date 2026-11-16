// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit

/// Recognises "files dragged with ⌘ held", from any app.
///
/// At rest there is only a global click monitor. The drag and modifier
/// monitors live between mouseDown and mouseUp; the
/// drag pasteboard is read only when ⌘ is held (DESIGN.md §2.5).
@MainActor
final class FileDragWatcher {
  private let resources: ResourceBag
  /// ⌘ held during a file drag: files and pointer position (AppKit coordinates).
  private let onCommandDrag: ([URL], CGPoint, Bool) -> Void
  /// ⇧ pressed or released while ⌘ stays held: `true` = advanced tools.
  private let onAdvancedChanged: (Bool) -> Void
  /// ⌘ released while the drag continues.
  private let onCommandReleased: () -> Void
  /// The mouse button was released.
  private let onEnd: () -> Void
  private var downToken: ResourceBag.Token?
  private var dragToken: ResourceBag.Token?
  private var baseline = 0
  private var lastCheck: TimeInterval = 0
  private var isActive = false
  private var isAdvanced = false

  init(
    resources: ResourceBag,
    onCommandDrag: @escaping ([URL], CGPoint, Bool) -> Void,
    onAdvancedChanged: @escaping (Bool) -> Void,
    onCommandReleased: @escaping () -> Void,
    onEnd: @escaping () -> Void
  ) {
    self.resources = resources
    self.onCommandDrag = onCommandDrag
    self.onAdvancedChanged = onAdvancedChanged
    self.onCommandReleased = onCommandReleased
    self.onEnd = onEnd
    downToken = try? resources.addGlobalMonitor(matching: .leftMouseDown) { [weak self] _ in self?.begin() }
  }

  private func begin() {
    stopDragMonitor()
    isActive = false
    baseline = NSPasteboard(name: .drag).changeCount
    // `flagsChanged` covers ⌘ pressed with the mouse still; if macOS does not deliver it
    // without permissions (spike 25), the first movement is enough: drag events
    // carry the modifiers too.
    let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .flagsChanged]
    dragToken = try? resources.addGlobalMonitor(matching: mask) { [weak self] event in self?.handle(event) }
  }

  private func handle(_ event: NSEvent) {
    if event.type == .leftMouseUp {
      stopDragMonitor()
      let wasActive = isActive
      isActive = false
      if wasActive { onEnd() }
      return
    }
    let command = event.modifierFlags.contains(.command)
    let advanced = event.modifierFlags.contains(.shift)
    if command, !isActive, let files = draggedFiles() {
      isActive = true
      isAdvanced = advanced
      onCommandDrag(files, NSEvent.mouseLocation, advanced)
    } else if !command, isActive {
      isActive = false
      onCommandReleased()
    } else if command, isActive, advanced != isAdvanced {
      isAdvanced = advanced
      onAdvancedChanged(advanced)
    }
  }

  /// Files of the drag in progress, if it is a file drag that started after the click.
  private func draggedFiles() -> [URL]? {
    // At most 30 pasteboard reads per second.
    let uptime = ProcessInfo.processInfo.systemUptime
    guard uptime - lastCheck >= 1.0 / 30 else { return nil }
    lastCheck = uptime
    let pasteboard = NSPasteboard(name: .drag)
    guard pasteboard.changeCount != baseline else { return nil }
    let urls =
      pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.isEmpty ? nil : urls
  }

  private func stopDragMonitor() {
    if let dragToken { resources.cancel(dragToken) }
    dragToken = nil
    lastCheck = 0
  }
}
