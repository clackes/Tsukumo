// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit

/// File placed in the island.
struct ShelfItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let url: URL

  init(url: URL, id: UUID = UUID()) {
    self.id = id
    self.url = url
  }
}

enum Shelf {
  static let limit = 12

  /// Appends at the end without duplicates; beyond the limit the oldest drop out.
  static func adding(_ urls: [URL], to items: [ShelfItem], limit: Int = Shelf.limit) -> [ShelfItem] {
    var result = items
    var known = Set(items.map { $0.url.standardizedFileURL })
    for url in urls where url.isFileURL {
      guard known.insert(url.standardizedFileURL).inserted else { continue }
      result.append(ShelfItem(url: url))
    }
    return Array(result.suffix(max(limit, 0)))
  }

  /// Bookmarks follow the file even if it is moved or renamed.
  static func bookmarks(for items: [ShelfItem]) -> [Data] {
    items.compactMap { try? $0.url.bookmarkData() }
  }

  /// Discards files that no longer exist.
  static func items(from bookmarks: [Data]) -> [ShelfItem] {
    bookmarks.compactMap { data in
      var stale = false
      guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
        FileManager.default.fileExists(atPath: url.path)
      else { return nil }
      return ShelfItem(url: url)
    }
  }

  /// Opens the system AirDrop picker: there is no API to list the devices.
  @MainActor
  @discardableResult
  static func airDrop(_ urls: [URL]) -> Bool {
    guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls)
    else { return false }
    service.perform(withItems: urls)
    return true
  }
}

/// Detects a file drag arriving near the notch.
///
/// At rest only a click monitor exists. The drag monitor lives
/// between mouseDown and mouseUp, and the drag pasteboard is read only when the
/// pointer is in the hot zone (DESIGN.md §2.1, shelf).
@MainActor
final class ShelfDragMonitor {
  private let resources: ResourceBag
  private let hotZone: () -> CGRect
  private let onEnter: () -> Void
  private let onEnd: () -> Void
  private var downToken: ResourceBag.Token?
  private var dragToken: ResourceBag.Token?
  private var baseline = 0
  private var lastCheck: TimeInterval = 0
  private var didEnter = false

  init(
    resources: ResourceBag,
    hotZone: @escaping () -> CGRect,
    onEnter: @escaping () -> Void,
    onEnd: @escaping () -> Void
  ) {
    self.resources = resources
    self.hotZone = hotZone
    self.onEnter = onEnter
    self.onEnd = onEnd
    downToken = try? resources.addGlobalMonitor(matching: .leftMouseDown) { [weak self] _ in self?.begin() }
  }

  func invalidate() {
    end(notify: false)
    if let downToken { resources.cancel(downToken) }
    downToken = nil
  }

  private func begin() {
    end(notify: false)
    baseline = NSPasteboard(name: .drag).changeCount
    dragToken = try? resources.addGlobalMonitor(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
      if event.type == .leftMouseUp {
        self?.end(notify: true)
      } else {
        self?.dragged()
      }
    }
  }

  private func dragged() {
    guard !didEnter, hotZone().contains(NSEvent.mouseLocation) else { return }
    // At most 30 pasteboard reads per second while staying in the zone.
    let uptime = ProcessInfo.processInfo.systemUptime
    guard uptime - lastCheck >= 1.0 / 30 else { return }
    lastCheck = uptime
    let pasteboard = NSPasteboard(name: .drag)
    guard pasteboard.changeCount != baseline,
      pasteboard.availableType(from: [.fileURL]) != nil
    else { return }
    didEnter = true
    onEnter()
  }

  private func end(notify: Bool) {
    if let dragToken { resources.cancel(dragToken) }
    dragToken = nil
    let entered = didEnter
    didEnter = false
    lastCheck = 0
    if notify, entered { onEnd() }
  }
}
