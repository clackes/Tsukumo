// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import ModuleKit

// MARK: - Locked screen

extension IslandModule {
  /// How long the open lock stays visible before the island returns to rest.
  static let unlockDuration: Duration = .milliseconds(1100)
  /// Wait before opening the lock: the lock screen must have finished fading away,
  /// otherwise the animation shows through the fade.
  static let unlockDelay: Duration = .milliseconds(550)
  static let hudDuration: Duration = .milliseconds(1400)

  func setLockEnabled(_ value: Bool) {
    guard let model, model.lockEnabled != value else { return }
    model.lockEnabled = value
    try? context.settings.set(value, forKey: "lockEnabled", moduleID: Self.descriptor.id)
    if value {
      startLockObservers()
    } else {
      if !needsLockObservers { stopLockObservers() }
      if case .lock = model.activity { clearActivity() }
    }
  }

  /// Music and lyrics on the lock screen: private SkyLight, hence opt-in.
  func setLockMediaEnabled(_ value: Bool) {
    guard let model, model.lockMediaEnabled != value else { return }
    model.lockMediaEnabled = value
    try? context.settings.set(value, forKey: "lockMediaEnabled", moduleID: Self.descriptor.id)
    if value {
      startLockObservers()
    } else {
      if !needsLockObservers { stopLockObservers() }
      lockMedia?.close()
    }
    // The lock screen lyrics also depend on this checkbox.
    lyricsNeedChanged()
  }

  /// Artwork as lock screen background: takes effect from the next update.
  func setLockBackdropEnabled(_ value: Bool) {
    guard let model, model.lockBackdropEnabled != value else { return }
    model.lockBackdropEnabled = value
    try? context.settings.set(value, forKey: "lockBackdropEnabled", moduleID: Self.descriptor.id)
    lockMedia?.refresh(locked: isScreenLocked)
  }

  /// Text next to the player: changes the window width, which is rebuilt.
  func setLockLyricsEnabled(_ value: Bool) {
    guard let model, model.lockLyricsEnabled != value else { return }
    model.lockLyricsEnabled = value
    try? context.settings.set(value, forKey: "lockLyricsEnabled", moduleID: Self.descriptor.id)
    lyricsNeedChanged()
    lockMedia?.relayout()
  }

  func stopLockObservers() {
    for token in lockTokens { context.resources.cancel(token) }
    lockTokens = []
    isScreenLocked = false
    lockMedia?.close()
    panel?.attachesToLockScreen = false
  }

  /// Lock and unlock serve the lock, the player and the island on the lock screen.
  var needsLockObservers: Bool {
    guard let model else { return false }
    return model.lockEnabled || model.lockMediaEnabled || model.lockScreenEnabled
  }

  /// The island enters the lock screen's Space only while the screen is locked.
  func updateLockScreenSpace(locked: Bool) {
    if locked, let lockSpaceToken {
      context.resources.cancel(lockSpaceToken)
      self.lockSpaceToken = nil
    }
    panel?.attachesToLockScreen = locked && model?.lockScreenEnabled == true
  }

  /// After unlock the island returns to the normal Space, with the lock open: so
  /// the transition is not visible while the lock screen fades away.
  private func leaveLockScreenSpace(after delay: Duration) {
    if let lockSpaceToken { context.resources.cancel(lockSpaceToken) }
    guard delay > .zero else {
      lockSpaceToken = nil
      updateLockScreenSpace(locked: false)
      return
    }
    let task = Task { [weak self] in
      try? await Task.sleep(for: delay, tolerance: .milliseconds(100))
      guard !Task.isCancelled, let self, !self.isScreenLocked else { return }
      self.lockSpaceToken = nil
      self.updateLockScreenSpace(locked: false)
    }
    lockSpaceToken = context.resources.addTask(task)
  }

  /// Showing the island on the lock screen uses SkyLight (private): it is opt-in.
  func setLockScreenEnabled(_ value: Bool) {
    guard let model, model.lockScreenEnabled != value else { return }
    model.lockScreenEnabled = value
    try? context.settings.set(value, forKey: "lockScreenEnabled", moduleID: Self.descriptor.id)
    if value {
      startLockObservers()
    } else if !needsLockObservers {
      stopLockObservers()
    }
    updateLockScreenSpace(locked: isScreenLocked)
    update()
  }

  /// Lock and unlock arrive as distributed notifications: no polling.
  func startLockObservers() {
    guard lockTokens.isEmpty else { return }
    let center = DistributedNotificationCenter.default()
    lockTokens = [
      context.resources.addObserver(Notification.Name("com.apple.screenIsLocked"), center: center) { [weak self] in
        guard let self else { return }
        self.isScreenLocked = true
        self.updateLockScreenSpace(locked: true)
        if self.model?.lockEnabled == true { self.show(.lock(isLocked: true), for: nil) }
        self.lockMedia?.refresh(locked: true)
      },
      context.resources.addObserver(Notification.Name("com.apple.screenIsUnlocked"), center: center) { [weak self] in
        guard let self else { return }
        self.lockMedia?.refresh(locked: false)
        if self.model?.lockEnabled == true {
          self.playUnlock()
          self.leaveLockScreenSpace(after: Self.unlockDelay + Self.unlockDuration)
        } else {
          self.isScreenLocked = false
          self.leaveLockScreenSpace(after: .zero)
        }
      },
    ]
  }

  /// Unlock: the lock stays closed until the lock screen fades away,
  /// then it opens and the island returns to rest.
  func playUnlock() {
    guard let model else { return }
    isScreenLocked = false
    if model.activity != .lock(isLocked: true) { show(.lock(isLocked: true), for: nil) }
    if let activityToken { context.resources.cancel(activityToken) }
    let task = Task { [weak self] in
      try? await Task.sleep(for: Self.unlockDelay, tolerance: .milliseconds(50))
      guard !Task.isCancelled else { return }
      self?.show(.lock(isLocked: false), for: Self.unlockDuration)
    }
    activityToken = context.resources.addTask(task)
  }
}

// MARK: - Music indicator

extension IslandModule {
  /// Wave, colored bars or still symbol next to the artwork while playing.
  func setPlaybackIndicator(_ value: IslandPlaybackIndicator) {
    guard let model, model.playbackIndicator != value else { return }
    model.playbackIndicator = value
    try? context.settings.set(value, forKey: "playbackIndicator", moduleID: Self.descriptor.id)
  }
}

// MARK: - Volume and brightness HUD

extension IslandModule {
  /// Rereads the permissions the HUD needs. Does not make prompts appear.
  func refreshHUDPermissions() {
    guard let model else { return }
    model.hudAccessibility = AXIsProcessTrusted()
    model.hudInputMonitoring = CGPreflightListenEventAccess()
    // A permission just granted can unblock the tap without touching the switch.
    if model.hudEnabled, hudTapToken == nil { startHUD() }
  }

  /// Requests start only from these two buttons in Settings.
  func requestHUDAccessibility() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    refreshHUDPermissions()
  }

  func requestHUDInputMonitoring() {
    _ = CGRequestListenEventAccess()
    refreshHUDPermissions()
  }

  func setHUDEnabled(_ value: Bool) {
    guard let model, model.hudEnabled != value else { return }
    model.hudEnabled = value
    try? context.settings.set(value, forKey: "hudEnabled", moduleID: Self.descriptor.id)
    if value {
      startHUD()
    } else {
      if let hudTapToken { context.resources.cancel(hudTapToken) }
      hudTapToken = nil
      if let hudScreenToken { context.resources.cancel(hudScreenToken) }
      hudScreenToken = nil
      hudPolicy.set(HUDPolicy.State())
      model.hudTapFailed = false
      if model.activity?.isHUD == true { clearActivity() }
    }
  }

  /// Intercepts the volume and brightness keys with the shared active tap. Without
  /// Accessibility it does not even try: the keys stay with the system.
  func startHUD() {
    guard let model, hudTapToken == nil else { return }
    model.hudAccessibility = AXIsProcessTrusted()
    model.hudInputMonitoring = CGPreflightListenEventAccess()
    guard model.hudAccessibility else {
      model.hudTapFailed = false
      return
    }
    refreshHUDPolicy()
    let policy = hudPolicy
    let mask = CGEventMask(1) << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
    do {
      let subscription = try context.inputTaps.subscribe(.active, mask: mask) { [weak self] _, event in
        // Tap thread: it only decides whether to consume; the work goes to main.
        guard let nsEvent = NSEvent(cgEvent: event),
          let press = MediaKeyPress.parse(
            subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1, modifiers: nsEvent.modifierFlags
          ),
          policy.handles(press)
        else { return event }
        if press.isDown {
          Task { @MainActor in self?.handle(press) }
        }
        return nil
      }
      hudTapToken = context.resources.addInputTap(subscription)
      model.hudTapFailed = false
      let screenChanged: @MainActor () -> Void = { [weak self] in self?.refreshHUDPolicy() }
      hudScreenToken = context.resources.addObserver(
        NSApplication.didChangeScreenParametersNotification, handler: screenChanged)
    } catch {
      hudPolicy.set(HUDPolicy.State())
      model.hudTapFailed = true
    }
  }

  /// We handle only what we know how to adjust: an audio output with volume and the built-in display.
  func refreshHUDPolicy() {
    guard model?.hudEnabled == true else { return }
    let volume = AudioVolume.defaultDevice().map(AudioVolume.canSetVolume) ?? false
    hudPolicy.set(HUDPolicy.State(volume: volume, brightness: DisplayBrightness.builtInDisplay() != nil))
  }

  private func handle(_ press: MediaKeyPress) {
    guard model?.hudEnabled == true else { return }
    switch press.key {
    case .soundUp, .soundDown, .mute:
      guard let device = AudioVolume.defaultDevice(), let current = AudioVolume.volume(device) else {
        // The device changed under us: from the next key the system decides again.
        refreshHUDPolicy()
        return
      }
      var muted = AudioVolume.isMuted(device)
      var level = current
      if press.key == .mute {
        muted.toggle()
      } else {
        level = HUDMath.stepped(current, up: press.key == .soundUp, fine: press.fine)
        AudioVolume.setVolume(level, device: device)
        // Raising the volume removes the mute, as the system does.
        if press.key == .soundUp { muted = false }
        // At zero the slider is not enough: many outputs (built-in speakers
        // included) still play quietly. Zero is a real mute.
        if level <= 0 { muted = true }
      }
      AudioVolume.setMuted(muted, device: device)
      show(.hud(kind: .volume, level: level, muted: muted), for: Self.hudDuration)
    case .brightnessUp, .brightnessDown:
      guard let display = DisplayBrightness.builtInDisplay(), let current = DisplayBrightness.get(display) else {
        refreshHUDPolicy()
        return
      }
      // When held down, each repeat starts from the target level, not from the mid-ramp one.
      let level = HUDMath.stepped(brightnessTarget ?? current, up: press.key == .brightnessUp, fine: press.fine)
      rampBrightness(from: current, to: level, display: display)
      show(.hud(kind: .brightness, level: level, muted: false), for: Self.hudDuration)
    }
  }

  /// Brings the brightness to the new level in small steps, as the system does:
  /// a sharp jump of one sixteenth shows as a jolt.
  private func rampBrightness(from start: Float, to target: Float, display: CGDirectDisplayID) {
    if let brightnessRampToken { context.resources.cancel(brightnessRampToken) }
    brightnessTarget = target
    let task = Task { [weak self] in
      for step in 1...HUDMath.rampSteps {
        guard !Task.isCancelled else { return }
        DisplayBrightness.set(HUDMath.ramp(from: start, to: target, step: step), display: display)
        try? await Task.sleep(for: .milliseconds(12))
      }
      guard !Task.isCancelled else { return }
      self?.brightnessRampFinished()
    }
    brightnessRampToken = context.resources.addTask(task)
  }

  private func brightnessRampFinished() {
    if let brightnessRampToken { context.resources.cancel(brightnessRampToken) }
    brightnessRampToken = nil
    brightnessTarget = nil
  }
}
