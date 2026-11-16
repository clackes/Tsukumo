// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import PrivateBridges

/// Already-resolved private function, read by the crash signal handler. It is
/// `nil` when the system ⌘⇥ was not turned off by us: the handler then does nothing.
private nonisolated(unsafe) var crashRestoreFunction: (@convention(c) (Int32, Bool) -> Int32)?

/// Disables and restores the system ⌘⇥ with the private API
/// `CGSSetSymbolicHotKeyEnabled` (DESIGN.md §2.2.1). Access to the symbol lives
/// in `PrivateBridges.SkyLightBridge`; here is the state logic (persistent
/// flag, exit hook, restore at launch): the state belongs to the
/// WindowServer session and survives a `kill -9` of Tsukumo (spike 6, 12 Nov 2026).
public enum NativeSwitcherGuard {
  /// ⌘⇥ and ⌘⇧⇥.
  private static let hotKeys: [Int32] = [1, 2]
  static let flagKey = "switcher.nativeHotkeyDisabledByUs"

  /// `true` if the private API exists on this system.
  public static var isAvailable: Bool { SkyLightBridge.hasSymbolicHotKey }

  /// To call at app launch, before the modules: repairs a previous crash.
  public static func restoreIfNeeded() {
    if UserDefaults.standard.bool(forKey: flagKey) { enableNative() }
  }

  /// Disables the system ⌘⇥. The flag is written **first**, so a crash in between
  /// is still repaired at the next launch.
  static func disableNative() {
    guard isAvailable else { return }
    UserDefaults.standard.set(true, forKey: flagKey)
    UserDefaults.standard.synchronize()
    installExitHook()
    armCrashRestore()
    for key in hotKeys { SkyLightBridge.setSymbolicHotKeyEnabled(key, false) }
  }

  /// Re-enables the system ⌘⇥ and deletes the flag.
  public static func enableNative() {
    if isAvailable {
      for key in hotKeys { SkyLightBridge.setSymbolicHotKeyEnabled(key, true) }
    }
    UserDefaults.standard.removeObject(forKey: flagKey)
    crashRestoreFunction = nil
  }

  /// `true` if the system ⌘⇥ is off by our hand.
  public static var isDisabledByUs: Bool { UserDefaults.standard.bool(forKey: flagKey) }

  private nonisolated(unsafe) static var crashHandlersInstalled = false

  /// §2.2.1 point 5: best-effort attempt to re-enable ⌘⇥ in a crash. It is not
  /// async-signal-safe and not guaranteed; the real protection remains the flag
  /// reread at the next launch. Swift traps arrive as SIGTRAP/SIGILL.
  /// `SA_RESETHAND` restores the default action: on return the signal
  /// is raised again and the crash proceeds normally, with its report.
  private static func armCrashRestore() {
    crashRestoreFunction = SkyLightBridge.symbolicHotKeyFunction
    guard !crashHandlersInstalled else { return }
    crashHandlersInstalled = true
    for number in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
      var action = sigaction()
      action.__sigaction_u.__sa_handler = { _ in
        guard let restore = crashRestoreFunction else { return }
        _ = restore(1, true)
        _ = restore(2, true)
      }
      sigemptyset(&action.sa_mask)
      action.sa_flags = SA_RESETHAND
      sigaction(number, &action, nil)
    }
  }

  private nonisolated(unsafe) static var exitHookInstalled = false

  /// `atexit` covers normal exits (also `exit()` after a handled signal).
  private static func installExitHook() {
    guard !exitHookInstalled else { return }
    exitHookInstalled = true
    atexit {
      if UserDefaults.standard.bool(forKey: NativeSwitcherGuard.flagKey) { NativeSwitcherGuard.enableNative() }
    }
  }
}
