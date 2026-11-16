// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import EventKit
import ModuleKit
import SwiftUI

/// Island on the notch: charging, playing track and controls.
///
/// At rest nothing runs: the collapsed panel is black and static, the mouse
/// is detected with an `NSTrackingArea`, battery and track arrive via events.
@MainActor
public final class IslandModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "island",
    nameKey: "Island",
    symbol: "capsule.tophalf.filled",
    tint: .indigo,
    energyClass: .zero
  )

  static let activityDuration: Duration = .seconds(3)
  static let eventActivityDuration: Duration = .seconds(8)

  public private(set) var model: IslandModel?
  let context: ModuleContext
  var panel: IslandPanelController?
  var lockMedia: LockMediaController?
  private var media: (any MediaBackend)?
  var activityToken: ResourceBag.Token?
  var lockTokens: [ResourceBag.Token] = []
  /// The screen is locked: when another activity ends, the closed lock returns.
  var isScreenLocked = false
  /// Return of the island to the normal Space after unlock.
  var lockSpaceToken: ResourceBag.Token?
  var hudTapToken: ResourceBag.Token?
  /// Observer of the HUD's screen changes: lives and dies with the tap.
  var hudScreenToken: ResourceBag.Token?
  let hudPolicy = HUDPolicy()
  var brightnessRampToken: ResourceBag.Token?
  /// Level toward which the brightness is heading: repeated keys start from here.
  var brightnessTarget: Float?
  private var isOpen = false
  private var shelfMonitor: ShelfDragMonitor?
  private var calendar: CalendarSource?
  private var announcedEventID: String?
  var musicScript: MusicScriptBridge?
  var favoriteToken: ResourceBag.Token?
  private var artworkToken: ResourceBag.Token?
  var artworkKey: String?
  /// Clears the previous track's artwork if the new one never arrives.
  var artworkClearToken: ResourceBag.Token?
  var lyricsProvider: LyricsProvider?
  var lyrics: [LyricLine] = []
  var lyricsQuery: LyricsQuery?
  var lyricsFetchToken: ResourceBag.Token?
  var lyricsTickToken: ResourceBag.Token?

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    let model = IslandModel()
    self.model = model
    let id = Self.descriptor.id
    // The old boolean preference counts as the initial choice.
    let legacyHover: Bool = context.settings.value(forKey: "expandOnHover", moduleID: id) ?? true
    model.activation = context.settings.value(forKey: "activation", moduleID: id) ?? (legacyHover ? .hover : .click)
    model.lyricsEnabled = context.settings.value(forKey: "lyricsEnabled", moduleID: id) ?? false
    model.showCharging = context.settings.value(forKey: "showCharging", moduleID: id) ?? true
    model.showTrackChanges = context.settings.value(forKey: "showTrackChanges", moduleID: id) ?? true
    model.lockEnabled = context.settings.value(forKey: "lockEnabled", moduleID: id) ?? true
    model.lockScreenEnabled = context.settings.value(forKey: "lockScreenEnabled", moduleID: id) ?? false
    model.lockMediaEnabled = context.settings.value(forKey: "lockMediaEnabled", moduleID: id) ?? false
    model.lockLyricsEnabled = context.settings.value(forKey: "lockLyricsEnabled", moduleID: id) ?? false
    model.lockBackdropEnabled = context.settings.value(forKey: "lockBackdropEnabled", moduleID: id) ?? false
    model.hudEnabled = context.settings.value(forKey: "hudEnabled", moduleID: id) ?? false
    model.haloEnabled = context.settings.value(forKey: "haloEnabled", moduleID: id) ?? false
    model.playbackIndicator = context.settings.value(forKey: "playbackIndicator", moduleID: id) ?? .waveform
    model.shelfEnabled = context.settings.value(forKey: "shelfEnabled", moduleID: id) ?? true
    model.shelf = Shelf.items(from: context.settings.value(forKey: "shelf", moduleID: id) ?? [])

    let actions = IslandActions(
      tap: { [weak self] in self?.tapped() },
      send: { [weak self] command in self?.media?.send(command) },
      removeFromShelf: { [weak self] id in self?.removeFromShelf(id) },
      airDropAll: { [weak self] in Shelf.airDrop(self?.model?.shelf.map(\.url) ?? []) },
      seek: { [weak self] seconds in self?.seek(to: seconds) },
      toggleFavorite: { [weak self] in self?.toggleFavorite() }
    )
    let panel = IslandPanelController(model: model, actions: actions, resources: context.resources)
    lockMedia = LockMediaController(model: model, actions: actions, resources: context.resources)
    panel.onHover = { [weak self] inside in self?.hoverChanged(inside) }
    self.panel = panel
    if model.shelfEnabled { startShelf() }
    context.resources.addObserver(NSApplication.didChangeScreenParametersNotification) { [weak self, weak panel] in
      panel?.relayout()
      self?.lockMedia?.relayout()
    }

    model.power = PowerStatus.current()
    PowerObserver.install(in: context.resources) { [weak self] in self?.powerChanged() }

    startMedia()

    model.artworkEnabled = context.settings.value(forKey: "artworkEnabled", moduleID: id) ?? false
    if model.artworkEnabled { startArtwork() }

    if needsLockObservers { startLockObservers() }
    if model.hudEnabled { startHUD() }

    model.calendarEnabled = context.settings.value(forKey: "calendarEnabled", moduleID: id) ?? false
    model.calendarAccess = CalendarSource.access
    if model.calendarEnabled { startCalendar() }
  }

  public func stop() async {
    activityToken = nil
    lockTokens = []
    hudTapToken = nil
    hudScreenToken = nil
    brightnessRampToken = nil
    brightnessTarget = nil
    hudPolicy.set(HUDPolicy.State())
    shelfMonitor = nil
    calendar = nil
    announcedEventID = nil
    musicScript = nil
    artworkToken = nil
    artworkKey = nil
    artworkClearToken = nil
    lyricsProvider?.invalidate()
    lyricsProvider = nil
    lyrics = []
    lyricsQuery = nil
    lyricsFetchToken = nil
    lyricsTickToken = nil
    media = nil
    panel?.close()  // the bag entry holds a weak reference: with `panel = nil` it would never fire
    panel = nil
    lockMedia?.close()
    lockMedia = nil
    isScreenLocked = false
    lockSpaceToken = nil
    model = nil
    isOpen = false
  }

  public var settings: AnyView {
    AnyView(IslandSettingsView(model: model, module: self))
  }

  public var health: ModuleHealth {
    get async {
      MediaRemoteBridge.isAvailable ? .ok : .degraded("MRMediaRemoteSendCommand unavailable")
    }
  }
}

// MARK: - Preferences and optional sources

extension IslandModule {

  func setActivation(_ value: IslandActivation) {
    model?.activation = value
    try? context.settings.set(value, forKey: "activation", moduleID: Self.descriptor.id)
  }

  func setHaloEnabled(_ value: Bool) {
    model?.haloEnabled = value
    try? context.settings.set(value, forKey: "haloEnabled", moduleID: Self.descriptor.id)
    panel?.refreshHalo()
  }

  func setShowCharging(_ value: Bool) {
    model?.showCharging = value
    try? context.settings.set(value, forKey: "showCharging", moduleID: Self.descriptor.id)
  }

  func setShowTrackChanges(_ value: Bool) {
    model?.showTrackChanges = value
    try? context.settings.set(value, forKey: "showTrackChanges", moduleID: Self.descriptor.id)
  }

  func setShelfEnabled(_ value: Bool) {
    guard let model, model.shelfEnabled != value else { return }
    model.shelfEnabled = value
    try? context.settings.set(value, forKey: "shelfEnabled", moduleID: Self.descriptor.id)
    if value {
      startShelf()
    } else {
      shelfMonitor?.invalidate()
      shelfMonitor = nil
      panel?.onDrop = nil
      panel?.onDragMove = nil
      model.isDragging = false
      model.dragOverAirDrop = false
    }
    update()
  }

  /// Turning on the artwork is the only point from which the Automation request starts.
  func setArtworkEnabled(_ value: Bool) {
    guard let model, model.artworkEnabled != value else { return }
    model.artworkEnabled = value
    try? context.settings.set(value, forKey: "artworkEnabled", moduleID: Self.descriptor.id)
    if value {
      startArtwork()
    } else {
      if let artworkToken { context.resources.cancel(artworkToken) }
      artworkToken = nil
      musicScript = nil
      artworkKey = nil
      setArtwork(nil, track: "")
      model.artworkDenied = false
    }
  }

  private func startArtwork() {
    musicScript = MusicScriptBridge()
    // Initial state: notifications arrive only at the next track change.
    if MusicScriptBridge.isMusicRunning { fetchMusicSnapshot(adoptTrack: true) }
  }

  /// An Apple Event to Music, off the main thread. `adoptTrack` uses the response
  /// also as the current track (at launch, when there is no notification yet).
  func fetchMusicSnapshot(adoptTrack: Bool) {
    guard let musicScript else { return }
    if let artworkToken { context.resources.cancel(artworkToken) }
    let task = Task { [weak self] in
      let result = await musicScript.snapshot()
      guard !Task.isCancelled else { return }
      self?.musicSnapshotArrived(result, adoptTrack: adoptTrack)
    }
    artworkToken = context.resources.addTask(task)
  }

  private func musicSnapshotArrived(_ result: MusicScriptResult, adoptTrack: Bool) {
    if let artworkToken { context.resources.cancel(artworkToken) }
    artworkToken = nil
    guard let model, model.artworkEnabled else { return }
    model.artworkDenied = result == .denied
    guard case .snapshot(let snapshot) = result else { return }
    if adoptTrack, model.media == nil {
      model.media = snapshot.nowPlaying(at: Date())
      artworkKey = Self.trackKey(snapshot.title, snapshot.album)
    }
    // Meanwhile the track may have changed: the artwork is valid only for its own.
    guard let media = model.media, media.bundleID == MediaSource.music.rawValue, media.title == snapshot.title
    else { return }
    setArtwork(snapshot.artwork.flatMap { NSImage(data: $0) }, track: Self.trackKey(snapshot.title, snapshot.album))
    // The position read from Music counts more than the one estimated from notifications.
    model.media?.position = snapshot.position
    model.media?.updatedAt = Date()
    updateLyrics()
  }

  static func trackKey(_ title: String, _ album: String) -> String { "\(title)\u{1F}\(album)" }

  /// Turning on the calendar is the only point from which the access request starts.
  func setCalendarEnabled(_ value: Bool) {
    guard let model, model.calendarEnabled != value else { return }
    model.calendarEnabled = value
    try? context.settings.set(value, forKey: "calendarEnabled", moduleID: Self.descriptor.id)
    guard value else {
      calendar?.stop()
      calendar = nil
      model.nextEvent = nil
      update()
      return
    }
    guard CalendarSource.access == .notDetermined else {
      startCalendar()
      return
    }
    let task = Task { [weak self] in
      _ = try? await EKEventStore().requestFullAccessToEvents()
      guard !Task.isCancelled else { return }
      self?.startCalendar()
    }
    context.resources.addTask(task)
  }

  private func startCalendar() {
    guard let model, model.calendarEnabled else { return }
    model.calendarAccess = CalendarSource.access
    guard calendar == nil, model.calendarAccess == .granted else { return }
    let source = CalendarSource(resources: context.resources) { [weak self] event in self?.eventChanged(event) }
    calendar = source
    source.start()
  }

  private func eventChanged(_ event: UpcomingEvent?) {
    guard let model else { return }
    model.nextEvent = event
    update()
    guard let event, event.id != announcedEventID,
      let minutes = CalendarLogic.minutesUntilStart(of: event, now: Date())
    else { return }
    announcedEventID = event.id
    show(.event(title: event.title, minutes: minutes), for: Self.eventActivityDuration)
  }
}

// MARK: - Shelf

extension IslandModule {

  private func startShelf() {
    panel?.onDragMove = { [weak self] point in self?.dragMoved(point) }
    panel?.onDrop = { [weak self] urls, point in self?.dropped(urls, at: point) ?? false }
    shelfMonitor = ShelfDragMonitor(
      resources: context.resources,
      hotZone: { [weak self] in IslandGeometry.hotZone(notch: self?.model?.notch.rect ?? .zero) },
      onEnter: { [weak self] in self?.setDragging(true) },
      onEnd: { [weak self] in self?.dragEnded() }
    )
  }

  /// A dragged file opens the island; at the end it stays open only if the pointer is over it.
  private func setDragging(_ dragging: Bool) {
    guard let model else { return }
    model.isDragging = dragging
    if dragging {
      isOpen = true
    } else {
      model.dragOverAirDrop = false
    }
    update()
  }

  private func dragMoved(_ point: CGPoint?) {
    guard let model, let panel else { return }
    guard let point else {
      setDragging(false)
      isOpen = false
      update()
      return
    }
    if !model.isDragging { setDragging(true) }
    let overAirDrop = model.showsShelf && IslandGeometry.isAirDropZone(point, in: panel.size)
    if overAirDrop != model.dragOverAirDrop { model.dragOverAirDrop = overAirDrop }
  }

  private func dragEnded() {
    guard let model, model.isDragging else { return }
    let inside = panel?.frame?.contains(NSEvent.mouseLocation) ?? false
    setDragging(false)
    if !inside {
      isOpen = false
      update()
    }
  }

  private func dropped(_ urls: [URL], at point: CGPoint) -> Bool {
    guard let model, let panel else { return false }
    let toAirDrop = IslandGeometry.isAirDropZone(point, in: panel.size)
    if toAirDrop {
      Shelf.airDrop(urls)
    } else {
      model.shelf = Shelf.adding(urls, to: model.shelf)
      saveShelf()
    }
    setDragging(false)
    return true
  }

  private func removeFromShelf(_ id: UUID) {
    guard let model else { return }
    model.shelf.removeAll { $0.id == id }
    saveShelf()
    update()
  }

  private func saveShelf() {
    guard let model else { return }
    try? context.settings.set(Shelf.bookmarks(for: model.shelf), forKey: "shelf", moduleID: Self.descriptor.id)
  }
}

// MARK: - Events

extension IslandModule {

  private func hoverChanged(_ inside: Bool) {
    guard let model else { return }
    if inside {
      guard model.activation == .hover else { return }
      isOpen = true
    } else {
      isOpen = false
    }
    update()
  }

  private func tapped() {
    guard !isOpen else { return }
    isOpen = true
    update()
  }

  private func powerChanged() {
    guard let model else { return }
    let old = model.power
    let new = PowerStatus.current()
    guard new != old else { return }
    model.power = new
    if new.isPluggedIn, !old.isPluggedIn, model.showCharging {
      show(.charging(percent: new.percent))
    }
  }

  /// Backend 1 (mediaremote-adapter) if the app contains it, otherwise backend 2.
  /// If the adapter process dies, switch to backend 2 without retrying.
  private func startMedia() {
    guard let model else { return }
    if let payload = AdapterMediaBackend.Payload.inMainBundle() {
      let adapter = AdapterMediaBackend(payload: payload) { [weak self] in self?.fallBackToNotifications() }
      media = adapter
      adapter.start(in: context.resources) { [weak self] playing in self?.mediaChanged(playing) }
      // If startup failed the fallback has already set `canSendCommands`.
      if media === adapter {
        model.canSendCommands = adapter.canSendCommands
        return
      }
    }
    fallBackToNotifications()
  }

  private func fallBackToNotifications() {
    guard let model, !(media is NotificationMediaBackend) else { return }
    let backend = NotificationMediaBackend()
    media = backend
    model.canSendCommands = backend.canSendCommands
    backend.start(in: context.resources) { [weak self] playing in self?.mediaChanged(playing) }
    // The adapter is dead: what it showed is no longer reliable. Without this
    // the track would stay "playing" until a notification arrives.
    if model.media != nil { mediaChanged(nil) }
  }

  /// Seek in the track: the bar moves immediately, the confirmation comes from the backend.
  private func seek(to seconds: TimeInterval) {
    guard let model, var current = model.media, media?.seek(to: seconds) == true else { return }
    current.position = seconds
    current.updatedAt = Date()
    model.media = current
  }

  private func mediaChanged(_ playing: NowPlaying?) {
    guard let model else { return }
    let previousTitle = model.media?.title
    model.media = Self.withEstimatedPosition(playing, previous: model.media)
    updateArtwork(for: playing)
    if playing?.title != previousTitle { refreshFavorite() }
    updateLyrics()
    lockMedia?.refresh(locked: isScreenLocked)
    if let playing, playing.isPlaying, playing.title != previousTitle, model.showTrackChanges {
      show(.track(title: playing.title))
    } else {
      update()
    }
  }

  func update() {
    guard let model else { return }
    alignRestingActivity()
    let presentation = IslandGeometry.presentation(
      isOpen: isOpen, activity: model.activity, hasNotch: model.notch.isPhysical, showsLyrics: model.showsLyrics
    )
    model.presentation = presentation
    panel?.apply(presentation)
  }
}
