// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import EventKit
import ModuleKit

/// Next calendar event, reduced to what the island shows.
struct UpcomingEvent: Equatable, Sendable, Identifiable {
  let id: String
  var title: String
  var start: Date
  var end: Date
  /// Meeting link (Meet, Zoom, Teams), if the event contains one.
  var joinURL: URL?
}

enum CalendarAccess: Sendable {
  case granted, denied, notDetermined
}

enum CalendarLogic {
  /// The "in N min" activity starts at this distance from the start.
  static let announceLead: TimeInterval = 5 * 60
  /// An event stays "the next one" for a while after it starts, so "Join" is still useful.
  static let graceAfterStart: TimeInterval = 10 * 60
  static let lookAhead: TimeInterval = 7 * 24 * 3600

  private static let meetingPatterns = [
    #"https://meet\.google\.com/[a-z0-9\-]+"#,
    #"https://[a-z0-9\-]+\.zoom\.us/[jw]/[^\s<>"']+"#,
    #"https://zoom\.us/[jw]/[^\s<>"']+"#,
    #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"']+"#,
    #"https://teams\.microsoft\.com/meet/[^\s<>"']+"#,
    #"https://teams\.live\.com/meet/[^\s<>"']+"#,
  ]

  /// First recognized meeting link. Only https and only known hosts: nothing else opens with a click.
  static func joinURL(in texts: [String?]) -> URL? {
    for text in texts.compactMap(\.self) {
      for pattern in meetingPatterns {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
        if let url = URL(string: String(text[range])) { return url }
      }
    }
    return nil
  }

  /// The first event not yet finished and started recently or not yet started.
  static func next(from events: [UpcomingEvent], now: Date) -> UpcomingEvent? {
    events
      .filter { $0.end > now && $0.start.addingTimeInterval(graceAfterStart) > now }
      .min { $0.start < $1.start }
  }

  /// When to recompute: at the announcement, at the start and at the end of the grace period.
  /// With no events a daily check is enough; changes arrive from `EKEventStoreChanged`.
  static func nextRefresh(for event: UpcomingEvent?, now: Date) -> Date {
    let fallback = now.addingTimeInterval(24 * 3600)
    guard let event else { return fallback }
    let boundaries = [
      event.start.addingTimeInterval(-announceLead),
      event.start,
      min(event.end, event.start.addingTimeInterval(graceAfterStart)),
    ]
    return min(boundaries.first { $0 > now } ?? fallback, fallback)
  }

  /// Minutes to the start, only inside the announcement window.
  static func minutesUntilStart(of event: UpcomingEvent, now: Date) -> Int? {
    let remaining = event.start.timeIntervalSince(now)
    guard remaining > 0, remaining <= announceLead + 1 else { return nil }
    return max(1, Int((remaining / 60).rounded()))
  }
}

/// Reads the next event from EventKit. No polling: `EKEventStoreChanged`
/// plus a single one-shot task until the next boundary (DESIGN.md §2.1).
@MainActor
final class CalendarSource {
  private let resources: ResourceBag
  private let onChange: (UpcomingEvent?) -> Void
  private var store: EKEventStore?
  private var tokens: [ResourceBag.Token] = []
  private var refreshToken: ResourceBag.Token?

  static var access: CalendarAccess {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: .granted
    case .notDetermined: .notDetermined
    default: .denied
    }
  }

  init(resources: ResourceBag, onChange: @escaping (UpcomingEvent?) -> Void) {
    self.resources = resources
    self.onChange = onChange
  }

  /// Does nothing until access is granted: no prompt starts from here.
  func start() {
    guard store == nil, Self.access == .granted else { return }
    let store = EKEventStore()
    self.store = store
    let workspace = NSWorkspace.shared.notificationCenter
    tokens = [
      resources.addObserver(.EKEventStoreChanged, object: store) { [weak self] in self?.refresh() },
      resources.addObserver(NSWorkspace.didWakeNotification, center: workspace) { [weak self] in self?.refresh() },
    ]
    refresh()
  }

  func stop() {
    for token in tokens { resources.cancel(token) }
    tokens = []
    if let refreshToken { resources.cancel(refreshToken) }
    refreshToken = nil
    store = nil
  }

  func refresh() {
    guard let store else { return }
    let now = Date()
    let predicate = store.predicateForEvents(
      withStart: now.addingTimeInterval(-CalendarLogic.graceAfterStart),
      end: now.addingTimeInterval(CalendarLogic.lookAhead),
      calendars: nil
    )
    let events = store.events(matching: predicate).filter { !$0.isAllDay && $0.status != .canceled }.map { event in
      UpcomingEvent(
        id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
        title: event.title ?? "",
        start: event.startDate,
        end: event.endDate,
        joinURL: CalendarLogic.joinURL(in: [event.url?.absoluteString, event.location, event.notes])
      )
    }
    let next = CalendarLogic.next(from: events, now: now)
    schedule(at: CalendarLogic.nextRefresh(for: next, now: now), from: now)
    onChange(next)
  }

  private func schedule(at date: Date, from now: Date) {
    if let refreshToken { resources.cancel(refreshToken) }
    let delay = max(1, date.timeIntervalSince(now))
    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(max(1, min(delay / 10, 60))))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
    refreshToken = resources.addTask(task)
  }
}
