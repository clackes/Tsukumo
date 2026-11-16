// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ModuleKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let model = AppModel()
  private var statusItem: StatusItemController?
  private var settingsWindow: SettingsWindowController?
  private var onboardingWindow: OnboardingWindowController?
  private let onboardingStore = OnboardingStore()
  private var isTerminating = false
  private let router = IntentRouter()
  private let log = Logger(subsystem: "dev.local.tsukumo", category: "intents")
  private var quitKeyMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Default AX timeout for the whole process (on the system-wide element):
    // a hung app does not block Tsukumo for macOS's default ~6 s. Modules still
    // set shorter timeouts on their own elements.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
    installQuitKeyMonitor()
    model.registerModules()
    statusItem = StatusItemController(model: model, isVisible: model.showsMenuBarIcon) { [weak self] in
      self?.showSettings()
    }
    model.onMenuBarIconVisibilityChange = { [weak self] visible in
      self?.statusItem?.setVisible(visible)
    }
    model.onReviewPermissions = { [weak self] in self?.reviewPermissions() }
    Task { await model.restoreEnabledModules() }
    showOnboardingIfNeeded()
  }

  /// Onboarding on first launch (DESIGN.md §6.1): preset choice, then all
  /// permissions on a single page. The chosen modules start at the end; those
  /// still missing a permission stay "to be turned on" and restart on their own
  /// at the next launch once the permission is granted.
  private func showOnboardingIfNeeded() {
    guard onboardingStore.load().shouldShow else { return }
    showOnboarding(startingAt: .presets)
  }

  /// From Settings: reopens only the permissions page.
  private func reviewPermissions() {
    showOnboarding(startingAt: .permissions)
  }

  private func showOnboarding(startingAt step: OnboardingWindowController.Step) {
    let isFirstRun = step == .presets
    onboardingWindow = OnboardingWindowController(model: model) { [weak self] outcome in
      guard let self else { return }
      self.onboardingWindow = nil
      if isFirstRun {
        var state = self.onboardingStore.load()
        state.markCompleted(presetID: outcome.preset?.id)
        self.onboardingStore.save(state)
        self.model.setShowsMenuBarIcon(true)
      }
      Task { @MainActor in
        for id in outcome.preset?.moduleIDs ?? [] {
          await self.model.setEnabled(true, id: id)
        }
        if outcome.needsRestart {
          // Turned-on modules are already saved: at relaunch they restart with valid permissions.
          do { try LocalAppRelauncher.restart() } catch { NSApp.presentError(error) }
        } else if !isFirstRun {
          // Permissions granted without a relaunch: modules left waiting retry.
          await self.model.retryBlockedModules()
        }
      }
    }
    onboardingWindow?.show(startingAt: step)
  }

  /// ⌘Q closes the frontmost window (Settings, onboarding) and leaves
  /// Tsukumo running in the menu bar with all its modules: it is a background
  /// app. You only really quit from "Quit Tsukumo" in the panel. Local
  /// monitor: it only sees keys pressed in Tsukumo's own windows.
  private func installQuitKeyMonitor() {
    quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
      MainActor.assumeIsolated {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
          window.performClose(nil)
        }
      }
      return nil
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // A second request during teardown (repeated ⌘Q, signal) must not
    // quit right away: the reply arrives when `disableAll()` has finished.
    if isTerminating { return .terminateLater }
    guard model.registry.liveCount > 0 else { return .terminateNow }
    isTerminating = true
    Task {
      await model.registry.disableAll()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// `tsukumo://` scheme: it is not authenticated, so the `IntentRouter` decides
  /// (DESIGN.md §4.3.1). Anything that changes state asks for confirmation in the foreground.
  func application(_ application: NSApplication, open urls: [URL]) {
    let known = Set(model.registry.entries.map(\.descriptor.id))
    for url in urls {
      switch router.decide(url, knownModuleIDs: known) {
      case .execute(let action):
        perform(action)
      case .confirm(let action):
        // Outside the Apple Event handler: the confirmation starts on the next run-loop turn.
        Task {
          if confirm(action) { perform(action) }
        }
      case .reject(let reason):
        log.notice("URL rejected (\(reason.rawValue, privacy: .public))")
      }
    }
  }

  private func perform(_ action: IntentAction) {
    switch action {
    case .openSettings:
      showSettings()
    case .openModuleSettings(let id):
      model.settingsPage = .module(id)
      showSettings()
    case .setModuleEnabled(let id, let enabled):
      Task { await model.setEnabled(enabled, id: id) }
    }
  }

  private func confirm(_ action: IntentAction) -> Bool {
    guard case .setModuleEnabled(let id, let enabled) = action,
      let entry = model.registry.entries.first(where: { $0.descriptor.id == id })
    else { return false }
    let name = model.name(of: entry.descriptor)

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText =
      enabled
      ? String(localized: "A link is asking to turn on the “\(name)” module.")
      : String(localized: "A link is asking to turn off the “\(name)” module.")
    alert.informativeText = String(
      localized: """
        The request comes from outside Tsukumo, for example from a web page or another app. \
        Confirm only if you started it.
        """
    )
    // The default button is Cancel: Return never confirms.
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.addButton(withTitle: enabled ? String(localized: "Turn On") : String(localized: "Turn Off"))
    NSApp.activate()
    return alert.runModal() == .alertSecondButtonReturn
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showSettings()
    return false
  }

  private func showSettings() {
    if settingsWindow == nil {
      settingsWindow = SettingsWindowController(model: model) { [weak self] in
        self?.settingsWindow = nil
      }
    }
    settingsWindow?.show()
  }
}
