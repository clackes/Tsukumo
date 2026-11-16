// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import ModuleKit
import Observation
import SwiftUI

/// Mac audio (DESIGN.md §2.4.1), phase 1: quick output switching and blocking
/// of Music. Menu bar item with popover; the Core Audio listeners and
/// the launch observer live in the `ResourceBag`, so when off there is nothing.
///
/// Planned extension: per-app volume and output with process taps (spike 27)
/// will come in here as a second service, started in `start()` only if needed.
@MainActor
public final class SoundModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "sound",
    nameKey: "Sound",
    symbol: "speaker.wave.2",
    tint: .pink,
    permissions: [],
    energyClass: .zero
  )

  private static let statusItemName = "tsukumo.sound"

  private let context: ModuleContext
  private let settingsModel = SoundSettingsModel()
  private var audio: SoundModel?
  private var blocker: MusicBlocker?
  private var statusItem: StatusItemSurface?
  private var popover: StatusPopover?

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    let prefs: SoundPrefs = context.settings.value(forKey: "prefs", moduleID: Self.descriptor.id) ?? SoundPrefs()
    settingsModel.prefs = prefs

    let backend = CoreAudioBackend()
    // The writable mixer exists only since 14.4 (public process taps). Tsukumo's
    // target is 26.0, so it is always available at runtime; the
    // `#available` is for the compiler because `ProcessTap` requires it.
    let mixer: (any ProcessVolumeController)?
    if #available(macOS 14.4, *) {
      mixer = CoreAudioProcessVolume { [weak backend] in
        guard let backend, let id = backend.defaultOutputID() else { return nil }
        return backend.outputUID(of: id)
      }
    } else {
      mixer = nil
    }
    let audio = SoundModel(backend: backend, mixer: mixer)
    audio.includeSystemEffects = prefs.includeSystemEffects
    audio.refresh()
    self.audio = audio
    if let mixer {
      // The controller holds the taps: tearing it down frees aggregate devices and IOProcs.
      context.resources.add(.observer) { mixer.tearDown() }
    }

    let surface = context.surfaces.makeStatusItem(
      autosaveName: Self.statusItemName,
      content: Self.content(for: audio),
      moduleID: context.moduleID,
      in: context.resources
    )
    statusItem = surface
    if let button = surface.item?.button { installPopover(on: button, audio: audio) }

    let stopObserving = backend.observe { [weak self] change in self?.audioChanged(change) }
    context.resources.add(.observer, cancel: stopObserving)

    // After unlock and wake the mixer's aggregates may stay stopped:
    // they are recreated. Notifications only, no timer.
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      nonisolated(unsafe) let token = workspace.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.audio?.rebuildMixer() } }
      context.resources.add(.observer) { workspace.removeObserver(token) }
    }
    nonisolated(unsafe) let unlock = distributed.addObserver(
      forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.audio?.rebuildMixer() } }
    context.resources.add(.observer) { distributed.removeObserver(unlock) }

    blocker = MusicBlocker(resources: context.resources, prefs: prefs)
    settingsModel.onChange = { [weak self] prefs in self?.apply(prefs) }
  }

  private func installPopover(on button: NSStatusBarButton, audio: SoundModel) {
    let popover = StatusPopover(button: button) { AnyView(SoundPopoverView(model: audio)) }
    popover.onVisibilityChange = { [weak audio] open in
      audio?.isPresented = open
      if open { audio?.refresh() }
    }
    self.popover = popover
    context.resources.add(.window) { popover.invalidate() }
  }

  public func stop() async {
    settingsModel.onChange = nil
    blocker = nil
    popover = nil
    statusItem = nil
    audio = nil
  }

  public var settings: AnyView { AnyView(SoundSettingsView(model: settingsModel)) }

  private func audioChanged(_ change: AudioChange) {
    guard let audio else { return }
    audio.handle(change)
    statusItem?.updateIfChanged(Self.content(for: audio))
  }

  private func apply(_ prefs: SoundPrefs) {
    try? context.settings.set(prefs, forKey: "prefs", moduleID: Self.descriptor.id)
    audio?.includeSystemEffects = prefs.includeSystemEffects
    blocker?.update(prefs: prefs)
  }

  private static func content(for audio: SoundModel) -> StatusItemContent {
    StatusItemContent(symbol: audio.statusSymbol, accessibilityLabel: String(localized: "Sound"))
  }
}
